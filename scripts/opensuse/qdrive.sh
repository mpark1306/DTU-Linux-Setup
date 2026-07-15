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
  # AIT's personal M-Drive and shared O-Drive both live on the central
  # personal-home server (SITE_MDRIVE_SERVER, e.g. the Qumulo backend).
  SERVER="${SITE_MDRIVE_SERVER:-$SITE_FILE_SERVER}"
  USERS_BASE="${SITE_MDRIVE_BASE:-Users\$}"   # personal home top share (literal $)
  O_SHARE="${SITE_AIT_O_SHARE:-}"             # fixed shared dept share, e.g. 2adm$/AIT
  M_MOUNTPOINT="/mnt/Mdrev"
  O_MOUNTPOINT="/mnt/Odrev"
  FSTAB_FILE="/etc/fstab"

  if ! id "$USERNAME" >/dev/null 2>&1; then
    fail "User '$USERNAME' not found on this machine."
    exit 1
  fi

  UID_NUM="$(id -u "$USERNAME")"
  GID_NUM="$(id -g "$USERNAME")"
  HOME_DIR="/home/$USERNAME"
  CREDS_FILE="${HOME_DIR}/.smbcred-$(printf '%s' "$SERVER" | cut -d. -f1)"

  if [ ! -d "$HOME_DIR" ]; then
    echo "Creating home directory for $USERNAME..."
    mkdir -p "$HOME_DIR"
    chown "$UID_NUM":"$GID_NUM" "$HOME_DIR"
    chmod 0700 "$HOME_DIR"
  fi

  echo "Using UID=$UID_NUM GID=$GID_NUM  server=$SERVER"

  echo "[1/7] Installing cifs-utils..."
  zypper --non-interactive install cifs-utils

  echo "[2/7] Writing credentials file (chmod 600)..."
  install -o "$USERNAME" -g "$GID_NUM" -m 600 /dev/null "$CREDS_FILE"
  cat > "$CREDS_FILE" <<EOF
username=${USERNAME}
password=${PASSWORD}
domain=${DOMAIN}
EOF
  chown "$USERNAME":"$GID_NUM" "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"

  # One fstab backup up front (both shares edited below)
  [[ -f "$FSTAB_FILE" ]] && cp -a "$FSTAB_FILE" "${FSTAB_FILE}.dtu.bak.$(date +%s)"

  echo "[3/7] Scanning ${USERS_BASE} for your personal M-Drive folder (test-mount)..."
  M_CACHE="${HOME_DIR}/.config/dtu-setup/ait-mdrive-subdir"
  if ! M_SUBDIR="$(cifs_find_mdrive_subdir "$SERVER" "$USERS_BASE" "$USERNAME" "$CREDS_FILE" "$UID_NUM" "$GID_NUM" "$M_CACHE")"; then
    fail "Could not test-mount '${USERNAME}' under ${USERS_BASE}/Users0-9 on //${SERVER}. Wrong password, or folder outside Users0-9."
    exit 1
  fi
  M_SHARE="${USERS_BASE}/${M_SUBDIR}/${USERNAME}"
  ok "M-Drive personal folder: ${M_SHARE}"

  echo "[4/7] Writing M-Drive fstab entry..."
  cifs_setup_share "$SERVER" "$M_SHARE" "$M_MOUNTPOINT" "$CREDS_FILE" "$UID_NUM" "$GID_NUM"
  ok "M-Drive → ${M_MOUNTPOINT}"

  echo "[5/7] Verifying + writing O-Drive fstab entry (fixed share, no scan)..."
  if [[ -n "$O_SHARE" ]]; then
    if cifs_test_mount "$SERVER" "$O_SHARE" "$CREDS_FILE" "$UID_NUM" "$GID_NUM"; then
      ok "O-Drive reachable: ${O_SHARE}"
    else
      warn "O-Drive test-mount failed (permissions? not an AIT member?). Adding anyway — nofail means it just won't mount until access is granted."
    fi
    cifs_setup_share "$SERVER" "$O_SHARE" "$O_MOUNTPOINT" "$CREDS_FILE" "$UID_NUM" "$GID_NUM"
    ok "O-Drive → ${O_MOUNTPOINT}"
  else
    warn "SITE_AIT_O_SHARE is empty — skipping O-Drive mount."
  fi

  echo "[6/7] Reloading systemd and starting automount units..."
  systemctl daemon-reload
  cifs_start_automount "$M_MOUNTPOINT"
  [[ -n "$O_SHARE" ]] && cifs_start_automount "$O_MOUNTPOINT"

  echo "[7/7] Saving department config..."
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
  echo "    M-Drive: //${SERVER}/${M_SHARE} → ${M_MOUNTPOINT}"
  [[ -n "$O_SHARE" ]] && echo "    O-Drive: //${SERVER}/${O_SHARE} → ${O_MOUNTPOINT}"
  echo "    Local home folders are NOT symlinked — synced by sync-homedir."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sustain profile (default)
# ─────────────────────────────────────────────────────────────────────────────
DOMAIN="WIN"
# Prefer direct Qumulo target to avoid DFS referral issues on newer kernels.
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

echo "[1/7] Installing cifs-utils..."
zypper --non-interactive install cifs-utils samba-client

