#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Combined Setup Script for Ubuntu 24.04
#
# Modules:
#   1) Q-Drive (CIFS mount of \\<fileserver>\Qdrev\SUS)
#   2) Brother P950NW label printer
#   3) Microsoft Defender for Endpoint
#   4) PolicyKit / KDE IT-Backdoor (domain admin group)
#   5) FollowMe printers (MFP-PCL + Plot-PS)
#   6) OneDrive for Business (abraunegg client + folder symlinks)
#   7) RDP (xrdp + KDE Plasma remote desktop)
#   A) Run ALL modules
#
###############################################################################
set -euo pipefail

# ─── Colours / helpers ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

banner()  { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"; }
ok()      { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail()    { echo -e "${RED}❌ $1${NC}"; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "This module must be run as root (use sudo)."
    exit 1
  fi
}

# ─── MODULE 1: Q-Drive ──────────────────────────────────────────────────────
module_qdrive() {
  banner "Module 1 – Map \\\\\\\\<fileserver>\\\\Qdrev\\\\SUS → /mnt/Qdrev (CIFS)"

  read -rp "Enter domain username (e.g. mpark): " USERNAME
  read -rsp "Enter password for WIN\\$USERNAME: " PASSWORD; echo

  DOMAIN="WIN"
  SERVER="<fileserver>"
  SHARE_PATH="Qdrev/SUS"
  MOUNTPOINT="/mnt/Qdrev"
  CREDS_FILE="/home/$USERNAME/.smbcred-<fileserver>"
  FSTAB_FILE="/etc/fstab"

  if ! id "$USERNAME" >/dev/null 2>&1; then
    fail "User '$USERNAME' not found on this machine."
    return 1
  fi

  UID_NUM="$(id -u "$USERNAME")"
  GID_NUM="$(id -g "$USERNAME")"

  echo "Using UID=$UID_NUM GID=$GID_NUM"

  echo "[1/6] Installing cifs-utils..."
  apt-get update -qq
  apt-get install -y cifs-utils >/dev/null

  echo "[2/6] Creating mountpoint..."
  mkdir -p "$MOUNTPOINT"
  chown "$UID_NUM":"$GID_NUM" "$MOUNTPOINT"
  chmod 0770 "$MOUNTPOINT"

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
  FSTAB_LINE="//${SERVER}/${SHARE_PATH}  ${MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,serverino,_netdev,x-systemd.automount  0  0"

  if grep -qE "^[[:space:]]*//${SERVER}/${SHARE_PATH}[[:space:]]" "$FSTAB_FILE"; then
    echo "fstab entry already exists — updating..."
    sed -i "\|^[[:space:]]*//${SERVER}/${SHARE_PATH}[[:space:]]|d" "$FSTAB_FILE"
  fi
  echo "$FSTAB_LINE" >> "$FSTAB_FILE"

  if mount | grep -qE "[[:space:]]${MOUNTPOINT}[[:space:]]"; then
    echo "Already mounted — unmounting for clean remount..."
    umount "$MOUNTPOINT" || true
  fi

  echo "[5/6] Reloading systemd + mounting..."
  systemctl daemon-reload

  if ! mount -t cifs "//${SERVER}/${SHARE_PATH}" "$MOUNTPOINT" \
      -o "credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,serverino"; then
    fail "Mount failed. Check credentials or network."
    dmesg | tail -n 20 || true
    return 1
  fi

  echo "[6/6] Verifying..."
  if mount | grep -qE "[[:space:]]${MOUNTPOINT}[[:space:]]"; then
    ok "Mounted: ${MOUNTPOINT}"
    ls -la "$MOUNTPOINT" | head -n 10
  else
    fail "Mount not active."
    dmesg | tail -n 30 || true
    return 1
  fi
}

# ─── MODULE 2: Brother label printer ────────────────────────────────────────
module_brother() {
  banner "Module 2 – Brother P950NW Label Printer"

  PRINTER_NAME="Brother_P950NW"
  PRINTER_IP="10.61.1.9"
  PPD_MODEL="ptouch:0/ppd/ptouch-driver/Brother-PT-P950NW-ptouch-pt.ppd"

  echo "[1/5] Installing packages..."
  apt-get update -qq
  apt-get install -y cups printer-driver-ptouch

  echo "[2/5] Enabling CUPS..."
  systemctl enable --now cups
  systemctl restart cups

  echo "[3/5] Verifying PPD model..."
  if ! lpinfo -m | grep -qF "$PPD_MODEL"; then
    fail "PPD model not found."
    lpinfo -m | grep -i ptouch || true
    return 1
  fi

  echo "[4/5] Adding printer..."
  lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -E \
    -v "socket://$PRINTER_IP:9100" \
    -m "$PPD_MODEL"
  lpadmin -p "$PRINTER_NAME" \
    -o PageSize=12mm \
    -o Resolution=360dpi \
    -o MirrorPrint=Normal \
    -o RequireMatchingLabelSize=noRequireMatchingLabelSize
  cupsenable "$PRINTER_NAME"
  cupsaccept "$PRINTER_NAME"

  echo "[5/5] Final config:"
  lpoptions -p "$PRINTER_NAME" -l | grep -E "PageSize|Resolution|MirrorPrint|RequireMatchingLabelSize"
  lpoptions -p "$PRINTER_NAME"
  ok "Brother P950NW added."
}

# ─── MODULE 3: Microsoft Defender for Endpoint ──────────────────────────────
module_defender() {
  banner "Module 3 – Microsoft Defender for Endpoint"

  export DEBIAN_FRONTEND=noninteractive
  NP_MODE="${NP_MODE:-audit}"

  . /etc/os-release
  echo "[i] Detected: Ubuntu ${VERSION_ID} (${VERSION_CODENAME})"

  # Cleanup old artifacts
  rm -f /etc/apt/sources.list.d/microsoft-prod.list || true
  rm -f /etc/apt/keyrings/microsoft.gpg || true
  rm -f /etc/apt/trusted.gpg.d/microsoft.gpg || true
  rm -f /usr/local/bin/mdatp || true

  echo "[1/6] Installing prerequisites..."
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg apt-transport-https

  echo "[2/6] Installing Microsoft keyring..."
  curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" \
    -o /tmp/packages-microsoft-prod.deb
  dpkg -i /tmp/packages-microsoft-prod.deb
  apt-get update -y

  echo "[3/6] Installing mdatp..."
  apt-get install -y mdatp

  echo "[4/6] Ensuring daemon paths..."
  DAEMON="/opt/microsoft/mdatp/sbin/wdavdaemon"
  CLIENT="/opt/microsoft/mdatp/sbin/wdavdaemonclient"
  [[ -x "$DAEMON" ]] || { fail "Missing daemon: $DAEMON"; return 1; }
  chmod 0755 "$DAEMON" || true
  [[ -x "$CLIENT" ]] && chmod 0755 "$CLIENT" || true
  command -v mdatp >/dev/null || ln -sf "$CLIENT" /usr/bin/mdatp

  if findmnt -T /opt -o OPTIONS -n | grep -qw noexec; then
    mount -o remount,exec /opt || warn "/opt is noexec"
  fi

  echo "[5/6] Enabling service + onboarding..."
  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable --now mdatp

  curl -fsSL -o /tmp/MicrosoftDefenderATPOnboardingLinuxServer.py \
    konfigureret via site.conf/download/MicrosoftDefenderATPOnboardingLinuxServer.py
  python3 /tmp/MicrosoftDefenderATPOnboardingLinuxServer.py || true

  mdatp config passive-mode --value disabled || true
  mdatp config real-time-protection --value enabled || true
  case "$NP_MODE" in
    audit|block) mdatp config network-protection --value "$NP_MODE" || true ;;
  esac

  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG mdatp "$SUDO_USER" || true
  fi

  echo "[6/6] Final checks..."
  mdatp definitions update || true
  sleep 5
  mdatp health || true
  mdatp version || true
  ok "Microsoft Defender installed on Ubuntu ${VERSION_ID}"
}

# ─── MODULE 4: PolicyKit / KDE IT-Backdoor ──────────────────────────────────
module_polkit() {
  banner "Module 4 – PolicyKit / KDE IT Admin Backdoor + Domain User Rights"

  echo "[1/4] Configuring admin identities..."
  tee /etc/polkit-1/localauthority.conf.d/50-localauthority.conf > /dev/null <<'EOF'
[Configuration]
AdminIdentities=unix-user:0;unix-group:sudo;unix-group:wheel;unix-group:SUS-ITAdm-Client-Admins
EOF

  echo "[2/4] Creating PolKit admin rules..."
  mkdir -p /etc/polkit-1/rules.d/

  tee /etc/polkit-1/rules.d/49-domain-admins.rules > /dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("SUS-ITAdm-Client-Admins")) {
        return polkit.Result.YES;
    }
});
EOF

  tee /etc/polkit-1/rules.d/49-allow-username-input.rules > /dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.") === 0 ||
        action.id.indexOf("org.kde.") === 0) {
        return polkit.Result.AUTH_ADMIN_KEEP;
    }
});
EOF

  # ── Step 3: Domain user daily-use rights ──────────────────────────────
  echo "[3/4] Creating domain-user rights (50-domain-users.rules)..."
  tee /etc/polkit-1/rules.d/50-domain-users.rules > /dev/null <<'EOF'
