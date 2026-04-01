#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: OneDrive for Business
# Env: DTU_USERNAME (optional – falls back to interactive)
#
# Uses the abraunegg OneDrive Client for Linux from OBS repository.
# Authentication is interactive (browser-based) — must be done by the user.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "OneDrive for Business (abraunegg client)"

# Require username via environment (interactive prompts hang in GUI)
if [[ -z "${DTU_USERNAME:-}" ]]; then
  fail "DTU_USERNAME must be set. Run via the GUI or export it."
  exit 1
fi

USERNAME="$DTU_USERNAME"

if ! id "$USERNAME" >/dev/null 2>&1; then
  fail "User '$USERNAME' not found on this machine."
  exit 1
fi

HOME_DIR="$(eval echo "~$USERNAME")"
ONEDRIVE_DIR="${HOME_DIR}/OneDrive"
CONFIG_DIR="${HOME_DIR}/.config/onedrive"
UID_NUM="$(id -u "$USERNAME")"
GID_NUM="$(id -g "$USERNAME")"

# Domain user may not have logged in yet — create home dir if missing
if [ ! -d "$HOME_DIR" ]; then
  echo "Creating home directory for $USERNAME..."
  mkdir -p "$HOME_DIR"
  chown "$UID_NUM":"$GID_NUM" "$HOME_DIR"
  chmod 0700 "$HOME_DIR"
fi

echo "Target user : $USERNAME (UID=$UID_NUM GID=$GID_NUM)"
echo "Sync dir    : $ONEDRIVE_DIR"
echo "Config dir  : $CONFIG_DIR"

# ── Step 1: Remove old/broken onedrive packages ────────────────────────────
echo "[1/7] Cleaning up old onedrive packages (if any)..."
systemctl --user -M "${USERNAME}@" stop onedrive.service 2>/dev/null || true
apt-get remove -y onedrive 2>/dev/null || true
rm -f /etc/apt/sources.list.d/onedrive.list 2>/dev/null || true
add-apt-repository --remove ppa:yann1ck/onedrive 2>/dev/null || true

# ── Step 2: Add OBS repository + install ───────────────────────────────────
echo "[2/7] Adding OpenSuSE Build Service repository..."
apt-get update -qq
apt-get install -y curl gnupg apt-transport-https >/dev/null

. /etc/os-release
OBS_URL="https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_${VERSION_ID}"

wget -qO - "${OBS_URL}/Release.key" \
  | gpg --dearmor \
  | tee /usr/share/keyrings/obs-onedrive.gpg >/dev/null

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] ${OBS_URL}/ ./" \
  | tee /etc/apt/sources.list.d/onedrive.list >/dev/null

apt-get update -qq
apt-get install -y --no-install-recommends --no-install-suggests onedrive

ok "OneDrive client installed: $(onedrive --version 2>&1 | head -n1 || echo 'unknown')"

# ── Step 3: Create configuration ───────────────────────────────────────────
echo "[3/7] Writing OneDrive configuration..."
mkdir -p "$CONFIG_DIR"
chown "$UID_NUM":"$GID_NUM" "$CONFIG_DIR"

cat > "${CONFIG_DIR}/config" <<'CONF'
# OneDrive for Business – DTU Sustain
# Application ID: register in Entra ID with admin consent, or use default
# To use the default abraunegg app, remove/comment the application_id line
# and grant admin consent for d50ca740-c83f-4d1b-b616-12c519384f0c in Entra.
application_id = "d50ca740-c83f-4d1b-b616-12c519384f0c"
sync_dir = "~/OneDrive"
classify_as_big_delete = "50"
monitor_interval = "300"
skip_file = "~*|.~*|*.tmp|*.swp|*.partial|*.crdownload"
skip_dotfiles = "false"
force_http_11 = "true"
ip_protocol_version = "1"
CONF

chown -R "$UID_NUM":"$GID_NUM" "$CONFIG_DIR"
chmod 600 "${CONFIG_DIR}/config"

