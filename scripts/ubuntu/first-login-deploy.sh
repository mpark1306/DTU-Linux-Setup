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

# Systemvidt, ikke /etc/skel.
#
# /etc/skel kopieres ind i en hjemmemappe når kontoen OPRETTES. For en
# domænebruger sker det ved første login, via pam_mkhomedir. Køres dette
# modul bagefter — og det gør det altid, for admin skal jo være logget ind
# for at køre det — er hjemmemappen allerede lavet, og posten kommer aldrig.
# Det er derfor dialogen "aldrig dukker op og ikke findes i Autostart".
#
# /etc/xdg/autostart gælder alle sessioner, også dem der allerede findes.
# Selve scriptet afgør så om den skal køre: kun for domænebrugere, og kun
# indtil den er kørt færdig én gang.
XDG_AUTOSTART="/etc/xdg/autostart"
SKEL_AUTOSTART="/etc/skel/.config/autostart"

echo "[1/4] Installing first-login script to ${INSTALL_PATH}..."
cp "$FIRST_LOGIN_SRC" "$INSTALL_PATH"
chmod 0755 "$INSTALL_PATH"
ok "Script installed."

echo "[2/4] Creating system-wide autostart entry..."
mkdir -p "$XDG_AUTOSTART"
cat > "${XDG_AUTOSTART}/dtu-first-login.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=DTU First-Login Setup
Name[da]=DTU Førstegangsopsætning
Comment=Configure network drives and printers on first login
Comment[da]=Opsætter netværksdrev og printere ved første login
Exec=/usr/local/bin/dtu-first-login.sh
Terminal=false
X-KDE-autostart-phase=2
X-GNOME-Autostart-enabled=true
DESKTOP
chmod 0644 "${XDG_AUTOSTART}/dtu-first-login.desktop"
ok "Autostart entry created in ${XDG_AUTOSTART}."

# Den gamle skel-post fjernes. Lå begge, ville en ny bruger få dialogen to
# gange, og den per-bruger-kopi kan brugeren ikke selv rydde op i.
if [[ -f "${SKEL_AUTOSTART}/dtu-first-login.desktop" ]]; then
    rm -f "${SKEL_AUTOSTART}/dtu-first-login.desktop"
    ok "Removed the old /etc/skel entry (superseded by ${XDG_AUTOSTART})."
fi

# Og de kopier der allerede er landet i eksisterende hjemmemapper.
removed=0
for home in /home/*; do
    entry="${home}/.config/autostart/dtu-first-login.desktop"
    if [[ -f "$entry" ]]; then
        rm -f "$entry"
        removed=$((removed + 1))
    fi
done
[[ "$removed" -gt 0 ]] && ok "Removed ${removed} stale per-user autostart entr(ies)."

echo "[3/4] Configuring default KDE X11 session for new users..."
# GDM reads ~/.dmrc to pick the default session for a user who hasn't logged
# in before. Writing it to /etc/skel ensures every new domain user starts in
# KDE Plasma on X11 rather than Wayland.
if [[ -f /usr/share/xsessions/plasmaX11.desktop ]]; then
    KDE_X11_SESSION="plasmaX11"
else
    KDE_X11_SESSION="plasma"  # Ubuntu 24.04 / Plasma 5 naming
fi
cat > /etc/skel/.dmrc <<DMRC
[Desktop]
Session=${KDE_X11_SESSION}
DMRC
chmod 0644 /etc/skel/.dmrc
ok "Default session set to '${KDE_X11_SESSION}' (X11) for all new users via /etc/skel/.dmrc."

echo "[4/4] Copying scripts to /opt for first-login access..."
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
