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
  local conf="${SITE_CONF:-/etc/dtu-setup/site.conf}"
  if [[ -r "$conf" ]]; then
    # shellcheck disable=SC1090
    source "$conf"
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

# ─── Resolve SCRIPT_DIR ─────────────────────────────────────────────────────
# Each module script should call: SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Then source common.sh: source "${SCRIPT_DIR}/../common.sh"