// Domain Users – daily-use rights without admin password prompt.
// IT admins (SUS-ITAdm-Client-Admins) are already handled by
// 49-domain-admins.rules and get YES for everything.
//
// Installed by dtu-setup-ubuntu.sh Module 4.

polkit.addRule(function(action, subject) {

    // Only apply to active, local sessions (not SSH without a seat)
    if (!subject.local || !subject.active)
        return polkit.Result.NOT_HANDLED;

    // Only apply to Domain Users
    if (!subject.isInGroup("Domain Users"))
        return polkit.Result.NOT_HANDLED;

    var dominated = action.id;

    // ── ALLOW without prompt ────────────────────────────────────────

    // PackageKit: refresh repos, install updates, accept EULAs
    if (dominated === "org.freedesktop.packagekit.system-sources-refresh" ||
        dominated === "org.freedesktop.packagekit.system-update"          ||
        dominated === "org.freedesktop.packagekit.trigger-offline-update" ||
        dominated === "org.freedesktop.packagekit.package-eula-accept") {
        return polkit.Result.YES;
    }

    // UDisks2: mount/unmount removable media, power-off drives, eject
    if (dominated.indexOf("org.freedesktop.udisks2.filesystem-mount")  === 0 ||
        dominated.indexOf("org.freedesktop.udisks2.power-off-drive")   === 0 ||
        dominated.indexOf("org.freedesktop.udisks2.eject-media")       === 0) {
        return polkit.Result.YES;
    }

    // NetworkManager: WiFi, VPN, wired – everything
    if (dominated.indexOf("org.freedesktop.NetworkManager.") === 0) {
        return polkit.Result.YES;
    }

    // Login1: power-off, reboot, suspend, hibernate
    if (dominated.indexOf("org.freedesktop.login1.power-off")  === 0 ||
        dominated.indexOf("org.freedesktop.login1.reboot")     === 0 ||
        dominated.indexOf("org.freedesktop.login1.suspend")    === 0 ||
        dominated.indexOf("org.freedesktop.login1.hibernate")  === 0) {
        return polkit.Result.YES;
    }

    // Bluetooth (bluez)
    if (dominated.indexOf("org.bluez.") === 0) {
        return polkit.Result.YES;
    }

    // CUPS: manage own print jobs (cancel, hold, release)
    if (dominated === "org.opensuse.cupspkhelper.mechanism.job-cancel" ||
        dominated === "org.opensuse.cupspkhelper.mechanism.job-edit") {
        return polkit.Result.YES;
    }

    // ── REQUIRE ADMIN AUTH (explicit) ───────────────────────────────

    // PackageKit: install / remove software, configure repos
    if (dominated === "org.freedesktop.packagekit.package-install"          ||
        dominated === "org.freedesktop.packagekit.package-remove"           ||
        dominated === "org.freedesktop.packagekit.system-sources-configure") {
        return polkit.Result.AUTH_ADMIN;
    }

    // CUPS: add/remove printers (admin action)
    if (dominated.indexOf("org.opensuse.cupspkhelper.mechanism.printer-") === 0 ||
        dominated.indexOf("org.opensuse.cupspkhelper.mechanism.server-")  === 0) {
        return polkit.Result.AUTH_ADMIN;
    }

    // Everything else – fall through to default (AUTH_ADMIN)
    return polkit.Result.NOT_HANDLED;
});
EOF

  echo "[4/4] Restarting polkit..."
  systemctl restart polkit
  sleep 1  # wait for polkit to be fully ready

  ok "PolicyKit configured for SUS-ITAdm-Client-Admins + Domain Users."
  echo "    KDE auth dialog will now show a username field."
  echo "    Domain users can update packages, mount USB, manage WiFi, etc."
  echo "    Log out and back in for full effect."
}

