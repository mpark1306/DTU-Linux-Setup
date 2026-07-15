#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Shared helpers for all module scripts
###############################################################################

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

# ─── Site configuration ─────────────────────────────────────────────────────
# Sources /etc/dtu-setup/site.conf if present, then defines safe defaults so
# scripts can reference $SITE_* variables without repeating fallback logic.
# Defaults match the DTU production environment for backward compatibility.
load_site_conf() {
  local dept="${DTU_DEPARTMENT:-}"
  local dept_conf="/etc/dtu-setup/dtu-${dept}.env"
  local default_conf="${SITE_CONF:-/etc/dtu-setup/site.conf}"

  if [[ -n "$dept" && -r "$dept_conf" ]]; then
    # shellcheck disable=SC1090
    source "$dept_conf"
  elif [[ -r "$default_conf" ]]; then
    # shellcheck disable=SC1090
    source "$default_conf"
  fi

  # Active Directory / Kerberos
  : "${SITE_AD_DOMAIN:=WIN.DTU.DK}"
  : "${SITE_AD_REALM:=win.dtu.dk}"
  : "${SITE_AD_ADMIN_GROUP:=SUS-ITAdm-Client-Admins}"

  # File servers
  : "${SITE_FILE_SERVER:=<fileserver>}"
  : "${SITE_FILE_SERVER_QUMULO:=<qumulo-server>}"
  : "${SITE_USERS_BASE:=Users}"
  : "${SITE_SUSTAIN_Q_SHARE:=Qdrev/SUS}"
  : "${SITE_SUSTAIN_P_SUBPATH:=Qdrev/SUS/Personal}"
  : "${SITE_AIT_O_SHARE:=}"

  # M-Drive (personal home, Users0..Users9). Central drive shared by all
  # departments — server defaults to SITE_FILE_SERVER, top share to "Users$".
  : "${SITE_MDRIVE_SERVER:=${SITE_FILE_SERVER}}"
  : "${SITE_MDRIVE_BASE:=Users\$}"

  # Printing
  : "${SITE_PRINT_SERVER:=konfigureret via site.conf}"
  : "${SITE_WEBPRINT_URL:=https://webprint.dtu.dk}"

  # WiFi
  : "${SITE_WIFI_SSID:=DTUSecure}"
  : "${SITE_WIFI_IDENTITY_SUFFIX:=@win.dtu.dk}"

  # Defender
  : "${SITE_DEFENDER_ONBOARDING_URL:=konfigureret via site.conf/download/MicrosoftDefenderATPOnboardingLinuxServer.py}"

  # Helpdesk
  : "${SITE_HELPDESK_URL:=https://serviceportal.dtu.dk}"
  : "${SITE_HELPDESK_EMAIL:=ait@dtu.dk}"

  export SITE_AD_DOMAIN SITE_AD_REALM SITE_AD_ADMIN_GROUP
  export SITE_FILE_SERVER SITE_FILE_SERVER_QUMULO SITE_USERS_BASE
  export SITE_SUSTAIN_Q_SHARE SITE_SUSTAIN_P_SUBPATH SITE_AIT_O_SHARE
  export SITE_MDRIVE_SERVER SITE_MDRIVE_BASE
  export SITE_PRINT_SERVER SITE_WEBPRINT_URL
  export SITE_WIFI_SSID SITE_WIFI_IDENTITY_SUFFIX
  export SITE_DEFENDER_ONBOARDING_URL
  export SITE_HELPDESK_URL SITE_HELPDESK_EMAIL
}

# Auto-load on source so every module script sees $SITE_* variables.
load_site_conf

# ─── Credential helpers ─────────────────────────────────────────────────────
# Scripts receive credentials via environment variables set by the GUI.
# If not set, fall back to interactive prompts (for CLI usage).
get_username() {
  if [[ -n "${DTU_USERNAME:-}" ]]; then
    echo "$DTU_USERNAME"
  else
    read -rp "Enter domain username (e.g. mpark): " _u
    echo "$_u"
  fi
}

get_password() {
  if [[ -n "${DTU_PASSWORD:-}" ]]; then
    echo "$DTU_PASSWORD"
  else
    read -rsp "Enter password: " _p; echo >&2
    echo "$_p"
  fi
}

get_admin_password() {
  if [[ -n "${DTU_ADMIN_PASSWORD:-}" ]]; then
    echo "$DTU_ADMIN_PASSWORD"
  else
    read -rsp "Enter domain admin password: " _p; echo >&2
    echo "$_p"
  fi
}

# ─── APT lock helper ────────────────────────────────────────────────────────
# Wait for dpkg / apt locks to be released before running apt-get.
# Call: apt_wait  (before the first apt-get in a module)
apt_wait() {
  local max_wait=120   # seconds
  local waited=0
  while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock &>/dev/null 2>&1; do
    if (( waited == 0 )); then
      warn "Waiting for apt/dpkg lock to be released..."
    fi
    sleep 2
    waited=$((waited + 2))
    if (( waited >= max_wait )); then
      fail "Timed out waiting for apt lock after ${max_wait}s"
      return 1
    fi
  done
}

