#!/usr/bin/env bash
# Read a backup back (CHG-0039): decrypt the newest archive and check it against
# its own manifest. Changes nothing; a restore is a separate, deliberate act.
#
#   deevnet-backup-verify drive|dry-run <identity file>
#
# The identity file is the private key, which no host holds. The playbook that
# calls this places it in memory for the length of the check and removes it.
set -euo pipefail

CONFIG=${DEEVNET_BACKUP_CONFIG:-/etc/deevnet/backup.conf}
# shellcheck disable=SC1090
. "$CONFIG"

SOURCE=${1:-}
IDENTITY=${2:-}
[ -f "$IDENTITY" ] || { echo "usage: deevnet-backup-verify drive|dry-run <identity file>" >&2; exit 2; }

die() { echo "deevnet-backup-verify: FAILED: $*" >&2; exit 1; }

WORK=""
MOUNTED=0
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
  [ "$MOUNTED" = 1 ] && unmount "$BACKUP_MOUNT"
  [ -n "$WORK" ] && rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

case "$SOURCE" in
  drive)
    mapfile -t DRIVES < <(blkid -t "LABEL=$BACKUP_LABEL" -o device)
    [ "${#DRIVES[@]}" -eq 1 ] || die "expected one filesystem labeled $BACKUP_LABEL, found ${#DRIVES[@]}"
    mountpoint -q "$BACKUP_MOUNT" && die "$BACKUP_MOUNT is in use"
    mount -o ro,nosuid,nodev,noexec "${DRIVES[0]}" "$BACKUP_MOUNT" || die "could not mount ${DRIVES[0]}"
    MOUNTED=1
    DIR="$BACKUP_MOUNT/$BACKUP_DIR"
    ;;
  dry-run) DIR="$BACKUP_STATE_DIR/dry-run" ;;
  *) die "source must be drive or dry-run" ;;
esac

ARCHIVE=$(find "$DIR" -maxdepth 1 -type f -name '*.tar.age' | sort | tail -1)
[ -n "$ARCHIVE" ] || die "no archive under $DIR"

WORK=$(mktemp -d /run/deevnet-backup-verify.XXXXXX)
chmod 700 "$WORK"
age --decrypt --identity "$IDENTITY" "$ARCHIVE" | tar -C "$WORK" -xf - \
  || die "could not decrypt $(basename "$ARCHIVE") with this key"
cd "$WORK"
sed -n '/^sha256:/,$p' MANIFEST | tail -n +2 | sed 's/^  //' | sha256sum --check --quiet \
  || die "the archive does not match its manifest"
TABLES=$(podman exec -i "$BACKUP_DB_CONTAINER" pg_restore --list < database.pgdump | grep -c 'TABLE DATA') \
  || die "the database dump is not readable"

echo "archive: $(basename "$ARCHIVE")"
sed '/^sha256:/,$d' MANIFEST
echo "checksums: all match"
echo "database dump: readable, $TABLES tables with data"
