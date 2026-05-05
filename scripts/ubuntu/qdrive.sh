#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: Q-Drive & P-Drive CIFS mount
# Env: DTU_USERNAME, DTU_PASSWORD (optional – falls back to interactive)
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Q-Drive & P-Drive – Map CIFS shares from \\\\<fileserver>"

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
  banner "O-Drive & M-Drive – AIT CIFS mount"

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

  echo "[1/9] Installing cifs-utils + smbclient..."
  apt_wait
  apt-get update -qq 2>/dev/null || true
  apt-get install -y cifs-utils smbclient >/dev/null

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
  mkdir -p "$O_MOUNTPOINT"
  chown "$UID_NUM":"$GID_NUM" "$O_MOUNTPOINT"
  chmod 0770 "$O_MOUNTPOINT"

  echo "[4/9] Ensuring /etc/fstab entry for O-Drive..."
  O_FSTAB_LINE="//${SERVER}/${O_SHARE}  ${O_MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,serverino,_netdev,x-systemd.automount  0  0"
  if grep -qE "^[[:space:]]*//${SERVER}/${O_SHARE}[[:space:]]" "$FSTAB_FILE"; then
    echo "fstab entry already exists — updating..."
    sed -i "\|^[[:space:]]*//${SERVER}/${O_SHARE}[[:space:]]|d" "$FSTAB_FILE"
  fi
  echo "$O_FSTAB_LINE" >> "$FSTAB_FILE"

  echo "[5/9] Searching for M-Drive in ${USERS_BASE}/Users0-Users9..."
  # Check cache first
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

  # Save cache
  mkdir -p "$USERS_CACHE_DIR"
  echo "$USERS_SUBDIR" > "$USERS_CACHE"
  chown -R "$UID_NUM":"$GID_NUM" "$USERS_CACHE_DIR"
  ok "M-Drive subdir cached: ${USERS_SUBDIR} → ${USERS_CACHE}"

  M_SHARE="${USERS_BASE}/${USERS_SUBDIR}/${USERNAME}"

  echo "[6/9] Creating M-Drive mountpoint..."
  mkdir -p "$M_MOUNTPOINT"
  chown "$UID_NUM":"$GID_NUM" "$M_MOUNTPOINT"
  chmod 0770 "$M_MOUNTPOINT"

  echo "[7/9] Ensuring /etc/fstab entry for M-Drive..."
  M_FSTAB_LINE="//${M_SERVER}/${M_SHARE}  ${M_MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,serverino,_netdev,x-systemd.automount  0  0"
  if grep -qE "^[[:space:]]*//${M_SERVER}/Users/" "$FSTAB_FILE"; then
    echo "fstab entry already exists — updating..."
    sed -i "\|^[[:space:]]*//${M_SERVER}/Users/|d" "$FSTAB_FILE"
  fi
  echo "$M_FSTAB_LINE" >> "$FSTAB_FILE"

  echo "[8/9] Reloading systemd and starting automount units..."
  systemctl daemon-reload
  systemctl restart mnt-Odrev.automount 2>/dev/null || systemctl start mnt-Odrev.automount || true
  systemctl restart mnt-Mdrev.automount 2>/dev/null || systemctl start mnt-Mdrev.automount || true

  echo "[9/9] Saving department config..."
  DTU_SETUP_DIR="/etc/dtu-setup"
  mkdir -p "$DTU_SETUP_DIR"
  echo "ait" > "${DTU_SETUP_DIR}/department"
  # Store drive paths for sync-homedir
  cat > "${DTU_SETUP_DIR}/drives.conf" <<DCONF
DEPARTMENT=ait
MOUNT_POINT=${M_MOUNTPOINT}
REMOTE_BASE=${M_MOUNTPOINT}
DCONF
  chmod 644 "${DTU_SETUP_DIR}/drives.conf"

  ok "AIT O-Drive & M-Drive configured."
  echo "    O-Drive: //${SERVER}/${O_SHARE} → ${O_MOUNTPOINT}"
  echo "    M-Drive: //${M_SERVER}/${M_SHARE} → ${M_MOUNTPOINT}"
  echo "    Local home folders (Desktop, Documents etc.) are NOT symlinked."
  echo "    sync-homedir.sh syncs them to M-Drive when the drive is reachable."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sustain profile (default)
