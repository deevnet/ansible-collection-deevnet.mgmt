#!/usr/bin/env bash
# Restore a backup (CHG-0039) into a provisioning VM its roles have just built:
# the API's database and the state bucket, from one archive on the drive.
#
#   deevnet-backup-restore <identity file> [archive name]
#
# Without a name, the newest archive on the drive. Refuses unless the registry
# holds no tenants and the bucket no objects: a restore fills an empty host, it
# does not overwrite a live one. The API is stopped while the database is
# replaced and started again at the end. A reconcile of every tenant follows,
# from the control node; this script does not run it.
#
# The identity file is the private key, which no host holds. The playbook that
# calls this places it in memory for the length of the restore and removes it.
set -euo pipefail

CONFIG=${DEEVNET_BACKUP_CONFIG:-/etc/deevnet/backup.conf}
# shellcheck disable=SC1090
. "$CONFIG"

IDENTITY=${1:-}
WANTED=${2:-}
[ -f "$IDENTITY" ] || { echo "usage: deevnet-backup-restore <identity file> [archive name]" >&2; exit 2; }

log() { echo "deevnet-backup-restore: $*"; }
die() { echo "deevnet-backup-restore: FAILED: $*" >&2; exit 1; }

WORK=""
MOUNTED=0
API_STOPPED=0

unmount() {
  for _ in $(seq 1 30); do
    umount "$1" 2>/dev/null && return 0
    mountpoint -q "$1" || return 0
    sleep 2
  done
  umount "$1"
}

cleanup() {
  [ "$MOUNTED" = 1 ] && unmount "$BACKUP_MOUNT"
  [ -n "$WORK" ] && rm -rf "$WORK"
  if [ "$API_STOPPED" = 1 ]; then
    echo "deevnet-backup-restore: $BACKUP_API_SERVICE was left STOPPED: the restore did not finish" >&2
  fi
  return 0
}
trap cleanup EXIT

db() { podman exec "$BACKUP_DB_CONTAINER" "$@"; }

# One-shot container from the store's own image, for its client. See the backup
# script for why labelling is off rather than relabelled.
s3() {
  podman run --rm --pull=never --network host --security-opt label=disable \
    --env-file "$BACKUP_S3_ENV_FILE" \
    -e MC_CONFIG_DIR=/tmp/mc -e BACKUP_S3_URL -e BACKUP_S3_BUCKET \
    -v "$BACKUP_S3_CA_DIR:$BACKUP_S3_CA_MOUNT:ro" \
    -v "$WORK/state:/in:ro" \
    --entrypoint sh "$S3_IMAGE" -c "
      set -e
      mc alias set dst \"\$BACKUP_S3_URL\" \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null
      $1"
}

[ "$(id -u)" = 0 ] || die "must run as root"

# --- The archive ---------------------------------------------------------------
mapfile -t DRIVES < <(blkid -t "LABEL=$BACKUP_LABEL" -o device)
[ "${#DRIVES[@]}" -eq 1 ] || die "expected one filesystem labeled $BACKUP_LABEL, found ${#DRIVES[@]}"
mountpoint -q "$BACKUP_MOUNT" && die "$BACKUP_MOUNT is in use"
mkdir -p "$BACKUP_MOUNT"
mount -o ro,nosuid,nodev,noexec "${DRIVES[0]}" "$BACKUP_MOUNT" || die "could not mount ${DRIVES[0]}"
MOUNTED=1

DIR="$BACKUP_MOUNT/$BACKUP_DIR"
if [ -n "$WANTED" ]; then
  ARCHIVE="$DIR/$(basename "$WANTED")"
  [ -f "$ARCHIVE" ] || die "no archive $(basename "$WANTED") under $BACKUP_DIR on the drive"
else
  ARCHIVE=$(find "$DIR" -maxdepth 1 -type f -name '*.tar.age' | sort | tail -1)
  [ -n "$ARCHIVE" ] || die "no archive under $BACKUP_DIR on the drive"
fi

WORK=$(mktemp -d /run/deevnet-backup-restore.XXXXXX)
chmod 700 "$WORK"
age --decrypt --identity "$IDENTITY" "$ARCHIVE" | tar -C "$WORK" -xf - \
  || die "could not decrypt $(basename "$ARCHIVE") with this key"
(cd "$WORK" && sed -n '/^sha256:/,$p' MANIFEST | tail -n +2 | sed 's/^  //' | sha256sum --check --quiet) \
  || die "the archive does not match its manifest"
unmount "$BACKUP_MOUNT"; MOUNTED=0
OBJECTS=$(find "$WORK/state" -type f | wc -l)

# --- Only into an empty host ---------------------------------------------------
ready=0
for _ in $(seq 1 30); do
  if db pg_isready -q -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" 2>/dev/null; then ready=1; break; fi
  sleep 2
done
[ "$ready" = 1 ] || die "the database in $BACKUP_DB_CONTAINER does not answer"

# No tenants table at all is a database the API has not yet migrated: empty.
HAVE=$(db psql -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -Atc "select count(*) from tenants" 2>/dev/null || echo 0)
[ "$HAVE" = 0 ] || die "the registry already holds $HAVE tenants; a restore fills an empty host and will not overwrite this one"

S3_IMAGE=$(podman container inspect "$BACKUP_S3_CONTAINER" --format '{{.ImageName}}') \
  || die "the state store container $BACKUP_S3_CONTAINER does not exist"
export BACKUP_S3_URL BACKUP_S3_BUCKET
PRESENT=$(s3 'mc ls --recursive dst/"$BACKUP_S3_BUCKET" | wc -l' | tr -d '[:space:]') \
  || die "the state store does not answer, or has no bucket $BACKUP_S3_BUCKET"
[ "$PRESENT" = 0 ] || die "the bucket $BACKUP_S3_BUCKET already holds $PRESENT objects; refusing to overwrite them"

log "restoring $(basename "$ARCHIVE")"
sed '/^sha256:/,$d' "$WORK/MANIFEST" | sed 's/^/  /'

# --- The database --------------------------------------------------------------
systemctl stop "$BACKUP_API_SERVICE"
API_STOPPED=1
db dropdb -U "$BACKUP_DB_USER" --if-exists "$BACKUP_DB_NAME" || die "could not drop the empty database"
db createdb -U "$BACKUP_DB_USER" -O "$BACKUP_DB_USER" "$BACKUP_DB_NAME" || die "could not create the database"
podman exec -i "$BACKUP_DB_CONTAINER" \
  pg_restore -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" --exit-on-error < "$WORK/database.pgdump" \
  || die "pg_restore failed; the database is incomplete"
TENANTS=$(db psql -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -Atc "select count(*) from tenants")

# --- The state bucket ----------------------------------------------------------
if [ "$OBJECTS" -gt 0 ]; then
  s3 'mc mirror --quiet /in dst/"$BACKUP_S3_BUCKET" >/dev/null' || die "copying state into the bucket failed"
fi
NOW=$(s3 'mc ls --recursive dst/"$BACKUP_S3_BUCKET" | wc -l' | tr -d '[:space:]')
[ "$NOW" = "$OBJECTS" ] || die "the archive holds $OBJECTS state objects but the bucket now holds $NOW"

systemctl start "$BACKUP_API_SERVICE" || die "the database and bucket are restored but $BACKUP_API_SERVICE did not start"
API_STOPPED=0

log "restored $TENANTS tenants and $OBJECTS state objects from $(basename "$ARCHIVE")"
log "next, from the control node: make reconcile NAME=--all"
