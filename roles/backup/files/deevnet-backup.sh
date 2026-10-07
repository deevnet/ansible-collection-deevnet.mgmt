#!/usr/bin/env bash
# Deevnet backup (CHG-0039): the API's database and the state bucket, in one
# archive, encrypted before it is written to the attached drive.
#
#   deevnet-backup             write an archive to the drive, now
#   deevnet-backup --if-due    the same, but only when the newest good backup is
#                              older than the interval; otherwise do nothing and
#                              succeed. What the timer runs.
#   deevnet-backup --dry-run   build and encrypt an archive without a drive, and
#                              leave it under the state directory for a
#                              decryption check
#
# Fails, with the reason on the last line, when the drive is absent, is not one
# this site prepared, or when either source does not answer. Plaintext exists
# only under /run, in memory, and only while a run lasts.
set -euo pipefail

CONFIG=${DEEVNET_BACKUP_CONFIG:-/etc/deevnet/backup.conf}
# shellcheck disable=SC1090
. "$CONFIG"

DRY_RUN=0
IF_DUE=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  --if-due) IF_DUE=1 ;;
  *) echo "usage: deevnet-backup [--if-due | --dry-run]" >&2; exit 2 ;;
esac

WORK=""
MOUNTED=0

log() { echo "deevnet-backup: $*"; }
die() { echo "deevnet-backup: FAILED: $*" >&2; exit 1; }

# A second run, or the timer's check, can hold the mount for a moment. Wait for
# it rather than leave the drive mounted.
unmount() {
  for _ in $(seq 1 30); do
    umount "$1" 2>/dev/null && return 0
    mountpoint -q "$1" || return 0
    sleep 2
  done
  umount "$1"
}