# ─── MODULE 5: FollowMe printers ────────────────────────────────────────────
module_followme() {
  banner "Module 5 – DTU Sustain FollowMe Printers"

  read -rp "Username (e.g. mpark): " U
  read -rsp "Password: " P; echo

  echo "[1/8] Installing packages..."
  apt-get update -qq
  apt-get install -y cups smbclient openprinting-ppds samba-common-bin

  echo "[2/8] Enabling CUPS..."
  systemctl enable --now cups

  echo "[3/8] Disabling cups-browsed (if present)..."
  systemctl disable --now cups-browsed 2>/dev/null || true

  echo "[4/8] Writing credentials..."
  cat > /etc/cups/print-sustain.creds <<CREDS
username=WIN\\\\${U}
password=${P}
CREDS
  chown root:lp /etc/cups/print-sustain.creds
  chmod 640 /etc/cups/print-sustain.creds

  echo "[5/8] Installing smbspool-auth backend..."
  cat > /usr/lib/cups/backend/smbspool-auth << "BACKEND"
#!/usr/bin/env bash
set -euo pipefail
CREDS="/etc/cups/print-sustain.creds"
if [ $# -eq 0 ]; then exit 0; fi
USER_LINE=$(grep -E "^username=" "$CREDS" | head -n1 | cut -d= -f2-)
PASS_LINE=$(grep -E "^password=" "$CREDS" | head -n1 | cut -d= -f2-)
DOMAIN="${USER_LINE%%\\\\*}"
UNAME="${USER_LINE##*\\\\}"
URI="${DEVICE_URI#smbspool-auth://}"
export DEVICE_URI="smb://${DOMAIN}/${UNAME}:${PASS_LINE}@${URI}"
exec /usr/bin/smbspool "$@"
BACKEND
  chmod 755 /usr/lib/cups/backend/smbspool-auth
  rm -f /usr/lib/cups/backend/smb-auth 2>/dev/null || true

  echo "[6/8] Removing old queues..."
  lpadmin -x FollowMe-MFP-PCL 2>/dev/null || true
  lpadmin -x FollowMe-Plot-PS  2>/dev/null || true

  echo "[7/8] Adding FollowMe printers..."
  lpadmin -p FollowMe-MFP-PCL -E \
    -v "smbspool-auth://konfigureret via site.conf/FollowMe-MFP-PCL" \
    -m "openprinting-ppds:0/ppd/openprinting/KONICA_MINOLTA/KOC550UX.ppd" \
    -o job-sheets=none,none

  lpadmin -p FollowMe-Plot-PS -E \
    -v "smbspool-auth://konfigureret via site.conf/FollowMe-Plot-PS" \
    -m "openprinting-ppds:0/ppd/openprinting/KONICA_MINOLTA/KOC550UX.ppd" \
    -o job-sheets=none,none

  systemctl restart cups

  echo "[8/8] Installing print-manager + test page..."
  apt-get install -y print-manager 2>/dev/null || true
  lp -d FollowMe-MFP-PCL /usr/share/cups/data/testprint >/dev/null || true

  ok "FollowMe printers configured."
  echo "    Check with: lpstat -W completed | head"
}

# ─── MODULE 6: OneDrive for Business ────────────────────────────────────────
# NOTE: Uses the abraunegg OneDrive Client for Linux, installed from the
#       OpenSuSE Build Service (OBS) repository — the only supported way
#       for Ubuntu. Do NOT use the Ubuntu Universe 'onedrive' package.
#
#       Authentication is interactive (browser-based) and must be completed
#       manually by the target user after this module runs.
#
#       Sync strategy:
#         ~/OneDrive/              ← sync root (two-way sync with M365)
#
#       Updates are handled automatically via the OBS apt repo.
module_onedrive() {
  banner "Module 6 – OneDrive for Business (abraunegg client)"

  read -rp "Enter domain username (e.g. mpark): " USERNAME

  if ! id "$USERNAME" >/dev/null 2>&1; then
    fail "User '$USERNAME' not found on this machine."
    return 1
  fi

  HOME_DIR="$(eval echo "~$USERNAME")"
  ONEDRIVE_DIR="${HOME_DIR}/OneDrive"
  CONFIG_DIR="${HOME_DIR}/.config/onedrive"
  UID_NUM="$(id -u "$USERNAME")"
  GID_NUM="$(id -g "$USERNAME")"

  echo "Target user : $USERNAME (UID=$UID_NUM GID=$GID_NUM)"
  echo "Sync dir    : $ONEDRIVE_DIR"
  echo "Config dir  : $CONFIG_DIR"

  # ── Step 1: Remove old/broken onedrive packages ──────────────────────────
  echo "[1/7] Cleaning up old onedrive packages (if any)..."
  systemctl --user -M "${USERNAME}@" stop onedrive.service 2>/dev/null || true
  apt-get remove -y onedrive 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/onedrive.list 2>/dev/null || true
  add-apt-repository --remove ppa:yann1ck/onedrive 2>/dev/null || true

  # ── Step 2: Add OBS repository + install ─────────────────────────────────
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

  # ── Step 3: Create configuration ─────────────────────────────────────────
  echo "[3/7] Writing OneDrive configuration..."
  sudo -u "$USERNAME" mkdir -p "$CONFIG_DIR"

  cat > "${CONFIG_DIR}/config" <<'CONF'
# OneDrive for Business – DTU Sustain
# Generated by dtu-setup-ubuntu.sh

sync_dir = "~/OneDrive"

# Safety: refuse to sync if more than 50 items would be deleted at once.
# Protects against accidental mass-deletion (e.g. mount disappearing).
classify_as_big_delete = "50"

# Monitor interval in seconds (5 minutes)
monitor_interval = "300"

# Skip common temporary / junk files
skip_file = "~*|.~*|*.tmp|*.swp|*.partial|*.crdownload"

# Skip dot-files (hidden files) — set to true if you don't want them synced
skip_dotfiles = "false"

# Work around known curl/libcurl HTTP/2 bugs on Ubuntu 24.04
force_http_11 = "true"
ip_protocol_version = "1"
CONF

  chown -R "$UID_NUM":"$GID_NUM" "$CONFIG_DIR"
  chmod 600 "${CONFIG_DIR}/config"

  # ── Step 4: Create OneDrive directory structure ──────────────────────────
echo "[4/6] Creating OneDrive directory structure..."
  sudo -u "$USERNAME" mkdir -p "${ONEDRIVE_DIR}"

  # ── Step 5: Install sleep/resume handler ─────────────────────────────────
  echo "[5/6] Installing sleep/resume handler (restart sync on wake)..."
  mkdir -p /usr/lib/systemd/system-sleep
  cat > /usr/lib/systemd/system-sleep/onedrive-resume.sh <<'SLEEP'
#!/bin/sh
# Restart OneDrive user services on resume to clear stale curl connections.
# Installed by dtu-setup-ubuntu.sh Module 6.
case "$1" in
  post)
    # Restart all active onedrive@ system services
    for svc in $(systemctl list-units --type=service --state=running --no-legend \
                   | awk '/onedrive@/{print $1}'); do
      systemctl restart "$svc" 2>/dev/null || true
    done
    # Also poke user-level services via loginctl
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

  # ── Step 6: Print manual auth instructions ─────────────────────────────
  echo "[6/6] Installation complete."
  echo
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║              MANUAL STEP REQUIRED — READ THIS               ║${NC}"
  echo -e "${CYAN}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║                                                              ║${NC}"
  echo -e "${CYAN}║  Log in as ${BOLD}${USERNAME}${NC}${CYAN} (GUI session or SSH) and run:            ║${NC}"
  echo -e "${CYAN}║                                                              ║${NC}"
  echo -e "${CYAN}║    ${BOLD}onedrive${NC}${CYAN}                                                  ║${NC}"
  echo -e "${CYAN}║                                                              ║${NC}"
  echo -e "${CYAN}║  1. The client will print a Microsoft login URL              ║${NC}"
  echo -e "${CYAN}║  2. Open the URL in a browser → log in with DTU account      ║${NC}"
  echo -e "${CYAN}║  3. You'll be redirected to a blank page                     ║${NC}"
  echo -e "${CYAN}║  4. Copy the full URL from the browser address bar           ║${NC}"
  echo -e "${CYAN}║  5. Paste it back into the terminal                          ║${NC}"
  echo -e "${CYAN}║                                                              ║${NC}"
  echo -e "${CYAN}║  After authentication, enable automatic sync:                ║${NC}"
  echo -e "${CYAN}║                                                              ║${NC}"
  echo -e "${CYAN}║    ${BOLD}systemctl --user enable onedrive${NC}${CYAN}                          ║${NC}"
  echo -e "${CYAN}║    ${BOLD}systemctl --user start  onedrive${NC}${CYAN}                          ║${NC}"
  echo -e "${CYAN}║                                                              ║${NC}"
  echo -e "${CYAN}║  Optional – start sync at boot even before login:            ║${NC}"
  echo -e "${CYAN}║    ${BOLD}loginctl enable-linger ${USERNAME}${NC}${CYAN}                              ║${NC}"
  echo -e "${CYAN}║                                                              ║${NC}"
  echo -e "${CYAN}║  Verify status:                                              ║${NC}"
  echo -e "${CYAN}║    ${BOLD}systemctl --user status onedrive${NC}${CYAN}                          ║${NC}"
  echo -e "${CYAN}║    ${BOLD}onedrive --display-config${NC}${CYAN}                                 ║${NC}"
  echo -e "${CYAN}║                                                              ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  # ── Enable lingering so OneDrive starts at boot ──────────────
  echo "Enabling loginctl linger for $USERNAME..."
  loginctl enable-linger "$USERNAME"
  ok "Linger enabled — OneDrive will start at boot without GUI login."

  ok "OneDrive module complete. Awaiting manual authentication by ${USERNAME}."
  echo "    Sync dir   : $ONEDRIVE_DIR"
  echo "    Config     : $CONFIG_DIR/config"
  echo "    Updates    : automatic via OBS apt repository"
}

