#!/usr/bin/env bash
###############################################################################
# DTU – Ubuntu 24.04 – Module: Printers
#
#   Sustain → CUPS FollowMe queues (MFP-PCL + Plot-PS via SMB)
#   AIT     → WebPrint desktop webapp (https://webprint.dtu.dk)
#
# Env: DTU_DEPARTMENT (sustain|ait)
#      DTU_USERNAME, DTU_PASSWORD (only required for Sustain)
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

DEPARTMENT="${DTU_DEPARTMENT:-sustain}"

# ─────────────────────────────────────────────────────────────────────────────
# AIT: install WebPrint as a standalone desktop webapp
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$DEPARTMENT" == "ait" ]]; then
  banner "DTU AIT WebPrint webapp"

  WEBPRINT_URL="https://webprint.dtu.dk"
  ICON_NAME="dtu-webprint"
  ICON_DST="/usr/share/pixmaps/${ICON_NAME}.png"
  WRAPPER="/usr/local/bin/dtu-webprint"
  DESKTOP="/usr/share/applications/${ICON_NAME}.desktop"

  echo "[1/4] Locating dtuprint.png icon..."
  ICON_SRC=""
  for cand in \
      "${SCRIPT_DIR}/../../data/dtuprint.png" \
      "/opt/dtu-sustain-setup/data/dtuprint.png" \
      "/usr/share/dtu-sustain-setup/data/dtuprint.png" \
      "/usr/local/share/dtu-sustain-setup/data/dtuprint.png"; do
    if [[ -f "$cand" ]]; then
      ICON_SRC="$cand"
      break
    fi
  done
  if [[ -z "$ICON_SRC" ]]; then
    warn "dtuprint.png ikke fundet – installerer uden ikon."
  else
    install -D -m 0644 "$ICON_SRC" "$ICON_DST"
    echo "    icon: $ICON_DST"
  fi

  echo "[2/4] Sikrer at en understøttet browser er installeret..."
  if ! command -v chromium-browser >/dev/null 2>&1 \
     && ! command -v chromium >/dev/null 2>&1 \
     && ! command -v google-chrome >/dev/null 2>&1 \
     && ! command -v microsoft-edge >/dev/null 2>&1 \
     && ! command -v brave-browser >/dev/null 2>&1; then
    apt_wait
    apt-get install -y chromium-browser 2>/dev/null \
      || snap install chromium 2>/dev/null \
      || warn "Kunne ikke installere chromium – Firefox bruges som fallback."
  fi

  echo "[3/4] Skriver wrapper-script ${WRAPPER}..."
  cat > "$WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
# DTU WebPrint launcher – opens https://webprint.dtu.dk as a standalone app.
set -e
URL="${WEBPRINT_URL}"

# Prefer Chromium-based browsers (--app gives a true windowed app, no tabs).
for browser in chromium-browser chromium google-chrome microsoft-edge brave-browser; do
  if command -v "\$browser" >/dev/null 2>&1; then
    exec "\$browser" --app="\$URL" --class=DTU-WebPrint --user-data-dir="\$HOME/.config/dtu-webprint"
  fi
done

# Snap chromium
if command -v snap >/dev/null 2>&1 && snap list chromium >/dev/null 2>&1; then
  exec chromium --app="\$URL" --class=DTU-WebPrint --user-data-dir="\$HOME/.config/dtu-webprint"
fi

# Firefox fallback (separate profile so it opens its own window)
if command -v firefox >/dev/null 2>&1; then
  PROFILE="\$HOME/.mozilla/firefox-dtu-webprint"
  mkdir -p "\$PROFILE"
  exec firefox --no-remote --class=DTU-WebPrint --profile "\$PROFILE" --new-window "\$URL"
fi

# Last resort
xdg-open "\$URL"
WRAPEOF
  chmod 0755 "$WRAPPER"

  echo "[4/4] Skriver desktop entry ${DESKTOP}..."
  cat > "$DESKTOP" <<DESKEOF
