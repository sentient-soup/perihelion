#!/usr/bin/env bash
# Snapshots the Vaultwarden vault to a timestamped tarball.
#
# A plain cp of a live db.sqlite3 can catch a write mid-transaction, so the db
# goes through SQLite's online backup API first; everything else in the data dir
# (attachments, sends, rsa_key.pem, config.json) is just files and tars as-is.
#
# Cron (daily at 03:30):
#   30 3 * * * /opt/homelab/docker/bootstrap/backup-vaultwarden.sh >> /var/log/vaultwarden-backup.log 2>&1
#
# Requires: sqlite3 on the host (apt install sqlite3)
#
# This writes to the same mergerfs pool as the vault - it survives a bad
# upgrade or a fat-fingered delete, not a dead machine. Point restic/rsync at
# BACKUP_DIR for the off-host copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../.env"

VAULT_DIR="${CONFIG_DIR}/vaultwarden"
BACKUP_DIR="${VAULTWARDEN_BACKUP_DIR:-${CONFIG_DIR}/backups/vaultwarden}"
RETENTION_DAYS="${VAULTWARDEN_BACKUP_RETENTION_DAYS:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)"

if ! command -v sqlite3 > /dev/null; then
    echo "$(date -Iseconds) ERROR: sqlite3 not installed (apt install sqlite3)" >&2
    exit 1
fi

mkdir -p "${BACKUP_DIR}"
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

# Consistent db snapshot, then prove it's readable before we keep it. A corrupt
# backup that nobody notices is worse than no backup.
sqlite3 "${VAULT_DIR}/db.sqlite3" ".backup '${STAGING}/db.sqlite3'"
if [[ "$(sqlite3 "${STAGING}/db.sqlite3" 'PRAGMA integrity_check;')" != "ok" ]]; then
    echo "$(date -Iseconds) ERROR: integrity_check failed on the snapshot" >&2
    exit 1
fi

ARCHIVE="${BACKUP_DIR}/vaultwarden-${STAMP}.tar.gz"
tar -czf "${ARCHIVE}" \
    -C "${STAGING}" db.sqlite3 \
    -C "${VAULT_DIR}" --exclude='db.sqlite3*' .

find "${BACKUP_DIR}" -name 'vaultwarden-*.tar.gz' -mtime "+${RETENTION_DAYS}" -delete

echo "$(date -Iseconds) INFO: wrote ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