#
# We mount directly against the Qumulo backend (SITE_FILE_SERVER_QUMULO)
# instead of the DFS root konfigureret via site.conf, because DFS referral
# resolution in the Linux kernel CIFS client is unreliable — particularly
# over VPN (split tunnel) and on kernels 6.19+. Symptom: Q-drive mounts but
# /mnt/Personal fails with "mount.cifs: permission denied" because the
# Personal/<user> path is a DFS junction to Qumulo.
# ─────────────────────────────────────────────────────────────────────────────
DOMAIN="WIN"
# Prefer the direct Qumulo target; fall back to the DFS root only if Qumulo
# is not configured in site.conf.
if [[ -n "${SITE_FILE_SERVER_QUMULO:-}" ]]; then
  SERVER="${SITE_FILE_SERVER_QUMULO}"
  Q_SHARE_PATH='sus-q$'
  P_SHARE_PATH='sus-q$/Personal/'"${USERNAME}"
  CIFS_OPTS="vers=3.0,sec=ntlmssp,nosharesock,nodfs"
else
  SERVER="${SITE_FILE_SERVER}"
  Q_SHARE_PATH="${SITE_SUSTAIN_Q_SHARE}"
  P_SHARE_PATH="${SITE_SUSTAIN_P_SUBPATH}/${USERNAME}"
  CIFS_OPTS="serverino"
fi
SHARE_PATH="$Q_SHARE_PATH"
MOUNTPOINT="/mnt/Qdrev"
P_MOUNTPOINT="/mnt/Personal"
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

echo "[1/8] Installing cifs-utils..."
apt_wait
apt-get update -qq 2>/dev/null || true
apt-get install -y cifs-utils smbclient >/dev/null

echo "[2/8] Creating mountpoints..."
mkdir -p "$MOUNTPOINT"
chown "$UID_NUM":"$GID_NUM" "$MOUNTPOINT"
chmod 0770 "$MOUNTPOINT"
mkdir -p "$P_MOUNTPOINT"
chown "$UID_NUM":"$GID_NUM" "$P_MOUNTPOINT"
chmod 0770 "$P_MOUNTPOINT"

echo "[3/8] Writing credentials file (chmod 600)..."
install -o "$USERNAME" -g "$GID_NUM" -m 600 /dev/null "$CREDS_FILE"
cat > "$CREDS_FILE" <<EOF
username=${USERNAME}
password=${PASSWORD}
domain=${DOMAIN}
EOF
chown "$USERNAME":"$GID_NUM" "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

echo "[4/8] Ensuring /etc/fstab entry for Q-Drive..."
FSTAB_LINE="//${SERVER}/${SHARE_PATH}  ${MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,${CIFS_OPTS},_netdev,x-systemd.automount  0  0"

# Remove any prior entry for this mountpoint or for the legacy DFS path.
sed -i "\|[[:space:]]${MOUNTPOINT}[[:space:]].*cifs|d" "$FSTAB_FILE" 2>/dev/null || true
sed -i "\|//${SITE_FILE_SERVER}/${SITE_SUSTAIN_Q_SHARE}[[:space:]]|d" "$FSTAB_FILE" 2>/dev/null || true
echo "$FSTAB_LINE" >> "$FSTAB_FILE"

if mount | grep -qE "[[:space:]]${MOUNTPOINT}[[:space:]]"; then
  echo "Already mounted — unmounting for clean state..."
  umount "$MOUNTPOINT" || true
fi

echo "[5/8] Ensuring /etc/fstab entry for P-Drive..."
P_FSTAB_LINE="//${SERVER}/${P_SHARE_PATH}  ${P_MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,${CIFS_OPTS},_netdev,x-systemd.automount  0  0"

sed -i "\|[[:space:]]${P_MOUNTPOINT}[[:space:]].*cifs|d" "$FSTAB_FILE" 2>/dev/null || true
sed -i "\|//${SITE_FILE_SERVER}/${SITE_SUSTAIN_P_SUBPATH}/|d" "$FSTAB_FILE" 2>/dev/null || true
echo "$P_FSTAB_LINE" >> "$FSTAB_FILE"

if mount | grep -qE "[[:space:]]${P_MOUNTPOINT}[[:space:]]"; then
  echo "Already mounted — unmounting for clean state..."
  umount "$P_MOUNTPOINT" || true
fi

# ─── M-Drive (personal home share on <fileserver> Users/Users0-9) ───────────────
# Mounted for Sustain users on request, but NOT used by sync-homedir
# (sync continues to target the P-Drive on Qumulo).
M_SERVER="${SITE_FILE_SERVER}"
M_USERS_BASE="${SITE_USERS_BASE:-Users}"
M_MOUNTPOINT="/mnt/Mdrev"

echo "[5b/8] Searching for M-Drive in ${M_USERS_BASE}/Users0-Users9 on //${M_SERVER}..."
M_USERS_CACHE_DIR="${HOME_DIR}/.config/dtu-setup"
M_USERS_CACHE="${M_USERS_CACHE_DIR}/sustain-mdrive-subdir"
M_USERS_SUBDIR=""

