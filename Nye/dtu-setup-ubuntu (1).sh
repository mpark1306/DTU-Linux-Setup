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
#   6) Auto-mount (Qdrev/Pdrev) + Desktop Polkit rules
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
    audit|block) mdatp network-protection feature-control set-mode --value "$NP_MODE" || true ;;
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
  banner "Module 4 – PolicyKit / KDE IT Admin Backdoor"

  echo "[1/3] Configuring admin identities..."
  tee /etc/polkit-1/localauthority.conf.d/50-localauthority.conf > /dev/null <<'EOF'
[Configuration]
AdminIdentities=unix-user:0;unix-group:sudo;unix-group:wheel;unix-group:SUS-ITAdm-Client-Admins
EOF

  echo "[2/3] Creating PolKit rules..."
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

  echo "[3/3] Restarting polkit (background, 2s delay)..."
  nohup bash -c 'sleep 2 && systemctl restart polkit' > /tmp/polkit-restart.log 2>&1 &

  ok "PolicyKit configured for SUS-ITAdm-Client-Admins."
  echo "    KDE auth dialog will now show a username field."
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
  echo "    Log out og ind igen for at teste."
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
  # Allow non-interactive: ./script.sh 1 3 5
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

  # Interactive menu
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
