#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Combined Setup Script for openSUSE Tumbleweed
#
# Modules:
#   1) Q-Drive (direct CIFS mount to real DFS target, bypassing DFS bug)
#   2) Brother P950NW label printer (built from source)
#   3) Microsoft Defender for Endpoint
#   4) PolicyKit / KDE IT-Backdoor (domain admin group)
#   5) FollowMe printers (MFP-PCL + Plot-PS)
#   6) Auto-mount (Qdrev/Pdrev) + Desktop Polkit rules
#   A) Run ALL modules
#
# Differences vs Ubuntu version:
#   - zypper instead of apt
#   - Package names adapted to openSUSE repos
#   - Q-Drive: direct mount to DFS target (kernel 6.19+ DFS bug workaround)
#   - Brother: built from source (no printer-driver-ptouch package)
#   - CUPS backend path: /usr/lib/cups (Tumbleweed x86_64)
#   - Defender repo: zypper + rpm key, SLES 15 packages
#   - PolicyKit admin identities via JS rules (no pkla)
#   - FollowMe: generic PostScript PPD (KOC550UX not in TW repos)
#   - samba-client instead of smbclient
#   - plasma6-print-manager instead of print-manager
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

# Detect CUPS paths
CUPS_FILTER_DIR="/usr/lib/cups/filter"
CUPS_BACKEND_DIR="/usr/lib/cups/backend"

# ─── MODULE 1: Q-Drive ──────────────────────────────────────────────────────
# NOTE: Tumbleweed kernel 6.19+ cannot follow DFS reparse points in the CIFS
#       module (EINTR). GVFS and KIO also fail intermittently.
#       The share \\<fileserver>\Qdrev\SUS is a DFS junction pointing to:
#         \\<qumulo-server>\sus-q$
#       Mounting the real target directly with nodfs bypasses the bug entirely.
module_qdrive() {
  banner "Module 1 – Map Q-Drive SUS → /mnt/Qdrev (direct CIFS)"

  read -rp "Enter domain username (e.g. mpark): " USERNAME
  read -rsp "Enter password for WIN\\$USERNAME: " PASSWORD; echo

  DOMAIN="WIN"
  # Real DFS target (\\<fileserver>\Qdrev\SUS → \\<qumulo-server>\sus-q$)
  SERVER="<qumulo-server>"
  SHARE="sus-q\$"
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
  zypper --non-interactive install cifs-utils

  echo "[2/6] Creating mountpoint..."
  # Clean up old symlinks/mounts from previous attempts
  umount "$MOUNTPOINT" 2>/dev/null || true
  rm -f "$MOUNTPOINT" 2>/dev/null || true
  mkdir -p "$MOUNTPOINT"
  chown "$UID_NUM":"$GID_NUM" "$MOUNTPOINT"
  chmod 0770 "$MOUNTPOINT"
  # Clean up old autostart files from GVFS attempts
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
  # Remove any old Qdrev fstab entries (both old DFS path and new direct path)
  sed -i "/<fileserver>.*[Qq]drev/d" "$FSTAB_FILE" 2>/dev/null || true
  sed -i "/ait-pqumulo.*sus-q/d" "$FSTAB_FILE" 2>/dev/null || true

  FSTAB_LINE="//${SERVER}/${SHARE}  ${MOUNTPOINT}  cifs  credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,vers=3.0,sec=ntlmssp,nosharesock,nodfs,_netdev,x-systemd.automount  0  0"
  echo "$FSTAB_LINE" >> "$FSTAB_FILE"

  echo "[5/6] Reloading systemd + mounting..."
  systemctl daemon-reload

  if ! mount -t cifs "//${SERVER}/${SHARE}" "$MOUNTPOINT" \
      -o "credentials=${CREDS_FILE},iocharset=utf8,uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,vers=3.0,sec=ntlmssp,nosharesock,nodfs"; then
    fail "Mount failed. Check credentials or network."
    dmesg | tail -n 20 || true
    return 1
  fi

  echo "[6/6] Verifying..."
  if mount | grep -qE "[[:space:]]${MOUNTPOINT}[[:space:]]"; then
    ok "Mounted: ${MOUNTPOINT}"
    echo "    Real target: //${SERVER}/${SHARE}"
    echo "    (DFS junction from \\\\<fileserver>\\Qdrev\\SUS)"
    ls "$MOUNTPOINT" | head -n 10
  else
    fail "Mount not active."
    dmesg | tail -n 30 || true
    return 1
  fi
}