if [[ -f "$M_USERS_CACHE" ]]; then
  CACHED=$(cat "$M_USERS_CACHE")
  echo "  Checking cached subdir: $CACHED"
  if ! smbclient "//${M_SERVER}/${M_USERS_BASE}" -A "$CREDS_FILE" \
      -c "ls ${CACHED}/${USERNAME}" 2>&1 | grep -q "NT_STATUS_"; then
    M_USERS_SUBDIR="$CACHED"
    echo "  Cache valid: $M_USERS_SUBDIR"
if [[ -n "${M_USERS_SUBDIR:-}" ]]; then
  echo "    M-Drive: //${M_SERVER}/${M_SHARE_PATH} → ${M_MOUNTPOINT} (no sync)"
fi
  else
    warn "Cached subdir stale, re-searching..."
  fi
fi

if [[ -z "$M_USERS_SUBDIR" ]]; then
  for i in 0 1 2 3 4 5 6 7 8 9; do
    echo -n "  Trying Users${i}/${USERNAME}... "
    if ! smbclient "//${M_SERVER}/${M_USERS_BASE}" -A "$CREDS_FILE" \
        -c "ls Users${i}/${USERNAME}" 2>&1 | grep -q "NT_STATUS_"; then
      M_USERS_SUBDIR="Users${i}"
      echo "found!"
      break
    fi
    echo "not found"
  done
fi

if [[ -z "$M_USERS_SUBDIR" ]]; then
  warn "Could not find M-Drive folder for '$USERNAME' in Users0-Users9 on //${M_SERVER}/${M_USERS_BASE}. Skipping M-Drive."
else
  mkdir -p "$M_USERS_CACHE_DIR"
  echo "$M_USERS_SUBDIR" > "$M_USERS_CACHE"
  chown -R "$UID_NUM":"$GID_NUM" "$M_USERS_CACHE_DIR"
  ok "M-Drive subdir cached: ${M_USERS_SUBDIR} → ${M_USERS_CACHE}"

  M_SHARE_PATH="${M_USERS_BASE}/${M_USERS_SUBDIR}/${USERNAME}"

  echo "[5c/8] Creating M-Drive mountpoint..."
  mkdir -p "$M_MOUNTPOINT"
  chown "$UID_NUM":"$GID_NUM" "$M_MOUNTPOINT"
  chmod 0770 "$M_MOUNTPOINT"

  echo "[5d/8] Ensuring /etc/fstab entry for M-Drive..."
  M_FSTAB_LINE="//${M_SERVER}/${M_SHARE_PATH}  ${M_MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,serverino,_netdev,x-systemd.automount  0  0"
  sed -i "\|[[:space:]]${M_MOUNTPOINT}[[:space:]].*cifs|d" "$FSTAB_FILE" 2>/dev/null || true
  sed -i "\|//${M_SERVER}/${M_USERS_BASE}/|d" "$FSTAB_FILE" 2>/dev/null || true
  echo "$M_FSTAB_LINE" >> "$FSTAB_FILE"

  if mount | grep -qE "[[:space:]]${M_MOUNTPOINT}[[:space:]]"; then
    echo "Already mounted — unmounting for clean state..."
    umount "$M_MOUNTPOINT" || true
  fi
fi

echo "[6/8] Reloading systemd and starting automount units..."
systemctl daemon-reload
systemctl restart mnt-Qdrev.automount 2>/dev/null || systemctl start mnt-Qdrev.automount || true
systemctl restart mnt-Personal.automount 2>/dev/null || systemctl start mnt-Personal.automount || true
if [[ -n "${M_USERS_SUBDIR:-}" ]]; then
  systemctl restart mnt-Mdrev.automount 2>/dev/null || systemctl start mnt-Mdrev.automount || true
fi

echo "[7/7] Saving department config..."
DTU_SETUP_DIR="/etc/dtu-setup"
mkdir -p "$DTU_SETUP_DIR"
echo "sustain" > "${DTU_SETUP_DIR}/department"
cat > "${DTU_SETUP_DIR}/drives.conf" <<DCONF
DEPARTMENT=sustain
MOUNT_POINT=${MOUNTPOINT}
REMOTE_BASE=${MOUNTPOINT}/Personal/${USERNAME}
DCONF
chmod 644 "${DTU_SETUP_DIR}/drives.conf"

ok "Q-Drive & P-Drive configured."
echo "    Q-Drive: //${SERVER}/${SHARE_PATH} → ${MOUNTPOINT}"
echo "    P-Drive: //${SERVER}/${P_SHARE_PATH} → ${P_MOUNTPOINT}"
echo "    Local home folders (Desktop, Documents etc.) are NOT symlinked."
echo "    sync-homedir.sh syncs them to P-Drive when the drive is reachable."
