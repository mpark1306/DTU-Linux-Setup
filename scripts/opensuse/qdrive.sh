#!/usr/bin/env bash
###############################################################################
# DTU Sustain – openSUSE Tumbleweed – Module: Q-Drive CIFS mount
# Direct mount to DFS target (bypasses kernel 6.19+ DFS bug)
# Env: DTU_USERNAME, DTU_PASSWORD (optional – falls back to interactive)
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Q-Drive SUS → /mnt/Qdrev (direct CIFS)"

# Require credentials via environment (interactive prompts hang in GUI)
if [[ -z "${DTU_USERNAME:-}" || -z "${DTU_PASSWORD:-}" ]]; then
  fail "DTU_USERNAME and DTU_PASSWORD must be set. Run via the GUI or export them."
  exit 1
fi

USERNAME="$DTU_USERNAME"
PASSWORD="$DTU_PASSWORD"
DEPARTMENT="${DTU_DEPARTMENT:-sustain}"

# ─────────────────────────────────────────────────────────────────────────────
# AIT profile: O-Drive (shared dept) + M-Drive (personal, Users0-9 lookup)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$DEPARTMENT" == "ait" ]]; then
  banner "O-Drive & M-Drive – AIT CIFS mount (openSUSE)"

  DOMAIN="WIN"
  SERVER="${SITE_FILE_SERVER}"
  O_SHARE="Department/Institut"
  O_MOUNTPOINT="/mnt/Odrev"
  M_SERVER="${SITE_FILE_SERVER}"
  USERS_BASE="Users"
  M_MOUNTPOINT="/mnt/Mdrev"
  CREDS_FILE="/home/$USERNAME/.smbcred-<fileserver>"
  FSTAB_FILE="/etc/fstab"

  if ! id "$USERNAME" >/dev/null 2>&1; then
    fail "User '$USERNAME' not found on this machine."
    exit 1
  fi

  UID_NUM="$(id -u "$USERNAME")"
  GID_NUM="$(id -g "$USERNAME")"
  HOME_DIR="/home/$USERNAME"

  if [ ! -d "$HOME_DIR" ]; then
    echo "Creating home directory for $USERNAME..."
    mkdir -p "$HOME_DIR"
    chown "$UID_NUM":"$GID_NUM" "$HOME_DIR"
    chmod 0700 "$HOME_DIR"
  fi

  echo "Using UID=$UID_NUM GID=$GID_NUM"

  echo "[1/9] Installing cifs-utils + samba-client..."
  zypper --non-interactive install cifs-utils samba-client

  echo "[2/9] Writing credentials file (chmod 600)..."
  install -o "$USERNAME" -g "$GID_NUM" -m 600 /dev/null "$CREDS_FILE"
  cat > "$CREDS_FILE" <<EOF
username=${USERNAME}
password=${PASSWORD}
domain=${DOMAIN}
EOF
  chown "$USERNAME":"$GID_NUM" "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"

  echo "[3/9] Creating O-Drive mountpoint..."
  umount "$O_MOUNTPOINT" 2>/dev/null || true
  mkdir -p "$O_MOUNTPOINT"
  chown "$UID_NUM":"$GID_NUM" "$O_MOUNTPOINT"
  chmod 0770 "$O_MOUNTPOINT"

  echo "[4/9] Ensuring /etc/fstab entry for O-Drive..."
  sed -i "\|${SERVER}/${O_SHARE}|d" "$FSTAB_FILE" 2>/dev/null || true
  O_FSTAB_LINE="//${SERVER}/${O_SHARE}  ${O_MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,vers=3.0,sec=ntlmssp,nosharesock,_netdev,x-systemd.automount  0  0"
  echo "$O_FSTAB_LINE" >> "$FSTAB_FILE"

  echo "[5/9] Searching for M-Drive in ${USERS_BASE}/Users0-Users9..."
  USERS_CACHE_DIR="${HOME_DIR}/.config/dtu-setup"
  USERS_CACHE="${USERS_CACHE_DIR}/ait-users-subdir"
  USERS_SUBDIR=""

  if [[ -f "$USERS_CACHE" ]]; then
    CACHED=$(cat "$USERS_CACHE")
    echo "  Checking cached subdir: $CACHED"
    if ! smbclient "//${M_SERVER}/${USERS_BASE}" -A "$CREDS_FILE" \
        -c "ls ${CACHED}/${USERNAME}" 2>&1 | grep -q "NT_STATUS_"; then
      USERS_SUBDIR="$CACHED"
      echo "  Cache valid: $USERS_SUBDIR"
    else
      warn "Cached subdir stale, re-searching..."
    fi
  fi

  if [[ -z "$USERS_SUBDIR" ]]; then
    for i in 0 1 2 3 4 5 6 7 8 9; do
      echo -n "  Trying Users${i}/${USERNAME}... "
      if ! smbclient "//${M_SERVER}/${USERS_BASE}" -A "$CREDS_FILE" \
          -c "ls Users${i}/${USERNAME}" 2>&1 | grep -q "NT_STATUS_"; then
        USERS_SUBDIR="Users${i}"
        echo "found!"
        break
      fi
      echo "not found"
    done
  fi

  if [[ -z "$USERS_SUBDIR" ]]; then
    fail "Could not find M-Drive folder for '$USERNAME' in Users0-Users9 on //${M_SERVER}/${USERS_BASE}."
    exit 1
  fi

  mkdir -p "$USERS_CACHE_DIR"
  echo "$USERS_SUBDIR" > "$USERS_CACHE"
  chown -R "$UID_NUM":"$GID_NUM" "$USERS_CACHE_DIR"
  ok "M-Drive subdir cached: ${USERS_SUBDIR} → ${USERS_CACHE}"

  M_SHARE="${USERS_BASE}/${USERS_SUBDIR}/${USERNAME}"

  echo "[6/9] Creating M-Drive mountpoint..."
  umount "$M_MOUNTPOINT" 2>/dev/null || true
  mkdir -p "$M_MOUNTPOINT"
  chown "$UID_NUM":"$GID_NUM" "$M_MOUNTPOINT"
  chmod 0770 "$M_MOUNTPOINT"

  echo "[7/9] Ensuring /etc/fstab entry for M-Drive..."
  sed -i "\|${M_SERVER}/Users/|d" "$FSTAB_FILE" 2>/dev/null || true
  M_FSTAB_LINE="//${M_SERVER}/${M_SHARE}  ${M_MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,vers=3.0,sec=ntlmssp,nosharesock,_netdev,x-systemd.automount  0  0"
  echo "$M_FSTAB_LINE" >> "$FSTAB_FILE"

  echo "[8/9] Reloading systemd..."
  systemctl daemon-reload
  systemctl restart mnt-Odrev.automount 2>/dev/null || systemctl start mnt-Odrev.automount || true
  systemctl restart mnt-Mdrev.automount 2>/dev/null || systemctl start mnt-Mdrev.automount || true

  echo "[9/9] Saving department config..."
  DTU_SETUP_DIR="/etc/dtu-setup"
  mkdir -p "$DTU_SETUP_DIR"
  echo "ait" > "${DTU_SETUP_DIR}/department"
  cat > "${DTU_SETUP_DIR}/drives.conf" <<DCONF