# ─── MODULE 2: Brother label printer ────────────────────────────────────────
# NOTE: No printer-driver-ptouch package exists on Tumbleweed.
#       We build the rastertoptch filter from source and install a hand-
#       crafted PPD derived from the foomatic XML definitions.
module_brother() {
  banner "Module 2 – Brother P950NW Label Printer (from source)"

  PRINTER_NAME="Brother_P950NW"
  PRINTER_IP="10.61.1.9"
  PPD_NAME="Brother-PT-P950NW-ptouch-pt.ppd"
  PPD_DIR="/usr/share/cups/model/ptouch"
  BUILD_DIR="/tmp/printer-driver-ptouch"

  echo "[1/7] Installing build dependencies + CUPS..."
  zypper --non-interactive install cups gcc cups-devel autoconf automake libtool git-core

  echo "[2/7] Enabling CUPS..."
  systemctl enable --now cups
  systemctl restart cups

  echo "[3/7] Cloning ptouch-driver source..."
  rm -rf "$BUILD_DIR"
  git clone https://github.com/philpem/printer-driver-ptouch.git "$BUILD_DIR"

  echo "[4/7] Building rastertoptch filter..."
  cd "$BUILD_DIR"
  autoreconf -fi
  ./configure
  # Build may fail on ptexplain (missing libpng define) — that's OK,
  # rastertoptch is the important filter and compiles first.
  make 2>/dev/null || true

  if [[ ! -f "$BUILD_DIR/rastertoptch" ]]; then
    fail "rastertoptch filter did not compile."
    return 1
  fi

  echo "[5/7] Installing filter..."
  cp "$BUILD_DIR/rastertoptch" "${CUPS_FILTER_DIR}/"
  chmod 755 "${CUPS_FILTER_DIR}/rastertoptch"

  echo "[6/7] Installing PPD..."
  mkdir -p "$PPD_DIR"
  cat > "${PPD_DIR}/${PPD_NAME}" <<'PPD'
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion: "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*PCFileName: "BrPTP950.ppd"
*Manufacturer: "Brother"
*Product: "(PT-P950NW)"
*ModelName: "Brother PT-P950NW"
*ShortNickName: "Brother PT-P950NW ptouch-pt"
*NickName: "Brother PT-P950NW ptouch-pt"
*PSVersion: "(3010.000) 0"
*LanguageLevel: "3"
*ColorDevice: False
*DefaultColorSpace: Gray
*FileSystem: False
*Throughput: "1"
*LandscapeOrientation: Plus90
*TTRasterizer: Type42
*cupsFilter: "application/vnd.cups-raster 100 rastertoptch"
*cupsModelNumber: 0
*OpenUI *PageSize/Tape Width: PickOne
*OrderDependency: 10 AnySetup *PageSize
*DefaultPageSize: tz-12
*PageSize tz-4/3.5mm:          "<</PageSize[10 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-6/6mm:            "<</PageSize[17 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-9/9mm:            "<</PageSize[26 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-12/12mm:          "<</PageSize[34 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-18/18mm:          "<</PageSize[51 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-24/24mm:          "<</PageSize[68 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-36/36mm:          "<</PageSize[102 283]/ImagingBBox null>>setpagedevice"
*PageSize hs-6/HS 5.8mm:       "<</PageSize[16 283]/ImagingBBox null>>setpagedevice"
*PageSize hs-9/HS 8.8mm:       "<</PageSize[25 283]/ImagingBBox null>>setpagedevice"
*PageSize hs-12/HS 11.7mm:     "<</PageSize[33 283]/ImagingBBox null>>setpagedevice"
*PageSize hs-18/HS 17.7mm:     "<</PageSize[50 283]/ImagingBBox null>>setpagedevice"
*PageSize hs-24/HS 23.6mm:     "<</PageSize[67 283]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageSize
*OpenUI *PageRegion/Tape Width: PickOne
*OrderDependency: 10 AnySetup *PageRegion
*DefaultPageRegion: tz-12
*PageRegion tz-4/3.5mm:        "<</PageSize[10 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-6/6mm:          "<</PageSize[17 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-9/9mm:          "<</PageSize[26 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-12/12mm:        "<</PageSize[34 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-18/18mm:        "<</PageSize[51 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-24/24mm:        "<</PageSize[68 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-36/36mm:        "<</PageSize[102 283]/ImagingBBox null>>setpagedevice"
*PageRegion hs-6/HS 5.8mm:     "<</PageSize[16 283]/ImagingBBox null>>setpagedevice"
*PageRegion hs-9/HS 8.8mm:     "<</PageSize[25 283]/ImagingBBox null>>setpagedevice"
*PageRegion hs-12/HS 11.7mm:   "<</PageSize[33 283]/ImagingBBox null>>setpagedevice"
*PageRegion hs-18/HS 17.7mm:   "<</PageSize[50 283]/ImagingBBox null>>setpagedevice"
*PageRegion hs-24/HS 23.6mm:   "<</PageSize[67 283]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageRegion
*DefaultImageableArea: tz-12
*ImageableArea tz-4/3.5mm:      "0 0 10 283"
*ImageableArea tz-6/6mm:        "0 0 17 283"
*ImageableArea tz-9/9mm:        "0 0 26 283"
*ImageableArea tz-12/12mm:      "0 0 34 283"
*ImageableArea tz-18/18mm:      "0 0 51 283"
*ImageableArea tz-24/24mm:      "0 0 68 283"
*ImageableArea tz-36/36mm:      "0 0 102 283"
*ImageableArea hs-6/HS 5.8mm:   "0 0 16 283"
*ImageableArea hs-9/HS 8.8mm:   "0 0 25 283"
*ImageableArea hs-12/HS 11.7mm: "0 0 33 283"
*ImageableArea hs-18/HS 17.7mm: "0 0 50 283"
*ImageableArea hs-24/HS 23.6mm: "0 0 67 283"
*DefaultPaperDimension: tz-12
*PaperDimension tz-4/3.5mm:      "10 283"
*PaperDimension tz-6/6mm:        "17 283"
*PaperDimension tz-9/9mm:        "26 283"
*PaperDimension tz-12/12mm:      "34 283"
*PaperDimension tz-18/18mm:      "51 283"
*PaperDimension tz-24/24mm:      "68 283"
*PaperDimension tz-36/36mm:      "102 283"
*PaperDimension hs-6/HS 5.8mm:   "16 283"
*PaperDimension hs-9/HS 8.8mm:   "25 283"
*PaperDimension hs-12/HS 11.7mm: "33 283"
*PaperDimension hs-18/HS 17.7mm: "50 283"
*PaperDimension hs-24/HS 23.6mm: "67 283"
*OpenUI *Resolution/Resolution: PickOne
*OrderDependency: 20 AnySetup *Resolution
*DefaultResolution: 360dpi
*Resolution 360x180dpi/360x180 DPI: "<</HWResolution[360 180]>>setpagedevice"
*Resolution 360dpi/360 DPI:          "<</HWResolution[360 360]>>setpagedevice"
*Resolution 360x720dpi/360x720 DPI:  "<</HWResolution[360 720]>>setpagedevice"
*CloseUI: *Resolution
*OpenUI *MirrorPrint/Mirror Print: PickOne
*OrderDependency: 30 AnySetup *MirrorPrint
*DefaultMirrorPrint: Normal
*MirrorPrint Normal/Normal: ""
*MirrorPrint Mirror/Mirror: ""
*CloseUI: *MirrorPrint
*OpenUI *HalfCut/Half Cut: PickOne
*OrderDependency: 30 AnySetup *HalfCut
*DefaultHalfCut: True
*HalfCut True/Yes: ""
*HalfCut False/No: ""
*CloseUI: *HalfCut
*OpenUI *CutLabel/Cut Label: PickOne
*OrderDependency: 30 AnySetup *CutLabel
*DefaultCutLabel: True
*CutLabel True/Yes: ""
*CutLabel False/No: ""
*CloseUI: *CutLabel
*DefaultFont: Courier
*Font Courier: Standard "(002.004S)" Standard ROM
*Font Courier-Bold: Standard "(002.004S)" Standard ROM
*Font Helvetica: Standard "(001.006S)" Standard ROM
*Font Helvetica-Bold: Standard "(001.007S)" Standard ROM
*Font Times-Roman: Standard "(001.007S)" Standard ROM
*Font Symbol: Special "(001.007S)" Special ROM
PPD

  systemctl restart cups

  echo "[7/7] Adding printer..."
  lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -E \
    -v "socket://$PRINTER_IP:9100" \
    -P "${PPD_DIR}/${PPD_NAME}"
  lpadmin -p "$PRINTER_NAME" \
    -o PageSize=tz-12 \
    -o Resolution=360dpi \
    -o MirrorPrint=Normal
  cupsenable "$PRINTER_NAME"
  cupsaccept "$PRINTER_NAME"

  ok "Brother P950NW added (filter built from source)."
  lpstat -p "$PRINTER_NAME"
}

# ─── MODULE 3: Microsoft Defender for Endpoint ──────────────────────────────
module_defender() {
  banner "Module 3 – Microsoft Defender for Endpoint"

  NP_MODE="${NP_MODE:-audit}"

  . /etc/os-release
  echo "[i] Detected: $NAME $VERSION_ID ($PRETTY_NAME)"

  rm -f /etc/zypp/repos.d/microsoft-prod.repo 2>/dev/null || true
  rm -f /usr/local/bin/mdatp 2>/dev/null || true

  echo "[1/6] Installing prerequisites..."
  zypper --non-interactive install curl ca-certificates gpg2

  echo "[2/6] Adding Microsoft package repository..."
  rpm --import https://packages.microsoft.com/keys/microsoft.asc
  zypper --non-interactive addrepo --refresh --check \
    "https://packages.microsoft.com/yumrepos/microsoft-sles15-prod" \
    microsoft-prod 2>/dev/null || true
  zypper --non-interactive --gpg-auto-import-keys refresh microsoft-prod || true

  echo "[3/6] Installing mdatp..."
  zypper --non-interactive install mdatp

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

  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG mdatp "$SUDO_USER" || true
  fi

  echo "[6/6] Final checks..."
  mdatp definitions update || true
  sleep 5
  mdatp health || true
  mdatp version || true
  ok "Microsoft Defender installed on $PRETTY_NAME"
  warn "Note: Tumbleweed is not officially supported by Microsoft."
  warn "Using SLES 15 packages. Monitor for compatibility issues."
}

# ─── MODULE 4: PolicyKit / KDE IT-Backdoor ──────────────────────────────────
module_polkit() {
  banner "Module 4 – PolicyKit / KDE IT Admin Backdoor"

  echo "[1/2] Creating PolKit rules..."
  mkdir -p /etc/polkit-1/rules.d/

  tee /etc/polkit-1/rules.d/49-domain-admins.rules > /dev/null <<'EOF'
// Grant full admin access to SUS-ITAdm-Client-Admins
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("SUS-ITAdm-Client-Admins")) {
        return polkit.Result.YES;
    }
});
EOF

  tee /etc/polkit-1/rules.d/40-admin-identities.rules > /dev/null <<'EOF'
// Define who counts as an administrator
polkit.addAdminRule(function(action, subject) {
    return [
        "unix-user:0",
        "unix-group:wheel",
        "unix-group:sudo",
        "unix-group:SUS-ITAdm-Client-Admins"
    ];
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

  echo "[2/2] Restarting polkit (background, 2s delay)..."
  nohup bash -c 'sleep 2 && systemctl restart polkit' > /tmp/polkit-restart.log 2>&1 &

  ok "PolicyKit configured for SUS-ITAdm-Client-Admins."
  echo "    KDE auth dialog will now show a username field."
  echo "    Admin identities set via 40-admin-identities.rules."
  echo "    Log out and back in for full effect."
}

# ─── MODULE 5: FollowMe printers ────────────────────────────────────────────
# NOTE: KOC550UX PPD is not available on Tumbleweed.
#       FollowMe queues go through DTU's print server which handles rendering,
#       so a generic PostScript PPD works correctly.
module_followme() {
  banner "Module 5 – DTU Sustain FollowMe Printers"

  read -rp "Username (e.g. mpark): " U
  read -rsp "Password: " P; echo

  echo "[1/8] Installing packages..."
  zypper --non-interactive install cups samba-client
  zypper --non-interactive install OpenPrintingPPDs-postscript 2>/dev/null \
    || zypper --non-interactive install OpenPrintingPPDs 2>/dev/null \
    || warn "Could not install OpenPrintingPPDs — using generic PostScript PPD."

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
  SMBSPOOL_BIN="/usr/bin/smbspool"
  [[ -x "${CUPS_BACKEND_DIR}/smb" ]] && SMBSPOOL_BIN="${CUPS_BACKEND_DIR}/smb"
  [[ -x "/usr/bin/smbspool" ]] && SMBSPOOL_BIN="/usr/bin/smbspool"

  cat > "${CUPS_BACKEND_DIR}/smbspool-auth" <<BACKEND
#!/usr/bin/env bash
set -euo pipefail
CREDS="/etc/cups/print-sustain.creds"
if [ \$# -eq 0 ]; then exit 0; fi
USER_LINE=\$(grep -E "^username=" "\$CREDS" | head -n1 | cut -d= -f2-)
PASS_LINE=\$(grep -E "^password=" "\$CREDS" | head -n1 | cut -d= -f2-)
DOMAIN="\${USER_LINE%%\\\\\\\\*}"
UNAME="\${USER_LINE##*\\\\\\\\}"
URI="\${DEVICE_URI#smbspool-auth://}"
export DEVICE_URI="smb://\${DOMAIN}/\${UNAME}:\${PASS_LINE}@\${URI}"
exec ${SMBSPOOL_BIN} "\$@"
BACKEND
  chmod 755 "${CUPS_BACKEND_DIR}/smbspool-auth"
  rm -f "${CUPS_BACKEND_DIR}/smb-auth" 2>/dev/null || true

  echo "[6/8] Removing old queues..."
  lpadmin -x FollowMe-MFP-PCL 2>/dev/null || true
  lpadmin -x FollowMe-Plot-PS  2>/dev/null || true

  PPD_MODEL="drv:///sample.drv/generic.ppd"

  echo "[7/8] Adding FollowMe printers..."
  lpadmin -p FollowMe-MFP-PCL -E \
    -v "smbspool-auth://konfigureret via site.conf/FollowMe-MFP-PCL" \
    -m "$PPD_MODEL" \
    -o job-sheets=none,none

  lpadmin -p FollowMe-Plot-PS -E \
    -v "smbspool-auth://konfigureret via site.conf/FollowMe-Plot-PS" \
    -m "$PPD_MODEL" \
    -o job-sheets=none,none

  systemctl restart cups

  echo "[8/8] Verifying..."
  lpstat -p FollowMe-MFP-PCL || true
  lpstat -p FollowMe-Plot-PS  || true

  ok "FollowMe printers configured."
  echo "    Check with: lpstat -W completed | head"
}

# ─── MODULE 6: Auto-mount (Qdrev/Pdrev) + Desktop Polkit rules ──────────────
# NOTE: Identical on Ubuntu and openSUSE — pam_exec and polkit are distro-
#       agnostic. Qdrev automount relies on the fstab entry from module 1.
#       Pdrev is a per-user symlink: /mnt/Pdrev → /mnt/Qdrev/Personal/<user>
#       created at login and removed at logout via pam_exec.
module_automount() {
  banner "Module 6 – Auto-mount (Qdrev/Pdrev) + Desktop Polkit Rules"

  # ── 1/3: Polkit rules for normal desktop use ────────────────────────────
  echo "[1/3] Writing desktop polkit rules..."
  mkdir -p /etc/polkit-1/rules.d/

  tee /etc/polkit-1/rules.d/45-desktop-users.rules > /dev/null <<'EOF'
// Allow active local sessions to perform normal desktop operations
// without authentication prompts.
// IT-admin overrides are handled by 49-domain-admins.rules.
polkit.addRule(function(action, subject) {

    if (!subject.active || !subject.local) return;

    var allow = [
        // USB / removable storage
        "org.freedesktop.udisks2.filesystem-mount",
        "org.freedesktop.udisks2.filesystem-mount-system",
        "org.freedesktop.udisks2.filesystem-unmount-others",
        "org.freedesktop.udisks2.encrypted-unlock",
        "org.freedesktop.udisks2.encrypted-unlock-system",
        "org.freedesktop.udisks2.eject-media",
        "org.freedesktop.udisks2.power-off-drive",
        "org.freedesktop.udisks2.loop-setup",
        // Network (WiFi, VPN, wired)
        "org.freedesktop.NetworkManager.network-control",
        "org.freedesktop.NetworkManager.settings.connection.modify",
        "org.freedesktop.NetworkManager.wifi.scan",
        "org.freedesktop.NetworkManager.checkpoint-rollback",
        // Power / session
        "org.freedesktop.login1.suspend",
        "org.freedesktop.login1.suspend-multiple-sessions",
        "org.freedesktop.login1.hibernate",
        "org.freedesktop.login1.hibernate-multiple-sessions",
        "org.freedesktop.login1.reboot",
        "org.freedesktop.login1.reboot-multiple-sessions",
        "org.freedesktop.login1.power-off",
        "org.freedesktop.login1.power-off-multiple-sessions",
        // Date / time
        "org.freedesktop.timedate1.set-time",
        "org.freedesktop.timedate1.set-timezone",
        "org.freedesktop.timedate1.set-ntp",
        // KDE colour management (display calibration)
        "org.freedesktop.color-manager.create-device",
        "org.freedesktop.color-manager.create-profile",
        "org.freedesktop.color-manager.delete-device",
        "org.freedesktop.color-manager.delete-profile",
        "org.freedesktop.color-manager.modify-device",
        "org.freedesktop.color-manager.modify-profile",
        // Locale / keyboard layout
        "org.freedesktop.locale1.set-locale",
        "org.freedesktop.locale1.set-keyboard",
        // PackageKit — repo refresh only (not install)
        "org.freedesktop.packagekit.system-sources-refresh",
    ];

    if (allow.indexOf(action.id) !== -1) {
        return polkit.Result.YES;
    }
});
EOF

  # ── 2/3: pam_exec script — Pdrev symlink at login/logout ───────────────
  echo "[2/3] Installing Pdrev session script..."

  tee /usr/local/sbin/pdrev-session.sh > /dev/null <<'EOF'
#!/usr/bin/env bash
# /usr/local/sbin/pdrev-session.sh
# Called by pam_exec at session open/close.
# Creates /mnt/Pdrev → /mnt/Qdrev/Personal/<user> at login,
# removes it at logout.
# PAM_USER and PAM_TYPE are injected by the PAM framework.

QDREV="/mnt/Qdrev"
PDREV="/mnt/Pdrev"
PERSONAL="${QDREV}/Personal/${PAM_USER}"

case "${PAM_TYPE}" in
  open_session)
    # Trigger systemd automount by touching the mountpoint, then wait
    ls "${QDREV}" >/dev/null 2>&1 &
    for i in $(seq 1 20); do
      mountpoint -q "${QDREV}" 2>/dev/null && break
      sleep 1
    done

    # Remove stale symlink from a previous session
    [ -L "${PDREV}" ] && rm -f "${PDREV}"
    # Remove empty mountpoint dir if left over
    [ -d "${PDREV}" ] && rmdir "${PDREV}" 2>/dev/null || true

    # Create symlink if the user's Personal folder exists on the share
    if [ -d "${PERSONAL}" ]; then
      ln -sf "${PERSONAL}" "${PDREV}"
    fi
    ;;

  close_session)
    # Only remove if symlink still points to this user's folder
    if [ -L "${PDREV}" ] && \
       [ "$(readlink "${PDREV}")" = "${PERSONAL}" ]; then
      rm -f "${PDREV}"
    fi
    ;;
esac

exit 0
EOF
  chmod 755 /usr/local/sbin/pdrev-session.sh

  # ── 3/3: Wire pam_exec into PAM common-session ─────────────────────────
  echo "[3/3] Adding PAM session hook..."
  PAM_FILE="/etc/pam.d/common-session"
  PAM_LINE="session optional pam_exec.so quiet /usr/local/sbin/pdrev-session.sh"

  if grep -qF "pdrev-session.sh" "${PAM_FILE}"; then
    echo "PAM hook already present — skipping."
  else
    echo "${PAM_LINE}" >> "${PAM_FILE}"
    ok "PAM hook added to ${PAM_FILE}"
  fi

  # Restart polkit for new rules (background to avoid killing the session)
  nohup bash -c 'sleep 2 && systemctl restart polkit' > /tmp/polkit-restart.log 2>&1 &

  ok "Module 6 complete."
  echo "    /mnt/Pdrev → /mnt/Qdrev/Personal/<username>  (created at next login)"
  echo "    Polkit rules:  USB, network, power, time — no prompts for local users"
  warn "Note: Qdrev (module 1) must be configured before Pdrev will appear."
  echo "    Log out and back in to test."
}

# ─── MAIN MENU ──────────────────────────────────────────────────────────────
show_menu() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║   DTU Sustain – openSUSE Tumbleweed Setup (Combined)    ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║  1) Q-Drive CIFS mount (direct DFS target)              ║"
  echo "║  2) Brother P950NW label printer (from source)          ║"
  echo "║  3) Microsoft Defender for Endpoint                     ║"
  echo "║  4) PolicyKit / KDE IT-Backdoor                         ║"
  echo "║  5) FollowMe printers (MFP-PCL + Plot-PS)              ║"
  echo "║  6) Auto-mount Qdrev/Pdrev + Desktop polkit rules       ║"
  echo "║                                                          ║"
  echo "║  A) Run ALL modules                                      ║"
  echo "║  Q) Quit                                                 ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

run_module() {
  case "$1" in
    1) need_root; module_qdrive    ;;
    2) need_root; module_brother   ;;
    3) need_root; module_defender  ;;
    4) need_root; module_polkit    ;;
    5) need_root; module_followme  ;;
    6) need_root; module_automount ;;
    *)
      fail "Unknown module: $1"
      return 1
      ;;
  esac
}

main() {
  if [[ $# -gt 0 ]]; then
    for mod in "$@"; do
      if [[ "${mod,,}" == "a" || "${mod,,}" == "all" ]]; then
        for i in 1 2 3 4 5 6; do run_module "$i"; done
        exit 0
      fi
      run_module "$mod"
    done
    exit 0
  fi

  while true; do
    show_menu
    read -rp "Choose module(s) [1-6, A, Q]: " CHOICE
    case "${CHOICE,,}" in
      1|2|3|4|5|6) run_module "$CHOICE" ;;
      a|all)
        for i in 1 2 3 4 5 6; do run_module "$i"; done
        ;;
      q|quit|exit) echo "Bye."; exit 0 ;;
      *) warn "Invalid choice: $CHOICE" ;;
    esac
  done
}

main "$@"
