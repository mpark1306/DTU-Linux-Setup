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

DOMAIN="WIN"
SERVER="<qumulo-server>"
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

echo "[5/8] Reloading systemd..."
systemctl daemon-reload

echo "[6/8] Setting up user folder symlinks to P-Drive..."
P_DIR="${MOUNTPOINT}/Personal/${USERNAME}"
BACKUP_SUFFIX="bak-$(date +%Y%m%d%H%M)"

for FOLDER in Desktop Documents Pictures Downloads; do
  LINK="${HOME_DIR}/${FOLDER}"
  TARGET="${P_DIR}/${FOLDER}"

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

echo "[7/8] Installing first-login mount..."

# Script that runs inside Konsole on first login
FIRST_RUN_SCRIPT="/usr/local/bin/dtu-qdrive-mount.sh"
cat > "$FIRST_RUN_SCRIPT" <<'FIRSTRUN'
#!/usr/bin/env bash
echo "=========================================================="
echo "  Q-Drive Mount — /mnt/Qdrev"
echo "=========================================================="
echo ""
echo "Attempting to mount Q-Drive..."

if mount /mnt/Qdrev 2>&1; then
  echo ""
  if ls /mnt/Qdrev >/dev/null 2>&1; then
    echo "Q-Drive mounted successfully!"
    ls /mnt/Qdrev | head -n 10
  else
    echo "Mount returned OK but directory is empty."
  fi
else
  echo ""
  echo "Q-Drive mount failed."
  echo "You can retry later with: sudo mount /mnt/Qdrev"
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
Name=DTU Q-Drive Mount
Comment=First-time Q-Drive mount
Exec=konsole --separate -e bash /usr/local/bin/dtu-qdrive-mount.sh
Terminal=false
X-KDE-autostart-phase=2
DESKTOP
chown -R "$UID_NUM":"$GID_NUM" "${HOME_DIR}/.config/autostart"

echo "[8/8] Done."
ok "Q-Drive configured."
echo "    fstab: x-systemd.automount (auto-mounts on access)"
echo "    Folder symlinks: ~/Desktop ~/Documents ~/Pictures ~/Downloads → P-Drive"
echo "    A Konsole window will verify the mount on first login."
