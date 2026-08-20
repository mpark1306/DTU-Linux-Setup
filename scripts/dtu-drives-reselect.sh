#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Re-pick Q-Drive/P-Drive target after a network change
#
# DTUSecure WiFi and some VPN profiles cannot route to the Qumulo backend
# used for the direct CIFS mount, while the DFS root is reachable from
# (almost) anywhere. This re-tests reachability and, if the reachable
# target changed since the last run, rewrites the fstab entries and
# remounts — so Q-Drive/P-Drive keep working when moving between wired,
# DTUSecure WiFi and VPN, instead of failing silently.
#
# Invoked by the NetworkManager dispatcher hook installed by
# deploy-drives-autoswitch.sh; safe to run manually as root too.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="/var/log/dtu-drives-reselect.log"
log() { echo "$(date '+%F %T'): $*" >> "$LOG" 2>/dev/null || true; }

if [[ $EUID -ne 0 ]]; then
  fail "Must run as root."
  exit 1
fi

DRIVES_CONF="/etc/dtu-setup/drives.conf"
[[ -f "$DRIVES_CONF" ]] || exit 0

DEPARTMENT="$(grep -E '^DEPARTMENT=' "$DRIVES_CONF" | cut -d= -f2-)"
[[ "$DEPARTMENT" == "sustain" ]] || exit 0

USERNAME="$(grep -E '^USERNAME=' "$DRIVES_CONF" | cut -d= -f2-)"
PREV_TARGET="$(grep -E '^TARGET=' "$DRIVES_CONF" | cut -d= -f2-)"
[[ -n "$USERNAME" ]] || exit 0
id "$USERNAME" >/dev/null 2>&1 || exit 0

UID_NUM="$(id -u "$USERNAME")"
GID_NUM="$(id -g "$USERNAME")"
CREDS_FILE="/home/${USERNAME}/.smbcred-<fileserver>"
[[ -r "$CREDS_FILE" ]] || { log "Credentials file missing: ${CREDS_FILE}"; exit 0; }

MOUNTPOINT="/mnt/Qdrev"
P_MOUNTPOINT="/mnt/Personal"

if ! sustain_pick_target "$USERNAME"; then
  log "Neither Qumulo nor the DFS root is reachable right now — leaving mounts as-is."
  exit 0
fi

if [[ "$TARGET_LABEL" == "$PREV_TARGET" ]]; then
  exit 0
fi

log "Network target changed: ${PREV_TARGET:-none} -> ${TARGET_LABEL}. Remounting Q-Drive/P-Drive for ${USERNAME}."

sustain_write_fstab "$MOUNTPOINT" "$P_MOUNTPOINT" "$CREDS_FILE" "$UID_NUM" "$GID_NUM"
systemctl daemon-reload
cifs_start_automount "$MOUNTPOINT"
cifs_start_automount "$P_MOUNTPOINT"

sed -i "s/^TARGET=.*/TARGET=${TARGET_LABEL}/" "$DRIVES_CONF"
log "Remounted using ${TARGET_LABEL} target //${SERVER}"