# ─── CIFS mount helpers ─────────────────────────────────────────────────────
# Shared logic for the personal M-Drive (Users0..9 auto-discovery) and any
# fixed CIFS share, used by both the AIT and Sustain profiles on Ubuntu and
# openSUSE. Mirrors the proven approach from mount-mdrive-kubuntu.sh:
#   • real short-lived test-mounts to locate/verify a share (not smbclient ls)
#   • vers=3.0/ntlmssp/nodfs options that avoid the kernel DFS-referral bug
#   • systemd automount with nofail + idle-timeout so boot never hangs
CIFS_MOUNT_OPTS="vers=3.0,sec=ntlmssp,nosharesock,nodfs,iocharset=utf8,serverino"
CIFS_SYSTEMD_OPTS="_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.mount-timeout=30"

# cifs_test_mount SERVER SHARE_PATH CREDS_FILE UID GID
# Attempts a short-lived CIFS mount to verify a share path is reachable.
# Returns 0 if it mounts (and cleanly unmounts), 1 otherwise.
cifs_test_mount() {
  local server="$1" path="$2" creds="$3" uid="$4" gid="$5"
  local tmp; tmp="$(mktemp -d /tmp/dtu-probe.XXXXXX)"
  if mount -t cifs "//${server}/${path}" "$tmp" \
       -o "credentials=${creds},uid=${uid},gid=${gid},${CIFS_MOUNT_OPTS}" \
       >/dev/null 2>&1; then
    umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
    rmdir "$tmp" 2>/dev/null || true
    return 0
  fi
  rmdir "$tmp" 2>/dev/null || true
  return 1
}

# cifs_setup_share SERVER SHARE_PATH MOUNTPOINT CREDS_FILE UID GID
# Creates the mountpoint and writes/refreshes a single /etc/fstab line using
# the shared CIFS + systemd automount options. Any prior line for the same
# mountpoint is removed first, and the share is unmounted for a clean state.
cifs_setup_share() {
  local server="$1" path="$2" mp="$3" creds="$4" uid="$5" gid="$6"
  local fstab="/etc/fstab"
  mkdir -p "$mp"
  chown "$uid:$gid" "$mp"
  chmod 0770 "$mp"
  local line="//${server}/${path}  ${mp}  cifs  credentials=${creds},uid=${uid},gid=${gid},dir_mode=0770,file_mode=0660,${CIFS_MOUNT_OPTS},${CIFS_SYSTEMD_OPTS}  0  0"
  sed -i "\|[[:space:]]${mp}[[:space:]].*cifs|d" "$fstab" 2>/dev/null || true
  printf '%s\n' "$line" >> "$fstab"
  if mount | grep -qE "[[:space:]]${mp}[[:space:]]"; then
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
  fi
}

# cifs_start_automount MOUNTPOINT
# (Re)starts the systemd automount unit derived from the mountpoint path.
cifs_start_automount() {
  local mp="$1" unit
  unit="$(systemd-escape -p --suffix=automount "$mp")"
  systemctl restart "$unit" 2>/dev/null || systemctl start "$unit" || true
}

# cifs_find_mdrive_subdir SERVER USERS_BASE USERNAME CREDS_FILE UID GID CACHE_FILE
# Locates the user's personal M-Drive folder by test-mounting
# USERS_BASE/Users0..Users9/USERNAME, honouring a cache file. Echoes the
# matching subdir (e.g. "Users7") on stdout and returns 0; returns 1 if none.
cifs_find_mdrive_subdir() {
  local server="$1" base="$2" user="$3" creds="$4" uid="$5" gid="$6" cache="$7"
  local d cached
  if [[ -f "$cache" ]]; then
    cached="$(cat "$cache")"
    if cifs_test_mount "$server" "${base}/${cached}/${user}" "$creds" "$uid" "$gid"; then
      printf '%s' "$cached"; return 0
    fi
  fi
  for d in Users0 Users1 Users2 Users3 Users4 Users5 Users6 Users7 Users8 Users9; do
    if cifs_test_mount "$server" "${base}/${d}/${user}" "$creds" "$uid" "$gid"; then
      mkdir -p "$(dirname "$cache")"
      printf '%s' "$d" > "$cache"
      chown -R "$uid:$gid" "$(dirname "$cache")"
      printf '%s' "$d"; return 0
    fi
  done
  return 1
}

# ─── Resolve SCRIPT_DIR ─────────────────────────────────────────────────────
# Each module script should call: SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Then source common.sh: source "${SCRIPT_DIR}/../common.sh"