# ─── MODULE 7: RDP (xrdp + KDE Plasma) ──────────────────────────────────────
module_rdp() {
  banner "Module 7 – RDP (xrdp + KDE Plasma Remote Desktop)"

  echo "[1/5] Installing xrdp..."
  apt-get update -qq
  apt-get install -y xrdp xorgxrdp >/dev/null
  usermod -aG ssl-cert xrdp

  echo "[2/5] Configuring KDE Plasma session..."
  cat > /etc/xrdp/startwm.sh <<'STARTWM'
#!/bin/sh
if [ -r /etc/profile ]; then . /etc/profile; fi
if [ -r "$HOME/.profile" ]; then . "$HOME/.profile"; fi
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
if command -v startplasma-x11 >/dev/null 2>&1; then
    exec startplasma-x11
elif command -v startplasma-wayland >/dev/null 2>&1; then
    exec startplasma-wayland
else
    exec xterm
fi
STARTWM
  chmod 755 /etc/xrdp/startwm.sh

  echo "[3/5] Tuning xrdp.ini..."
  XRDP_INI="/etc/xrdp/xrdp.ini"
  cp -n "$XRDP_INI" "${XRDP_INI}.orig" 2>/dev/null || true
  sed -i 's/^max_bpp=.*/max_bpp=24/' "$XRDP_INI"
  sed -i 's/^#\?xserverbpp=.*/xserverbpp=24/' "$XRDP_INI"
  sed -i 's/^security_layer=.*/security_layer=tls/' "$XRDP_INI"
  sed -i 's/^crypt_level=.*/crypt_level=high/' "$XRDP_INI"

  echo "[4/5] Configuring polkit for RDP sessions..."
  tee /etc/polkit-1/rules.d/45-xrdp.rules > /dev/null <<'POLKIT'
polkit.addRule(function(action, subject) {
    if ((action.id === "org.freedesktop.color-manager.create-device" ||
         action.id === "org.freedesktop.color-manager.create-profile" ||
         action.id === "org.freedesktop.color-manager.modify-device"  ||
         action.id === "org.freedesktop.color-manager.modify-profile") &&
        subject.isInGroup("Domain Users")) {
        return polkit.Result.YES;
    }
});
POLKIT

  echo "[5/5] Enabling xrdp..."
  systemctl enable xrdp
  systemctl restart xrdp

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 3389/tcp comment "xrdp (RDP)" >/dev/null
  fi

  if systemctl is-active --quiet xrdp; then
    ok "xrdp running on port 3389."
    echo "    Connect: $(hostname -I | awk '{print $1}'):3389"
    echo "    Login: WIN\\username"
  else
    fail "xrdp failed to start."
    journalctl -u xrdp --no-pager -n 20
    return 1
  fi
}

