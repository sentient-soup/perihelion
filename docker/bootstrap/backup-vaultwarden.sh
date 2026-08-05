#!/usr/bin/env bash
# Writes a consistent copy of the Vaultwarden SQLite db next to the vault, for
# the host's rsync mirror to pick up.
#
# Everything else in ${CONFIG_DIR}/vaultwarden (attachments, sends, rsa_key.pem,
# config.json) is ordinary files that rsync already handles correctly. The db is
# the exception: Vaultwarden runs SQLite in WAL mode, so an rsync of the live
# db.sqlite3 + db.sqlite3-wal can capture the two at different instants and
# mirror a torn, unrecoverable pair. SQLite's online backup API takes the copy
# under a proper lock instead.
#
# Cron (daily at 03:30, before the mirror runs):
#   30 3 * * * /opt/homelab/docker/bootstrap/backup-vaultwarden.sh >> /var/log/vaultwarden-backup.log 2>&1
#
# Requires: sqlite3 on the host (apt install sqlite3)
#
# Restore: stop vaultwarden, copy this db.sqlite3 over
# ${CONFIG_DIR}/vaultwarden/db.sqlite3 (delete any -wal/-shm alongside it),
# start it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../.env"

SRC="${CONFIG_DIR}/vaultwarden/db.sqlite3"
DEST_DIR="${CONFIG_DIR}/vaultwarden-backup"
DEST="${DEST_DIR}/db.sqlite3"

if ! command -v sqlite3 > /dev/null; then
    echo "$(date -Iseconds) ERROR: sqlite3 not installed (apt install sqlite3)" >&2
    exit 1
fi

mkdir -p "${DEST_DIR}"

# Snapshot to a temp name and verify before it replaces the last good copy: a
# run that dies partway must not leave a truncated db as the only backup.
sqlite3 "${SRC}" ".backup '${DEST}.tmp'"
if [[ "$(sqlite3 "${DEST}.tmp" 'PRAGMA integrity_check;')" != "ok" ]]; then
    echo "$(date -Iseconds) ERROR: integrity_check failed - check the live db" >&2
    exit 1
fi
mv -f "${DEST}.tmp" "${DEST}"

echo "$(date -Iseconds) INFO: wrote ${DEST} ($(du -h "${DEST}" | cut -f1))"