[Desktop Entry]
Type=Application
Name=DTU WebPrint
GenericName=Print Portal
Comment=Send dokumenter til DTU's webprint-portal
Exec=${WRAPPER}
Icon=${ICON_NAME}
Terminal=false
Categories=Office;Network;Printing;
StartupNotify=true
StartupWMClass=DTU-WebPrint
Keywords=print;webprint;dtu;
DESKEOF
  chmod 0644 "$DESKTOP"

  # Refresh desktop database so the entry shows up immediately
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
  fi

  ok "DTU WebPrint webapp installeret."
  echo "    Start fra menu: 'DTU WebPrint'  eller fra terminal: dtu-webprint"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sustain: classic CUPS FollowMe setup
# ─────────────────────────────────────────────────────────────────────────────
banner "DTU Sustain FollowMe Printers"

# Require credentials via environment (interactive prompts hang in GUI)
if [[ -z "${DTU_USERNAME:-}" || -z "${DTU_PASSWORD:-}" ]]; then
  fail "DTU_USERNAME and DTU_PASSWORD must be set. Run via the GUI or export them."
  exit 1
fi

U="$DTU_USERNAME"
P="$DTU_PASSWORD"

PRINT_SERVER="konfigureret via site.conf"
CREDS_FILE="/etc/cups/print-sustain.creds"

echo "[1/8] Installing packages..."
apt_wait
apt-get update -qq
apt-get install -y cups smbclient openprinting-ppds samba-common-bin

echo "[2/8] Enabling CUPS..."
systemctl enable --now cups

echo "[3/8] Disabling cups-browsed (if present)..."
systemctl disable --now cups-browsed 2>/dev/null || true

echo "[4/8] Writing credentials..."
cat > "${CREDS_FILE}" <<CREDS
username=WIN\\\\${U}
password=${P}
CREDS
chown root:lp "${CREDS_FILE}"
chmod 640 "${CREDS_FILE}"

echo "[5/8] Installing smbspool-auth backend..."
cat > /usr/lib/cups/backend/smbspool-auth <<'BACKEND'
#!/usr/bin/env bash
set -euo pipefail
if [ $# -eq 0 ]; then exit 0; fi
USER_LINE=$(grep -E "^username=" "$CREDS" | head -n1 | cut -d= -f2-)
PASS_LINE=$(grep -E "^password=" "$CREDS" | head -n1 | cut -d= -f2-)
DOMAIN="${USER_LINE%%\\*}"
UNAME="${USER_LINE##*\\}"
URI="${DEVICE_URI#smbspool-auth://}"
export DEVICE_URI="smb://${DOMAIN}/${UNAME}:${PASS_LINE}@${URI}"
exec /usr/bin/smbspool "$@"
BACKEND
sed -i "3i CREDS=\"${CREDS_FILE}\"" /usr/lib/cups/backend/smbspool-auth
chmod 755 /usr/lib/cups/backend/smbspool-auth
rm -f /usr/lib/cups/backend/smb-auth 2>/dev/null || true

echo "[6/8] Removing old queues..."
lpadmin -x FollowMe-MFP-PCL 2>/dev/null || true
lpadmin -x FollowMe-Plot-PS  2>/dev/null || true

echo "[7/8] Adding FollowMe printers..."
lpadmin -p FollowMe-MFP-PCL -E \
  -v "smbspool-auth://${PRINT_SERVER}/FollowMe-MFP-PCL" \
  -m "openprinting-ppds:0/ppd/openprinting/KONICA_MINOLTA/KOC550UX.ppd" \
  -o job-sheets=none,none

lpadmin -p FollowMe-Plot-PS -E \
  -v "smbspool-auth://${PRINT_SERVER}/FollowMe-Plot-PS" \
  -m "openprinting-ppds:0/ppd/openprinting/KONICA_MINOLTA/KOC550UX.ppd" \
  -o job-sheets=none,none

systemctl restart cups

echo "[8/8] Installing print-manager + test page..."
apt-get install -y print-manager 2>/dev/null || true
lp -d FollowMe-MFP-PCL /usr/share/cups/data/testprint >/dev/null || true

ok "FollowMe printers configured."
echo "    Check with: lpstat -W completed | head"
