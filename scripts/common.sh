#!/usr/bin/env bash
###############################################################################
# DTU Sustain Setup – Shared helpers for all module scripts
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

# ─── Resolve SCRIPT_DIR ─────────────────────────────────────────────────────
# Each module script should call: SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Then source common.sh: source "${SCRIPT_DIR}/../common.sh"