DEPARTMENT=ait
MOUNT_POINT=${M_MOUNTPOINT}
REMOTE_BASE=${M_MOUNTPOINT}
DCONF
  chmod 644 "${DTU_SETUP_DIR}/drives.conf"

  ok "AIT O-Drive & M-Drive configured."
  echo "    O-Drive: //${SERVER}/${O_SHARE} → ${O_MOUNTPOINT}"
  echo "    M-Drive: //${M_SERVER}/${M_SHARE} → ${M_MOUNTPOINT}"
  echo "    Local home folders are NOT symlinked — synced by sync-homedir."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sustain profile (default)
# ─────────────────────────────────────────────────────────────────────────────
DOMAIN="WIN"
SERVER="${SITE_FILE_SERVER_QUMULO}"
SHARE="sus-q\$"
MOUNTPOINT="/mnt/Qdrev"
CREDS_FILE="/home/$USERNAME/.smbcred-<fileserver>"
FSTAB_FILE="/etc/fstab"

if ! id "$USERNAME" >/dev/null 2>&1; then
  fail "User '$USERNAME' not found on this machine."
  exit 1
fi

UID_NUM="$(id -u "$USERNAME")"
GID_NUM="$(id -g "$USERNAME")"
HOME_DIR="/home/$USERNAME"

# Domain user may not have logged in yet — create home dir if missing
if [ ! -d "$HOME_DIR" ]; then
  echo "Creating home directory for $USERNAME..."
  mkdir -p "$HOME_DIR"
  chown "$UID_NUM":"$GID_NUM" "$HOME_DIR"
  chmod 0700 "$HOME_DIR"
fi

echo "Using UID=$UID_NUM GID=$GID_NUM"

echo "[1/6] Installing cifs-utils..."
zypper --non-interactive install cifs-utils

echo "[2/6] Creating mountpoint..."
umount "$MOUNTPOINT" 2>/dev/null || true
rm -f "$MOUNTPOINT" 2>/dev/null || true
mkdir -p "$MOUNTPOINT"
chown "$UID_NUM":"$GID_NUM" "$MOUNTPOINT"
chmod 0770 "$MOUNTPOINT"
rm -f "/home/${USERNAME}/.config/autostart/qdrev-mount.desktop" 2>/dev/null || true

echo "[3/6] Writing credentials file (chmod 600)..."
install -o "$USERNAME" -g "$GID_NUM" -m 600 /dev/null "$CREDS_FILE"
cat > "$CREDS_FILE" <<EOF
username=${USERNAME}
password=${PASSWORD}
domain=${DOMAIN}
EOF
chown "$USERNAME":"$GID_NUM" "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

echo "[4/6] Ensuring /etc/fstab entry exists..."
sed -i "/<fileserver>.*[Qq]drev/d" "$FSTAB_FILE" 2>/dev/null || true
sed -i "/ait-pqumulo.*sus-q/d" "$FSTAB_FILE" 2>/dev/null || true

FSTAB_LINE="//${SERVER}/${SHARE}  ${MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,vers=3.0,sec=ntlmssp,nosharesock,nodfs,_netdev,x-systemd.automount  0  0"
echo "$FSTAB_LINE" >> "$FSTAB_FILE"

echo "[5/5] Reloading systemd..."
systemctl daemon-reload

echo "[6/6] Saving department config..."
DTU_SETUP_DIR="/etc/dtu-setup"
mkdir -p "$DTU_SETUP_DIR"
echo "sustain" > "${DTU_SETUP_DIR}/department"
cat > "${DTU_SETUP_DIR}/drives.conf" <<DCONF
DEPARTMENT=sustain
MOUNT_POINT=${MOUNTPOINT}
REMOTE_BASE=${MOUNTPOINT}/Personal/${USERNAME}
DCONF
chmod 644 "${DTU_SETUP_DIR}/drives.conf"

ok "Q-Drive configured."
echo "    fstab: x-systemd.automount (auto-mounts on access)"
echo "    Local home folders are NOT symlinked — synced by sync-homedir."
echo "    A Konsole window will verify the mount on first login."
