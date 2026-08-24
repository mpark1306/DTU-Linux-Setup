#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Repair P-Drive "Permission denied"
#
# Fixes the known causes of P-Drive (/mnt/Personal) / Q-Drive failing to
# connect:
#   • the fstab entry targets a server unreachable on the current network
#     (DTUSecure WiFi / some VPN profiles can't route to the Qumulo
#     backend — see dtu-drives-reselect.sh, which normally handles this
#     automatically on network change)
#   • a stale/expired domain password in the credentials file
#   • the legacy DFS junction bug (Personal/<user> as a DFS junction to
#     Qumulo), fixed by mounting directly against Qumulo when reachable
#
# Run as root:  sudo bash repair-pdrive.sh <username>
#          or:  DTU_USERNAME=<username> sudo bash repair-pdrive.sh
#
# You will be prompted for the user's current domain password so the
# credentials file can be refreshed.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
need_root

site_require SITE_FILE_SERVER

if [[ -z "${1:-}" && -z "${DTU_USERNAME:-}" ]]; then
  echo "Usage: sudo bash $0 <username>"
  echo "  or:  DTU_USERNAME=<username> sudo bash $0"
  exit 1
fi

USERNAME="${1:-$DTU_USERNAME}"

if ! id "$USERNAME" >/dev/null 2>&1; then
  fail "User '${USERNAME}' not found on this machine."
  exit 1
fi

if [[ -z "${DTU_PASSWORD:-}" ]]; then
  read -rsp "Enter current domain password for ${USERNAME}: " DTU_PASSWORD; echo
fi

UID_NUM="$(id -u "$USERNAME")"
GID_NUM="$(id -g "$USERNAME")"

banner "Repair Q-Drive/P-Drive for ${USERNAME}"

MOUNTPOINT="/mnt/Qdrev"
P_MOUNTPOINT="/mnt/Personal"
CREDS_FILE="$(cifs_creds_file_resolve "$USERNAME")"

echo "[1/5] Refreshing credentials file..."
install -o "$USERNAME" -g "$GID_NUM" -m 600 /dev/null "$CREDS_FILE"
cat > "$CREDS_FILE" <<EOF
username=${USERNAME}
password=${DTU_PASSWORD}
domain=WIN
EOF
chown "$USERNAME":"$GID_NUM" "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
ok "Credentials file: ${CREDS_FILE}"

echo "[2/5] Picking the reachable target on the current network..."
if ! sustain_pick_target "$USERNAME"; then
  fail "Neither Qumulo (${SITE_FILE_SERVER_QUMULO:-unset}) nor the DFS root (${SITE_FILE_SERVER}) is reachable on port 445 right now."
  fail "Check the network/VPN connection and re-run."
  exit 1
fi
ok "Using ${TARGET_LABEL} target: //${SERVER}"

echo "[3/5] Verifying the P-Drive path is reachable with the refreshed password..."
if ! cifs_test_mount "$SERVER" "$P_SHARE_PATH" "$CREDS_FILE" "$UID_NUM" "$GID_NUM"; then
  fail "Still 'permission denied' against //${SERVER}/${P_SHARE_PATH}."
  fail "Password may still be wrong, or IT has not granted access to this Personal folder."
  exit 1
fi
ok "//${SERVER}/${P_SHARE_PATH} is reachable — dropping any stale fstab entry."

echo "[4/5] Rewriting /etc/fstab entries for Q-Drive and P-Drive..."
cp -a /etc/fstab "/etc/fstab.dtu.bak.$(date +%s)"
sustain_write_fstab "$MOUNTPOINT" "$P_MOUNTPOINT" "$CREDS_FILE" "$UID_NUM" "$GID_NUM"
ok "fstab updated (backup saved as /etc/fstab.dtu.bak.*)."

echo "[5/5] Reloading systemd and mounting..."
systemctl daemon-reload
cifs_start_automount "$MOUNTPOINT"
cifs_start_automount "$P_MOUNTPOINT"
if ls "$P_MOUNTPOINT" >/dev/null 2>&1 && mountpoint -q "$P_MOUNTPOINT"; then
  ok "P-Drive mounted at ${P_MOUNTPOINT}."
else
  warn "P-Drive did not mount automatically yet. Try: ls ${P_MOUNTPOINT}"
fi

# Keep drives.conf + the network auto-switch hook in sync, if configured.
DRIVES_CONF="/etc/dtu-setup/drives.conf"
if [[ -f "$DRIVES_CONF" ]]; then
  grep -q '^USERNAME=' "$DRIVES_CONF" && sed -i "s/^USERNAME=.*/USERNAME=${USERNAME}/" "$DRIVES_CONF" || echo "USERNAME=${USERNAME}" >> "$DRIVES_CONF"
  grep -q '^TARGET=' "$DRIVES_CONF" && sed -i "s/^TARGET=.*/TARGET=${TARGET_LABEL}/" "$DRIVES_CONF" || echo "TARGET=${TARGET_LABEL}" >> "$DRIVES_CONF"
fi
"${SCRIPT_DIR}/deploy-drives-autoswitch.sh" 2>/dev/null || true

ok "Done. Ask ${USERNAME} to log out and back in, then check ${P_MOUNTPOINT}."

