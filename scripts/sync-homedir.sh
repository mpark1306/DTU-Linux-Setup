#!/usr/bin/env bash
###############################################################################
# sync-homedir.sh — Sync local home folders to mounted network drive (Qdrev)
#
# Deployed to /usr/local/bin/sync-homedir.sh
# Detects $USER automatically; checks mount before syncing.
# Local files always win on conflict (rsync --update).
# Logs to ~/.local/share/sync-homedir.log
###############################################################################
set -euo pipefail

# Read department config written by qdrive.sh during admin setup.
# Fall back to env var (for manual/test runs) and then to "sustain".
DRIVES_CONF="/etc/dtu-setup/drives.conf"
if [[ -f "$DRIVES_CONF" ]]; then
  # Source only the MOUNT_POINT and REMOTE_BASE lines (safe subset)
  MOUNT_POINT=$(grep -E "^MOUNT_POINT=" "$DRIVES_CONF" | cut -d= -f2-)
  REMOTE_BASE=$(grep -E "^REMOTE_BASE=" "$DRIVES_CONF" | cut -d= -f2- | sed "s|\${USER}|${USER}|g; s|\$USER|${USER}|g")
elif [[ "${DTU_DEPARTMENT:-sustain}" == "ait" ]]; then
  MOUNT_POINT="/mnt/Mdrev"
  REMOTE_BASE="/mnt/Mdrev"
else
  MOUNT_POINT="/mnt/Qdrev"
  REMOTE_BASE="/mnt/Qdrev/Personal/${USER}"
fi
LOG="${HOME}/.local/share/sync-homedir.log"
DIRS=(Desktop Documents Pictures)

mkdir -p "$(dirname "$LOG")"

log() { echo "$(date '+%F %T'): $*" >> "$LOG"; }

# Skip silently if network drive is not mounted
if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    log "Drev ikke tilgængeligt, springer over."
    exit 0
fi

# Create remote folders if missing (first login)
for DIR in "${DIRS[@]}"; do
    mkdir -p "$REMOTE_BASE/$DIR"
done

# Sync local → remote (local files win)
ERRORS=0
for DIR in "${DIRS[@]}"; do
    SRC="${HOME}/${DIR}/"
    DST="${REMOTE_BASE}/${DIR}/"

    if [[ ! -d "$SRC" ]]; then
        log "SKIP ${DIR}: kilde findes ikke"
        continue
    fi

    if rsync -av --update "$SRC" "$DST" >> "$LOG" 2>&1; then
        log "OK   ${DIR}"
    else
        log "FAIL ${DIR} (rsync exit $?)"
        ERRORS=$((ERRORS + 1))
    fi
done

log "Sync gennemført for ${USER}. Fejl=${ERRORS}"
exit 0
