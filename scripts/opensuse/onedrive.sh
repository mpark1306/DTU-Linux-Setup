#!/usr/bin/env bash
###############################################################################
# DTU Sustain – openSUSE Tumbleweed – Module: OneDrive for Business
# Env: DTU_USERNAME (optional – falls back to interactive)
#
# Tries zypper package first, then builds from source (ldc D-compiler).
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

# ── Step 1: Install OneDrive client ────────────────────────────────────────
echo "[1/7] Installing OneDrive client..."

INSTALLED_FROM="unknown"

if zypper --non-interactive install onedrive 2>/dev/null; then
  INSTALLED_FROM="zypper"
  ok "Installed from zypper repository."
else
  echo "    Package not in zypper repos — building from source..."

  echo "    Installing build dependencies..."
  zypper --non-interactive install \
    git-core gcc ldc libcurl-devel sqlite3-devel systemd-devel \
    pkg-config autoconf automake

  BUILD_DIR="/tmp/onedrive-build"
  rm -rf "$BUILD_DIR"
  git clone https://github.com/abraunegg/onedrive.git "$BUILD_DIR"
  cd "$BUILD_DIR"

  ./configure DC=/usr/bin/ldmd2
  make clean
  make
  make install

  INSTALLED_FROM="source"
  cd /
  rm -rf "$BUILD_DIR"
  ok "Built and installed from source."
fi

echo "    Version: $(onedrive --version 2>&1 | head -n1 || echo 'unknown')"

# ── Step 2: Create configuration ───────────────────────────────────────────
echo "[2/7] Writing OneDrive configuration..."
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
CONF

chown -R "$UID_NUM":"$GID_NUM" "$CONFIG_DIR"
chmod 600 "${CONFIG_DIR}/config"

# ── Step 3: Create OneDrive directory structure ────────────────────────────
echo "[3/7] Creating OneDrive directory structure..."
mkdir -p "${ONEDRIVE_DIR}"
chown -R "$UID_NUM":"$GID_NUM" "${ONEDRIVE_DIR}"

# ── Step 4: Install sleep/resume handler ───────────────────────────────────
echo "[4/7] Installing sleep/resume handler (restart sync on wake)..."
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

# ── Step 5: Source-build update helper (if built from source) ──────────────
if [ "$INSTALLED_FROM" = "source" ]; then
  echo "[6/7] Installing update helper script..."
  cat > /usr/local/sbin/onedrive-update.sh <<'UPDATER'
#!/usr/bin/env bash
set -euo pipefail
BUILD_DIR="/tmp/onedrive-update-$$"
echo "[onedrive-update] Pulling latest source..."
git clone --depth 1 https://github.com/abraunegg/onedrive.git "$BUILD_DIR"
cd "$BUILD_DIR"
./configure DC=/usr/bin/ldmd2
make clean; make
echo "[onedrive-update] Installing..."
make install
rm -rf "$BUILD_DIR"
echo "[onedrive-update] Done. Restart user services to pick up new binary."
echo "[onedrive-update] Version: $(onedrive --version 2>&1 | head -n1)"
UPDATER
  chmod 755 /usr/local/sbin/onedrive-update.sh

  cat > /etc/cron.monthly/onedrive-update <<'CRON'
#!/bin/sh
/usr/local/sbin/onedrive-update.sh >> /var/log/onedrive-update.log 2>&1
CRON
  chmod 755 /etc/cron.monthly/onedrive-update

  ok "Update helper installed at /usr/local/sbin/onedrive-update.sh"
  echo "    Monthly auto-update via /etc/cron.monthly/onedrive-update"
else
  echo "[5/7] Updates handled by zypper — no extra setup needed."
fi

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
if [ "$INSTALLED_FROM" = "source" ]; then
  echo "    Updates    : monthly via /etc/cron.monthly/onedrive-update"
else
  echo "    Updates    : automatic via zypper dup"
fi
