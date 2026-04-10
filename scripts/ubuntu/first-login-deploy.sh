#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: Deploy First-Login Setup
#
# Installs the first-login welcome dialog mechanism so that when a new
# domain user logs in for the first time, they are prompted for their
# domain credentials and Q-Drive + FollowMe are configured automatically.
#
# What it deploys:
#   /usr/local/bin/dtu-first-login.sh          – the welcome/setup script
#   /etc/skel/.config/autostart/dtu-first-login.desktop – autostart trigger
#
# This module does NOT need domain user credentials — it just prepares
# the system so that each user is prompted on their first login.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Deploy First-Login User Setup"

# ── Locate the first-login script ────────────────────────────
FIRST_LOGIN_SRC="${SCRIPT_DIR}/../dtu-first-login.sh"
if [[ ! -f "$FIRST_LOGIN_SRC" ]]; then
    fail "dtu-first-login.sh not found at: $FIRST_LOGIN_SRC"
    exit 1
fi

INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="${INSTALL_DIR}/dtu-first-login.sh"
SKEL_AUTOSTART="/etc/skel/.config/autostart"

echo "[1/3] Installing first-login script to ${INSTALL_PATH}..."
cp "$FIRST_LOGIN_SRC" "$INSTALL_PATH"
chmod 0755 "$INSTALL_PATH"
ok "Script installed."

echo "[2/3] Creating skel autostart entry..."
mkdir -p "$SKEL_AUTOSTART"
cat > "${SKEL_AUTOSTART}/dtu-first-login.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=DTU Sustain First-Login Setup
Comment=Configure network drives and printers on first login
Exec=/usr/local/bin/dtu-first-login.sh
Terminal=false
X-KDE-autostart-phase=2
X-GNOME-Autostart-enabled=true
DESKTOP
chmod 0644 "${SKEL_AUTOSTART}/dtu-first-login.desktop"
ok "Autostart entry created in /etc/skel."

echo "[3/3] Copying scripts to /opt for first-login access..."
OPT_DIR="/opt/dtu-sustain-setup/scripts/ubuntu"
mkdir -p "$OPT_DIR"

# Copy the user-credential scripts that will be run at first login
for script in qdrive.sh followme.sh; do
    src="${SCRIPT_DIR}/${script}"
    dst="${OPT_DIR}/${script}"
    if [[ -f "$src" ]]; then
        if [[ "$(realpath "$src")" != "$(realpath "$dst" 2>/dev/null)" ]]; then
            cp "$src" "$dst"
            echo "  → Copied ${script}"
        else
            echo "  → ${script} already in place"
        fi
        chmod 0755 "$dst"
    else
        warn "${script} not found — skipping"
    fi
done

# Copy common.sh (needed by the scripts)
COMMON_SRC="${SCRIPT_DIR}/../common.sh"
COMMON_DST="/opt/dtu-sustain-setup/scripts/common.sh"
mkdir -p "/opt/dtu-sustain-setup/scripts"
if [[ -f "$COMMON_SRC" ]]; then
    if [[ "$(realpath "$COMMON_SRC")" != "$(realpath "$COMMON_DST" 2>/dev/null)" ]]; then
        cp "$COMMON_SRC" "$COMMON_DST"
        echo "  → Copied common.sh"
    else
        echo "  → common.sh already in place"
    fi
    chmod 0644 "$COMMON_DST"
fi

ok "First-login setup deployed successfully."
echo ""
echo "    How it works:"
echo "    1. Admin runs all setup modules (no user credentials needed)"
echo "    2. New domain user logs in → home dir created by mkhomedir"
echo "    3. Autostart fires → welcome dialog appears"
echo "    4. User enters their domain credentials"
echo "    5. Q-Drive, P-Drive, and FollowMe printers are configured"
echo "    6. Marker file created — won't run again on next login"
