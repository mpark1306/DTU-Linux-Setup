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
#   6) OneDrive for Business (abraunegg client)
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
#   - OneDrive: zypper or build-from-source (no OBS apt repo);
#     monthly cron update for source builds; no curl workarounds needed
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
  banner "Module 4 – PolicyKit / KDE IT Admin Backdoor + Domain User Rights"

  echo "[1/4] Creating PolKit admin rules..."
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

  # ── Step 2: Domain user daily-use rights ──────────────────────────────
  echo "[2/4] Creating domain-user rights (50-domain-users.rules)..."
  tee /etc/polkit-1/rules.d/50-domain-users.rules > /dev/null <<'EOF'
// Domain Users – daily-use rights without admin password prompt.
// IT admins (SUS-ITAdm-Client-Admins) are already handled by
// 49-domain-admins.rules and get YES for everything.
//
// Installed by dtu-setup-opensuse-tw.sh Module 4.

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

  # ── Step 3: Background zypper refresh timer ─────────────────────────
  # Discover triggers PackageKit RefreshCache which prompts for auth.
  # By keeping repos fresh in the background, Discover finds them already
  # up-to-date and skips the refresh entirely.
  echo "[3/4] Installing zypper-refresh systemd timer (every 4 hours)..."

  cat > /etc/systemd/system/zypper-refresh.service <<'UNIT'
[Unit]
Description=Refresh zypper repositories
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/zypper --non-interactive refresh
TimeoutStartSec=300
UNIT

  cat > /etc/systemd/system/zypper-refresh.timer <<'TIMER'
[Unit]
Description=Refresh zypper repositories every 4 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=4h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
TIMER

  systemctl daemon-reload
  systemctl enable --now zypper-refresh.timer

  echo "[4/4] Restarting polkit..."
  systemctl restart polkit
  sleep 1  # wait for polkit to be fully ready

  ok "PolicyKit configured for SUS-ITAdm-Client-Admins + Domain Users."
  echo "    KDE auth dialog will now show a username field."
  echo "    Admin identities set via 40-admin-identities.rules."
  echo "    Domain users can update packages, mount USB, manage WiFi, etc."
  echo "    Zypper repos will auto-refresh every 4 hours."
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

# ─── MODULE 6: OneDrive for Business ────────────────────────────────────────
# NOTE: Uses the abraunegg OneDrive Client for Linux.
#       On Tumbleweed we try the zypper package first, then fall back to
#       building from source (requires ldc D-compiler).
#
#       Authentication is interactive (browser-based) and must be completed
#       manually by the target user after this module runs.
#
#       Sync strategy:
#         ~/OneDrive/              ← sync root (two-way sync with M365)
#
#       Updates: handled by zypper dup (if installed from repo) or
#                manual rebuild (if built from source).
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

  # ── Step 1: Install OneDrive client ──────────────────────────────────────
  echo "[1/7] Installing OneDrive client..."

  INSTALLED_FROM="unknown"

  # Try zypper first (Tumbleweed may have community package)
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

    # Build with LDC (available in Tumbleweed repos)
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

  # ── Step 2: Create configuration ─────────────────────────────────────────
  echo "[2/7] Writing OneDrive configuration..."
  sudo -u "$USERNAME" mkdir -p "$CONFIG_DIR"

  cat > "${CONFIG_DIR}/config" <<'CONF'
# OneDrive for Business – DTU Sustain
# Generated by dtu-setup-opensuse-tw.sh

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
CONF

  chown -R "$UID_NUM":"$GID_NUM" "$CONFIG_DIR"
  chmod 600 "${CONFIG_DIR}/config"

  # ── Step 3: Create OneDrive directory structure ──────────────────────────
  echo "[3/7] Creating OneDrive directory structure..."
  sudo -u "$USERNAME" mkdir -p "${ONEDRIVE_DIR}"

  # ── Step 4: Install sleep/resume handler ─────────────────────────────────
  echo "[4/7] Installing sleep/resume handler (restart sync on wake)..."
  mkdir -p /usr/lib/systemd/system-sleep
  cat > /usr/lib/systemd/system-sleep/onedrive-resume.sh <<'SLEEP'
#!/bin/sh
# Restart OneDrive user services on resume to clear stale curl connections.
# Installed by dtu-setup-opensuse-tw.sh Module 6.
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

  # ── Step 5: Source-build update helper (if built from source) ────────────
  if [ "$INSTALLED_FROM" = "source" ]; then
    echo "[5/7] Installing update helper script..."
    cat > /usr/local/sbin/onedrive-update.sh <<'UPDATER'
#!/usr/bin/env bash
set -euo pipefail
# Update abraunegg OneDrive client from source.
# Run as root. Safe to call from cron or manually.
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

    # Monthly cron job for updates
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

  # ── Step 6: Print manual auth instructions ───────────────────────────────
  echo "[6/7] Installation complete."
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
  if [ "$INSTALLED_FROM" = "source" ]; then
    echo "    Updates    : monthly via /etc/cron.monthly/onedrive-update"
  else
    echo "    Updates    : automatic via zypper dup"
  fi
}

# ─── MAIN MENU ──────────────────────────────────────────────────────────────
show_menu() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║   DTU Sustain – openSUSE Tumbleweed Setup (Combined)    ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║  1) Q-Drive CIFS mount (direct DFS target)                ║"
  echo "║  2) Brother P950NW label printer (from source)          ║"
  echo "║  3) Microsoft Defender for Endpoint                     ║"
  echo "║  4) PolicyKit / KDE IT-Backdoor                         ║"
  echo "║  5) FollowMe printers (MFP-PCL + Plot-PS)              ║"
  echo "║  6) OneDrive for Business (sync only)                   ║"
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
