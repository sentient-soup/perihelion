#!/usr/bin/env bash
# Mirror a storage tier to its backup disk.
#   backup-tier.sh hot    /mnt/phis4/hot/  -> /mnt/phis4/hotb/hot/
#   backup-tier.sh cold   /mnt/phis4/cold/ -> /mnt/phis4/coldb/cold/
#
# Replaces the unversioned /opt/scripts/backup-{hot,cold}.sh pair.
#
# The guards below exist because a --delete mirror is only as trustworthy as
# its source. When ssd2 dropped off the USB bus on 2026-09-04, an unguarded
# run would have mirrored the missing files into the backup and destroyed the
# only remaining copy. rsync happened to save us (it skips deletion after a
# source read error unless --ignore-errors is set) and the schedule happened
# to miss the window. Neither is a control.
set -euo pipefail

TIER="${1:?usage: backup-tier.sh hot|cold}"
SRC="/mnt/phis4/${TIER}"
DEST="/mnt/phis4/${TIER}b/${TIER}"
LOG="/var/log/backup-${TIER}.log"

exec >>"$LOG" 2>&1
echo "========================================"
echo "${TIER} backup started: $(date)"

# A filesystem that failed to mount leaves an empty directory behind on its
# parent. To --delete that reads as "the user deleted everything".
#
# The test is a sentinel file living on each real filesystem, not mountpoint(1):
# /mnt/phis4/hot is a bind mount, so mountpoint reports success even when ssd1
# never mounted underneath it. That is exactly the nofail failure mode this
# needs to catch. Create one per filesystem with:
#   sudo touch /mnt/phis4/{hot,hot/media,hotb,cold,coldb}/.tier-ok
check_live() {
    [ -f "$1/.tier-ok" ] || { echo "ABORT: $1/.tier-ok missing, $1 is not the filesystem it should be"; exit 1; }
}

check_live "$SRC"
check_live "/mnt/phis4/${TIER}b"
# hot carries a nested mount for the media drive; cold is a single filesystem.
# (An if, not a &&: under set -e a false && short-circuit exits the script.)
if [ "$TIER" = hot ]; then
    check_live "$SRC/media"
fi

mkdir -p "$DEST"

# Circuit breaker. A normal run deletes a handful of files, so a hundred means
# the source is wrong rather than the data being gone. Raise it if a genuine
# library cleanup ever trips it.
if ! rsync -avh --delete --max-delete=100 --stats "$SRC/" "$DEST/"; then
    rc=$?
    echo "ABORT: rsync exited ${rc} (25 = --max-delete tripped, source is suspect)"
    exit "$rc"
fi

echo "${TIER} backup completed: $(date)"