# ─── MAIN MENU ──────────────────────────────────────────────────────────────
show_menu() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║       DTU Sustain – Ubuntu 24.04 Setup (Combined)       ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║  1) Q-Drive CIFS mount (\\\\<fileserver>\\Qdrev\\SUS)          ║"
  echo "║  2) Brother P950NW label printer                        ║"
  echo "║  3) Microsoft Defender for Endpoint                     ║"
  echo "║  4) PolicyKit / KDE IT-Backdoor                         ║"
  echo "║  5) FollowMe printers (MFP-PCL + Plot-PS)              ║"
  echo "║  6) OneDrive for Business (sync + folder symlinks)      ║"
  echo "║  7) RDP (xrdp + KDE Plasma remote desktop)              ║"
  echo "║                                                          ║"
  echo "║  A) Run ALL modules                                      ║"
  echo "║  Q) Quit                                                 ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

run_module() {
  case "$1" in
    1) need_root; module_qdrive   ;;
    2) need_root; module_brother  ;;
    3) need_root; module_defender ;;
    4) need_root; module_polkit   ;;
    5) need_root; module_followme ;;  
    6) need_root; module_onedrive ;;
    7) need_root; module_rdp     ;;
    *)
      fail "Unknown module: $1"
      return 1
      ;;
  esac
}

main() {
  # Allow non-interactive: ./script.sh 1 3 5
  if [[ $# -gt 0 ]]; then
    for mod in "$@"; do
      if [[ "${mod,,}" == "a" || "${mod,,}" == "all" ]]; then
        for i in 1 2 3 4 5 6 7; do run_module "$i"; done
        exit 0
      fi
      run_module "$mod"
    done
    exit 0
  fi

  # Interactive menu
  while true; do
    show_menu
    read -rp "Choose module(s) [1-7, A, Q]: " CHOICE
    case "${CHOICE,,}" in
      1|2|3|4|5|6|7) run_module "$CHOICE" ;;
      a|all)
        for i in 1 2 3 4 5 6 7; do run_module "$i"; done
        ;;
      q|quit|exit) echo "Bye."; exit 0 ;;
      *) warn "Invalid choice: $CHOICE" ;;
    esac
  done
}

main "$@"
