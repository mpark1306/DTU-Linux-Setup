#!/usr/bin/env bash
###############################################################################
# fix-qdrive-user.sh — Change Q-Drive/P-Drive credentials from adm account
#                       to the user's own domain account.
#
# Usage:  sudo bash fix-qdrive-user.sh <username>
#   e.g.  sudo bash fix-qdrive-user.sh lkjo
#
# Will prompt for the user's domain password.
###############################################################################
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo $0 <username>"; exit 1; fi
if [[ -z "${1:-}" ]]; then echo "Usage: sudo $0 <username>"; exit 1; fi

USERNAME="$1"
HOME_DIR="/home/$USERNAME"
DOMAIN="WIN"
SERVER="ait-pdfs"

if ! id "$USERNAME" &>/dev/null; then echo "User '$USERNAME' not found."; exit 1; fi
UID_NUM="$(id -u "$USERNAME")"
GID_NUM="$(id -g "$USERNAME")"

echo "=== Fixing Q-Drive credentials for $USERNAME ==="
echo "    Changing from adm-lkjo-byg → $USERNAME"
echo ""

# Get password
read -rsp "Enter domain password for $USERNAME: " PASSWORD
echo ""
if [[ -z "$PASSWORD" ]]; then echo "Password required."; exit 1; fi

CREDS_FILE="$HOME_DIR/.smbcred-ait-pdfs"
Q_MOUNT="/mnt/Qdrev"
P_MOUNT="/mnt/Personal"
SHARE_PATH="Qdrev/SUS"
P_SHARE_PATH="Qdrev/SUS/Personal/${USERNAME}"

echo "[1/4] Updating credentials file..."
cat > "$CREDS_FILE" <<EOF
username=${USERNAME}
password=${PASSWORD}
domain=${DOMAIN}
EOF
chown "$USERNAME":"$GID_NUM" "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
echo "  ✅ Credentials updated in $CREDS_FILE"

echo "[2/4] Updating /etc/fstab entries..."
FSTAB="/etc/fstab"

# Remove old entries (may reference adm-* user's creds file)
sed -i "\|//${SERVER}/${SHARE_PATH}[[:space:]]|d" "$FSTAB"
sed -i "\|//${SERVER}/${P_SHARE_PATH}[[:space:]]|d" "$FSTAB"
# Also remove any old P-drive line referencing the adm account
sed -i "\|//${SERVER}/Qdrev/SUS/Personal/adm-|d" "$FSTAB"

# Add correct entries
Q_LINE="//${SERVER}/${SHARE_PATH}  ${Q_MOUNT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,serverino,_netdev,x-systemd.automount  0  0"
P_LINE="//${SERVER}/${P_SHARE_PATH}  ${P_MOUNT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,serverino,_netdev,x-systemd.automount  0  0"

echo "$Q_LINE" >> "$FSTAB"
echo "$P_LINE" >> "$FSTAB"
echo "  ✅ fstab updated (credentials=$CREDS_FILE)"

echo "[3/4] Remounting drives..."
umount "$Q_MOUNT" 2>/dev/null || true
umount "$P_MOUNT" 2>/dev/null || true
systemctl daemon-reload
systemctl restart mnt-Qdrev.automount 2>/dev/null || true
systemctl restart mnt-Personal.automount 2>/dev/null || true

# Trigger automount + verify
sleep 1
ls "$Q_MOUNT" >/dev/null 2>&1 || true
sleep 2

if mountpoint -q "$Q_MOUNT" 2>/dev/null; then
    echo "  ✅ Q-Drive mounted"
else
    echo "  ⚠️  Q-Drive not mounted — will auto-mount on next access"
fi

echo "[4/4] Updating CUPS printer credentials (if present)..."
CUPS_CREDS="/etc/cups/print-sustain.creds"
if [[ -f "$CUPS_CREDS" ]]; then
    cat > "$CUPS_CREDS" <<EOF
username=WIN\\\\${USERNAME}
password=${PASSWORD}
EOF
    chown root:lp "$CUPS_CREDS"
    chmod 640 "$CUPS_CREDS"
    systemctl restart cups 2>/dev/null || true
    echo "  ✅ CUPS printer credentials updated"
else
    echo "  ✓ No CUPS credentials file found — skipping"
fi

echo ""
echo "=== Done! ==="
echo "  Q-Drive + P-Drive now use $USERNAME's credentials"
echo "  User should log out and back in to complete."