# ── Step 4: Create OneDrive directory structure ────────────────────────────
echo "[4/6] Creating OneDrive directory structure..."
mkdir -p "${ONEDRIVE_DIR}"
chown -R "$UID_NUM":"$GID_NUM" "${ONEDRIVE_DIR}"

# ── Step 5: Install sleep/resume handler ───────────────────────────────────
echo "[5/6] Installing sleep/resume handler (restart sync on wake)..."
mkdir -p /usr/lib/systemd/system-sleep
cat > /usr/lib/systemd/system-sleep/onedrive-resume.sh <<'SLEEP'
#!/bin/sh
case "$1" in
  post)
    for svc in $(systemctl list-units --type=service --state=running --no-legend \
                   | awk '/onedrive@/{print $1}'); do
      systemctl restart "$svc" 2>/dev/null || true
    done
    for uid_dir in /run/user/*; do
      uid="$(basename "$uid_dir")"
      user="$(id -nu "$uid" 2>/dev/null)" || continue
      XDG_RUNTIME_DIR="$uid_dir" sudo -u "$user" \
        systemctl --user restart onedrive.service 2>/dev/null || true
    done
    ;;
esac
SLEEP
chmod 755 /usr/lib/systemd/system-sleep/onedrive-resume.sh

# ── Step 6: Create first-login auto-launch script ─────────────────────────
echo "[6/7] Installing first-login OneDrive setup..."

# Script that runs inside Konsole on first login
FIRST_RUN_SCRIPT="/usr/local/bin/dtu-onedrive-setup.sh"
cat > "$FIRST_RUN_SCRIPT" <<'FIRSTRUN'
#!/usr/bin/env bash
echo "=========================================================="
echo "  OneDrive for Business — First-Time Setup"
echo "=========================================================="
echo ""
echo "A browser window will open for Microsoft login."
echo "After logging in, copy the redirect URL and paste it here."
echo ""

# Run onedrive initial auth
onedrive --synchronize --single-directory ''
RC=$?

if [ $RC -eq 0 ]; then
  echo ""
  echo "OneDrive authenticated successfully!"
  echo "Enabling automatic sync..."
  systemctl --user enable onedrive
  systemctl --user start onedrive
  echo "OneDrive sync is now running."
else
  echo ""
  echo "OneDrive authentication failed."
  echo "You can retry by running: onedrive"
fi

# Remove the autostart entry so this doesn't run again
rm -f "$HOME/.config/autostart/dtu-onedrive-setup.desktop"

echo ""
echo "Press Enter to close this window..."
read -r
FIRSTRUN
chmod 755 "$FIRST_RUN_SCRIPT"

# Create autostart desktop entry for the user
mkdir -p "${HOME_DIR}/.config/autostart"
chown "$UID_NUM":"$GID_NUM" "${HOME_DIR}/.config"
cat > "${HOME_DIR}/.config/autostart/dtu-onedrive-setup.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=DTU OneDrive Setup
Comment=First-time OneDrive authentication
Exec=konsole --separate -e bash /usr/local/bin/dtu-onedrive-setup.sh
Terminal=false
X-KDE-autostart-phase=2
DESKTOP
chown -R "$UID_NUM":"$GID_NUM" "${HOME_DIR}/.config/autostart"

ok "First-login OneDrive setup installed."
echo "    A Konsole window will open on first login to complete authentication."

# ── Step 7: Enable lingering so OneDrive starts at boot ──────────────────
echo "[7/7] Enabling loginctl linger for $USERNAME..."
loginctl enable-linger "$USERNAME"
ok "Linger enabled — OneDrive will start at boot without GUI login."

ok "OneDrive module complete."
echo "    Sync dir   : $ONEDRIVE_DIR"
echo "    Config     : $CONFIG_DIR/config"
echo "    Updates    : automatic via OBS apt repository"