echo "[2/7] Creating mountpoints..."
umount "$MOUNTPOINT" 2>/dev/null || true
rm -f "$MOUNTPOINT" 2>/dev/null || true
mkdir -p "$MOUNTPOINT"
chown "$UID_NUM":"$GID_NUM" "$MOUNTPOINT"
chmod 0770 "$MOUNTPOINT"
umount "$P_MOUNTPOINT" 2>/dev/null || true
rm -f "$P_MOUNTPOINT" 2>/dev/null || true
mkdir -p "$P_MOUNTPOINT"
chown "$UID_NUM":"$GID_NUM" "$P_MOUNTPOINT"
chmod 0770 "$P_MOUNTPOINT"
rm -f "/home/${USERNAME}/.config/autostart/qdrev-mount.desktop" 2>/dev/null || true

echo "[3/7] Writing credentials file (chmod 600)..."
install -o "$USERNAME" -g "$GID_NUM" -m 600 /dev/null "$CREDS_FILE"
cat > "$CREDS_FILE" <<EOF
username=${USERNAME}
password=${PASSWORD}
domain=${DOMAIN}
EOF
chown "$USERNAME":"$GID_NUM" "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

echo "[4/7] Ensuring /etc/fstab entry for Q-Drive..."
sed -i "/<fileserver>.*[Qq]drev/d" "$FSTAB_FILE" 2>/dev/null || true
sed -i "/ait-pqumulo.*sus-q/d" "$FSTAB_FILE" 2>/dev/null || true
sed -i "\|[[:space:]]${MOUNTPOINT}[[:space:]].*cifs|d" "$FSTAB_FILE" 2>/dev/null || true
sed -i "\|//${SITE_FILE_SERVER}/${SITE_SUSTAIN_Q_SHARE}[[:space:]]|d" "$FSTAB_FILE" 2>/dev/null || true

FSTAB_LINE="//${SERVER}/${Q_SHARE_PATH}  ${MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,${CIFS_OPTS},_netdev,x-systemd.automount  0  0"
echo "$FSTAB_LINE" >> "$FSTAB_FILE"

echo "[5/7] Ensuring /etc/fstab entry for P-Drive..."
P_FSTAB_LINE="//${SERVER}/${P_SHARE_PATH}  ${P_MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,${CIFS_OPTS},_netdev,x-systemd.automount  0  0"
sed -i "\|[[:space:]]${P_MOUNTPOINT}[[:space:]].*cifs|d" "$FSTAB_FILE" 2>/dev/null || true
sed -i "\|//${SITE_FILE_SERVER}/${SITE_SUSTAIN_P_SUBPATH}/|d" "$FSTAB_FILE" 2>/dev/null || true
echo "$P_FSTAB_LINE" >> "$FSTAB_FILE"

# ─── M-Drive (personal home share on Users0-9) ──────────────────────────────
# The personal M: drive lives on the central home server (SITE_MDRIVE_SERVER)
# and applies to Sustain users too. Mounted on request via the same proven
# test-mount discovery as the AIT profile, but NOT used by sync-homedir
# (sync continues to target the P-Drive on Qumulo).
M_SERVER="${SITE_MDRIVE_SERVER:-$SITE_FILE_SERVER}"
M_USERS_BASE="${SITE_MDRIVE_BASE:-Users\$}"
M_MOUNTPOINT="/mnt/Mdrev"
M_SUBDIR=""

echo "[5b/7] Scanning ${M_USERS_BASE} for M-Drive on //${M_SERVER} (test-mount)..."
M_CACHE="${HOME_DIR}/.config/dtu-setup/sustain-mdrive-subdir"
if M_SUBDIR="$(cifs_find_mdrive_subdir "$M_SERVER" "$M_USERS_BASE" "$USERNAME" "$CREDS_FILE" "$UID_NUM" "$GID_NUM" "$M_CACHE")"; then
  M_SHARE_PATH="${M_USERS_BASE}/${M_SUBDIR}/${USERNAME}"
  ok "M-Drive personal folder: ${M_SHARE_PATH}"
  echo "[5c/7] Writing M-Drive fstab entry..."
  cifs_setup_share "$M_SERVER" "$M_SHARE_PATH" "$M_MOUNTPOINT" "$CREDS_FILE" "$UID_NUM" "$GID_NUM"
  ok "M-Drive → ${M_MOUNTPOINT}"
else
  M_SUBDIR=""
  warn "Could not test-mount M-Drive for '$USERNAME' under ${M_USERS_BASE}/Users0-9 on //${M_SERVER}. Skipping M-Drive."
fi

echo "[6/7] Reloading systemd..."
systemctl daemon-reload
systemctl restart mnt-Qdrev.automount 2>/dev/null || systemctl start mnt-Qdrev.automount || true
systemctl restart mnt-Personal.automount 2>/dev/null || systemctl start mnt-Personal.automount || true
if [[ -n "${M_SUBDIR:-}" ]]; then
  cifs_start_automount "$M_MOUNTPOINT"
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
echo "    fstab: x-systemd.automount (auto-mounts on access)"
echo "    Q-Drive: //${SERVER}/${Q_SHARE_PATH} → ${MOUNTPOINT}"
echo "    P-Drive: //${SERVER}/${P_SHARE_PATH} → ${P_MOUNTPOINT}"
if [[ -n "${M_SUBDIR:-}" ]]; then
  echo "    M-Drive: //${M_SERVER}/${M_SHARE_PATH} → ${M_MOUNTPOINT} (no sync)"
fi
echo "    Local home folders are NOT symlinked — synced by sync-homedir."
echo "    A Konsole window will verify the mount on first login."
