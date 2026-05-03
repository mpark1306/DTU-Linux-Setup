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