cleanup() {
  if [ "$MOUNTED" = 1 ]; then
    sync
    unmount "$BACKUP_MOUNT" || echo "deevnet-backup: could not unmount $BACKUP_MOUNT" >&2
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || die "must run as root"
[ -n "$BACKUP_RECIPIENT" ] || die "no recipient key configured"
command -v age >/dev/null || die "age is not installed"

# --- Is one due? ----------------------------------------------------------------
# Judged from this host's own record of its last good run, so a check costs
# nothing and needs no drive. A clock that has gone backwards counts as due.
if [ "$IF_DUE" = 1 ] && [ -f "$BACKUP_STATE_DIR/last-success" ]; then
  LAST=$(sed -n 's/^epoch=//p' "$BACKUP_STATE_DIR/last-success")
  NOW=$(date -u +%s)
  if [ -n "$LAST" ] && [ "$NOW" -ge "$LAST" ] && [ $((NOW - LAST)) -lt $((BACKUP_INTERVAL_HOURS * 3600)) ]; then
    log "not due: the newest good backup is $(( (NOW - LAST) / 3600 ))h old, the interval is ${BACKUP_INTERVAL_HOURS}h"
    exit 0
  fi
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NAME="deevnet-backup-${BACKUP_HOST}-${STAMP}.tar.age"

# --- The drive, first: an absent drive should not cost a dump ------------------
if [ "$DRY_RUN" = 1 ]; then
  DEST="$BACKUP_STATE_DIR/dry-run"
  mkdir -p "$DEST"
  rm -f "$DEST"/*.tar.age "$DEST"/*.partial
else
  mapfile -t DRIVES < <(blkid -t "LABEL=$BACKUP_LABEL" -o device)
  [ "${#DRIVES[@]}" -ge 1 ] || die "backup drive absent: no filesystem labelled $BACKUP_LABEL"
  [ "${#DRIVES[@]}" -eq 1 ] || die "more than one filesystem labelled $BACKUP_LABEL: ${DRIVES[*]}"
  DRIVE=${DRIVES[0]}

  mkdir -p "$BACKUP_MOUNT"
  if mountpoint -q "$BACKUP_MOUNT"; then
    die "$BACKUP_MOUNT is already mounted; another run, or a mount left behind"
  fi
  mount -o nosuid,nodev,noexec "$DRIVE" "$BACKUP_MOUNT" || die "could not mount $DRIVE"
  MOUNTED=1
  [ -f "$BACKUP_MOUNT/$BACKUP_MARKER" ] \
    || die "$DRIVE carries the label but not $BACKUP_MARKER; it was not prepared for this site"
  DEST="$BACKUP_MOUNT/$BACKUP_DIR"
  mkdir -p "$DEST"
  rm -f "$DEST"/*.partial
fi

WORK=$(mktemp -d /run/deevnet-backup.XXXXXX)
chmod 700 "$WORK"
mkdir "$WORK/payload" "$WORK/payload/state"

# --- The database --------------------------------------------------------------
ready=0
for _ in $(seq 1 30); do
  if podman exec "$BACKUP_DB_CONTAINER" pg_isready -q -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" 2>/dev/null; then
    ready=1; break
  fi
  sleep 2
done
[ "$ready" = 1 ] || die "the database in $BACKUP_DB_CONTAINER does not answer"

podman exec "$BACKUP_DB_CONTAINER" \
  pg_dump -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" --format=custom \
  > "$WORK/payload/database.pgdump" || die "pg_dump failed"
[ -s "$WORK/payload/database.pgdump" ] || die "pg_dump wrote nothing"
DB_VERSION=$(podman exec "$BACKUP_DB_CONTAINER" pg_dump --version)

# --- The state bucket ----------------------------------------------------------
# A one-shot container from the store's own image, for its client. Labelling is
# off rather than relabelled: the CA directory belongs to the running store, and
# relabelling it for this container would take it away from that one.
S3_IMAGE=$(podman container inspect "$BACKUP_S3_CONTAINER" --format '{{.ImageName}}') \
  || die "the state store container $BACKUP_S3_CONTAINER does not exist"
export BACKUP_S3_URL BACKUP_S3_BUCKET
podman run --rm --pull=never --network host --security-opt label=disable \
  --env-file "$BACKUP_S3_ENV_FILE" \
  -e MC_CONFIG_DIR=/tmp/mc -e BACKUP_S3_URL -e BACKUP_S3_BUCKET \
  -v "$BACKUP_S3_CA_DIR:$BACKUP_S3_CA_MOUNT:ro" \
  -v "$WORK/payload/state:/out" \
  --entrypoint sh "$S3_IMAGE" -c '
    set -e
    mc alias set src "$BACKUP_S3_URL" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
    mc mirror --quiet src/"$BACKUP_S3_BUCKET" /out >/dev/null
    mc ls --recursive src/"$BACKUP_S3_BUCKET" | wc -l
  ' > "$WORK/object-count" || die "mirroring the state bucket failed"
EXPECTED=$(tr -d '[:space:]' < "$WORK/object-count")
FOUND=$(find "$WORK/payload/state" -type f | wc -l)
[ "$EXPECTED" = "$FOUND" ] || die "the state bucket holds $EXPECTED objects but $FOUND were mirrored"

# --- The manifest ---------------------------------------------------------------
{
  echo "host: $BACKUP_HOST"
  echo "taken: $STAMP"
  echo "database: $BACKUP_DB_NAME ($DB_VERSION, custom format)"
  echo "state_bucket: $BACKUP_S3_BUCKET ($FOUND objects)"
  echo "sha256:"
  (cd "$WORK/payload" && find database.pgdump state -type f -print0 | sort -z | xargs -0 sha256sum | sed 's/^/  /')
} > "$WORK/payload/MANIFEST"

# --- Encrypt, straight onto the destination --------------------------------------
tar -C "$WORK/payload" -cf - MANIFEST database.pgdump state \
  | age --encrypt --recipient "$BACKUP_RECIPIENT" --output "$DEST/$NAME.partial" \
  || die "encrypting the archive failed"
[ "$(head -c 21 "$DEST/$NAME.partial")" = "age-encryption.org/v1" ] \
  || die "what was written is not an age file"
sync "$DEST/$NAME.partial"
mv "$DEST/$NAME.partial" "$DEST/$NAME"
SIZE=$(stat -c %s "$DEST/$NAME")

# --- Retention -------------------------------------------------------------------
# Names sort by time. Only this host's archives, only on a real run.
KEPT=1
if [ "$DRY_RUN" = 0 ]; then
  mapfile -t ALL < <(find "$DEST" -maxdepth 1 -type f -name "deevnet-backup-${BACKUP_HOST}-*.tar.age" | sort)
  if [ "${#ALL[@]}" -gt "$BACKUP_KEEP" ]; then
    for old in "${ALL[@]:0:${#ALL[@]}-BACKUP_KEEP}"; do
      rm -f "$old"
    done
  fi
  KEPT=$(find "$DEST" -maxdepth 1 -type f -name "deevnet-backup-${BACKUP_HOST}-*.tar.age" | wc -l)
  sync

  mkdir -p "$BACKUP_STATE_DIR"
  {
    echo "taken=$STAMP"
    echo "epoch=$(date -u +%s)"
    echo "archive=$NAME"
    echo "bytes=$SIZE"
    echo "objects=$FOUND"
    echo "kept=$KEPT"
    echo "drive_uuid=$(blkid -s UUID -o value "$DRIVE")"
  } > "$BACKUP_STATE_DIR/last-success.tmp"
  mv "$BACKUP_STATE_DIR/last-success.tmp" "$BACKUP_STATE_DIR/last-success"
  log "wrote $NAME ($SIZE bytes, $FOUND state objects); $KEPT archives on the drive"
else
  log "dry run: wrote $DEST/$NAME ($SIZE bytes, $FOUND state objects); no drive was touched"
fi
