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

DOMAIN="WIN"
SERVER="<fileserver>"
SHARE_PATH="Qdrev/SUS"
MOUNTPOINT="/mnt/Qdrev"
P_SHARE_PATH="Qdrev/SUS/Personal/${USERNAME}"
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
apt-get install -y cifs-utils >/dev/null

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
FSTAB_LINE="//${SERVER}/${SHARE_PATH}  ${MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,serverino,_netdev,x-systemd.automount  0  0"

if grep -qE "^[[:space:]]*//${SERVER}/${SHARE_PATH}[[:space:]]" "$FSTAB_FILE"; then
  echo "fstab entry already exists — updating..."
  sed -i "\|^[[:space:]]*//${SERVER}/${SHARE_PATH}[[:space:]]|d" "$FSTAB_FILE"
fi
echo "$FSTAB_LINE" >> "$FSTAB_FILE"

if mount | grep -qE "[[:space:]]${MOUNTPOINT}[[:space:]]"; then
  echo "Already mounted — unmounting for clean state..."
  umount "$MOUNTPOINT" || true
fi

echo "[5/8] Ensuring /etc/fstab entry for P-Drive..."
P_FSTAB_LINE="//${SERVER}/${P_SHARE_PATH}  ${P_MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,serverino,_netdev,x-systemd.automount  0  0"

if grep -qE "^[[:space:]]*//${SERVER}/${P_SHARE_PATH}[[:space:]]" "$FSTAB_FILE"; then
  echo "fstab entry already exists — updating..."
  sed -i "\|^[[:space:]]*//${SERVER}/${P_SHARE_PATH}[[:space:]]|d" "$FSTAB_FILE"
fi
echo "$P_FSTAB_LINE" >> "$FSTAB_FILE"

if mount | grep -qE "[[:space:]]${P_MOUNTPOINT}[[:space:]]"; then
  echo "Already mounted — unmounting for clean state..."
  umount "$P_MOUNTPOINT" || true
fi

echo "[6/8] Reloading systemd and starting automount units..."
systemctl daemon-reload
systemctl restart mnt-Qdrev.automount 2>/dev/null || systemctl start mnt-Qdrev.automount || true
systemctl restart mnt-Personal.automount 2>/dev/null || systemctl start mnt-Personal.automount || true

echo "[7/9] Setting up user folder symlinks to P-Drive..."
BACKUP_SUFFIX="bak-$(date +%Y%m%d%H%M)"

for FOLDER in Desktop Documents Pictures Downloads; do
  LINK="${HOME_DIR}/${FOLDER}"
  TARGET="${P_MOUNTPOINT}/${FOLDER}"

  if [ -L "$LINK" ]; then
    EXISTING_TARGET="$(readlink "$LINK")"
    if [ "$EXISTING_TARGET" = "$TARGET" ]; then
      echo "  ${FOLDER} → already points to ${TARGET}"
      continue
    fi
    echo "  ${FOLDER} → removing old symlink (was → ${EXISTING_TARGET})"
    rm -f "$LINK"
  elif [ -d "$LINK" ]; then
    echo "  ${FOLDER} → backing up existing directory to ${FOLDER}.${BACKUP_SUFFIX}"
    mv "$LINK" "${LINK}.${BACKUP_SUFFIX}"
  elif [ -e "$LINK" ]; then
    echo "  ${FOLDER} → backing up existing file to ${FOLDER}.${BACKUP_SUFFIX}"
    mv "$LINK" "${LINK}.${BACKUP_SUFFIX}"
  fi

  ln -sf "$TARGET" "$LINK"
  chown -h "$UID_NUM":"$GID_NUM" "$LINK"
  echo "  ${FOLDER} → ${TARGET}"
done

echo "[8/9] Installing first-login mount..."

# Script that runs inside Konsole on first login
FIRST_RUN_SCRIPT="/usr/local/bin/dtu-qdrive-mount.sh"
cat > "$FIRST_RUN_SCRIPT" <<'FIRSTRUN'
#!/usr/bin/env bash
echo "=========================================================="
echo "  Q-Drive & P-Drive Mount"
echo "=========================================================="
echo ""

echo "Attempting to access Q-Drive (/mnt/Qdrev)..."
# x-systemd.automount triggers mount on access — just touch the directory
if ls /mnt/Qdrev >/dev/null 2>&1; then
  echo "Q-Drive mounted successfully!"
  ls /mnt/Qdrev | head -n 10
else
  echo "Q-Drive access failed — automount may not be ready yet."
  echo "Try: ls /mnt/Qdrev   (systemd will auto-mount on access)"
fi

echo ""
echo "Attempting to access P-Drive (/mnt/Personal)..."
if ls /mnt/Personal >/dev/null 2>&1; then
  echo "P-Drive mounted successfully!"
  ls /mnt/Personal | head -n 10
else
  echo "P-Drive access failed — automount may not be ready yet."
  echo "Try: ls /mnt/Personal   (systemd will auto-mount on access)"
fi

# Remove the autostart entry so this doesn't run again
rm -f "$HOME/.config/autostart/dtu-qdrive-mount.desktop"

echo ""
echo "Press Enter to close this window..."
read -r
FIRSTRUN
chmod 755 "$FIRST_RUN_SCRIPT"

# Create autostart desktop entry for the user
mkdir -p "${HOME_DIR}/.config/autostart"
chown "$UID_NUM":"$GID_NUM" "${HOME_DIR}/.config"
cat > "${HOME_DIR}/.config/autostart/dtu-qdrive-mount.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=DTU Q-Drive & P-Drive Mount
Comment=First-time Q-Drive and P-Drive mount
Exec=konsole --separate -e bash /usr/local/bin/dtu-qdrive-mount.sh
Terminal=false
X-KDE-autostart-phase=2
DESKTOP
chown -R "$UID_NUM":"$GID_NUM" "${HOME_DIR}/.config/autostart"

echo "[9/9] Done."
ok "Q-Drive & P-Drive configured."
echo "    Q-Drive: //${SERVER}/${SHARE_PATH} → ${MOUNTPOINT}"
echo "    P-Drive: //${SERVER}/${P_SHARE_PATH} → ${P_MOUNTPOINT}"
echo "    Folder symlinks: ~/Desktop ~/Documents ~/Pictures ~/Downloads → P-Drive"
echo "    fstab: x-systemd.automount (auto-mounts on access)"
echo "    A Konsole window will verify the mounts on first login."
