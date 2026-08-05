#!/usr/bin/env bash
# Snapshots the Vaultwarden vault to a single tarball, replaced each run.
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
# ponytail: one rolling copy, no retention. The trade-off is that a deletion
# you don't notice within a day is gone from here too (and from the rsync
# mirror). If that ever matters, add a date stamp to ARCHIVE and prune with
# `find -mtime`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../.env"

VAULT_DIR="${CONFIG_DIR}/vaultwarden"
BACKUP_DIR="${VAULTWARDEN_BACKUP_DIR:-${CONFIG_DIR}/backups/vaultwarden}"
ARCHIVE="${BACKUP_DIR}/vaultwarden.tar.gz"

if ! command -v sqlite3 > /dev/null; then
    echo "$(date -Iseconds) ERROR: sqlite3 not installed (apt install sqlite3)" >&2
    exit 1
fi

mkdir -p "${BACKUP_DIR}"
# Staged inside BACKUP_DIR so the final mv is a same-filesystem rename: a run
# that dies partway leaves the previous good tarball untouched.
STAGING="$(mktemp -d "${BACKUP_DIR}/.staging.XXXXXX")"
trap 'rm -rf "${STAGING}"' EXIT

# Consistent db snapshot, then prove it's readable before it replaces the last
# good one. A corrupt backup nobody notices is worse than no backup.
sqlite3 "${VAULT_DIR}/db.sqlite3" ".backup '${STAGING}/db.sqlite3'"
if [[ "$(sqlite3 "${STAGING}/db.sqlite3" 'PRAGMA integrity_check;')" != "ok" ]]; then
    echo "$(date -Iseconds) ERROR: integrity_check failed on the snapshot" >&2
    exit 1
fi

tar -czf "${STAGING}/vaultwarden.tar.gz" \
    -C "${STAGING}" db.sqlite3 \
    -C "${VAULT_DIR}" --exclude='db.sqlite3*' .
mv -f "${STAGING}/vaultwarden.tar.gz" "${ARCHIVE}"

echo "$(date -Iseconds) INFO: wrote ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
