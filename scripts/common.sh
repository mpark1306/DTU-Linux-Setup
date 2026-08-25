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
# Sources /etc/dtu-setup/site.conf (or the department profile) if present, then
# fills in defaults so scripts can reference $SITE_* without repeating fallback
# logic.
#
# Two classes of variable:
#
#   • Values that are the same across every DTU site (AD realm, DTUSecure SSID,
#     WebPrint URL, …) get a real default here.
#   • Values that identify specific infrastructure (file servers, print server,
#     Defender onboarding URL, AD admin group) get NO default. A missing
#     site.conf must stop the module, not make it run against a placeholder
#     host — that is exactly how the 2026.07.01 image shipped broken.
#
# Modules declare what they actually need with site_require (see below).

# Path of the config file that was sourced; empty when none was found.
SITE_CONF_LOADED=""

# site_is_placeholder VALUE
# True when a value is unset, empty, or still holds a template placeholder.
# Such a value must never reach a mount command or a download URL.
#
# Any value containing an <angle-bracketed> token counts, whether it is the
# whole value (`<fileserver>`) or embedded in a URL
# (`https://<defender-host>/download/...`). No legitimate hostname, share or
# URL contains angle brackets, so this is safe to apply broadly.
site_is_placeholder() {
  local v="${1-}"
  [[ -z "$v" ]] && return 0
  [[ "$v" == *"<"*">"* ]] && return 0
  # Text left behind by an over-eager search-and-replace in earlier releases.
  [[ "$v" == *"konfigureret via site.conf"* ]] && return 0
  return 1
}

# site_require VAR [VAR...]
# Stops the module with an actionable message if any named SITE_* variable is
# unset, empty, or still a placeholder. Call it near the top of a module and
# list only the variables that module actually uses.
site_require() {
  local missing=() v
  for v in "$@"; do
    if site_is_placeholder "${!v-}"; then
      missing+=("$v")
    fi
  done
  (( ${#missing[@]} == 0 )) && return 0

  fail "Site configuration is missing or incomplete."
  echo ""
  if [[ -n "$SITE_CONF_LOADED" ]]; then
    echo "  Loaded: $SITE_CONF_LOADED"
    echo "  These variables are unset or still hold a template placeholder:"
  else
    echo "  No site configuration was found. Looked for:"
    echo "    /etc/dtu-setup/dtu-${DTU_DEPARTMENT:-<department>}.env"
    echo "    ${SITE_CONF:-/etc/dtu-setup/site.conf}"
    echo ""
    echo "  This module requires:"
  fi
  for v in "${missing[@]}"; do
    echo "    • $v"
  done
  echo ""
  echo "  Install a site profile, then run the module again:"
  echo "    sudo install -d /etc/dtu-setup"
  echo "    sudo install -m 0644 <profile>.env /etc/dtu-setup/site.conf"
  echo ""
  echo "  See data/site.conf.example for every supported variable. DTU staff"
  echo "  can request the ready-made Sustain / AIT profiles from the maintainer."
  exit 1
}

load_site_conf() {
  local dept="${DTU_DEPARTMENT:-}"
  local dept_conf="/etc/dtu-setup/dtu-${dept}.env"
  local default_conf="${SITE_CONF:-/etc/dtu-setup/site.conf}"

  if [[ -n "$dept" && -r "$dept_conf" ]]; then
    # shellcheck disable=SC1090
    source "$dept_conf"
    SITE_CONF_LOADED="$dept_conf"
  elif [[ -r "$default_conf" ]]; then
    # shellcheck disable=SC1090
    source "$default_conf"
    SITE_CONF_LOADED="$default_conf"
  fi

  # site.conf is often installed straight from a department profile
  # (dtu-ait.env / dtu-sustain.env), which hardcodes DTU_DEPARTMENT itself. That
  # would silently override the department the GUI/env file already chose
  # (e.g. "sustain" script env clobbered by a leftover "ait" in site.conf).
  # The caller-supplied value always wins.
  if [[ -n "$dept" ]]; then
    DTU_DEPARTMENT="$dept"
  fi

  # ── Defaults that are valid at every DTU site ──────────────────────────────
  : "${SITE_AD_DOMAIN:=WIN.DTU.DK}"
  : "${SITE_AD_REALM:=win.dtu.dk}"
  : "${SITE_USERS_BASE:=Users}"
  : "${SITE_MDRIVE_BASE:=Users\$}"
  : "${SITE_SUSTAIN_Q_SHARE:=Qdrev/SUS}"
  : "${SITE_SUSTAIN_P_SUBPATH:=Qdrev/SUS/Personal}"
  : "${SITE_WEBPRINT_URL:=https://webprint.dtu.dk}"
  : "${SITE_WIFI_SSID:=DTUSecure}"
  : "${SITE_WIFI_IDENTITY_SUFFIX:=@win.dtu.dk}"
  : "${SITE_HELPDESK_URL:=https://serviceportal.dtu.dk}"
  : "${SITE_HELPDESK_EMAIL:=ait@dtu.dk}"

  # ── Site-specific: deliberately no default ─────────────────────────────────
  # Empty means "not configured". Modules that need one call site_require and
  # stop with an actionable message instead of mounting //<fileserver>/...
  : "${SITE_AD_ADMIN_GROUP:=}"
  : "${SITE_FILE_SERVER:=}"
  : "${SITE_FILE_SERVER_QUMULO:=}"
  : "${SITE_MDRIVE_SERVER:=${SITE_FILE_SERVER}}"
  : "${SITE_AIT_O_SHARE:=}"
  : "${SITE_PRINT_SERVER:=}"
  # Direkte plotter hos Sustain. Ikke en printserver: der spooles til enhedens
  # egen JetDirect-port, ikke gennem en SMB-kø. Derfor et selvstændigt
  # værtsnavn og ingen default.
  : "${SITE_SUSTAIN_PLOT_SERVER:=}"
  : "${SITE_DEFENDER_ONBOARDING_URL:=}"
  # Share names on the Qumulo backend. They differ from the DFS paths above
  # and are site-specific, so they get no default either.
  : "${SITE_SUSTAIN_Q_SHARE_QUMULO:=}"
  : "${SITE_SUSTAIN_P_SUBPATH_QUMULO:=${SITE_SUSTAIN_Q_SHARE_QUMULO:+${SITE_SUSTAIN_Q_SHARE_QUMULO}/Personal}}"

  # A template placeholder left in place is worse than no value at all: it
  # produces //<fileserver>/Qdrev/SUS rather than an error. Blank them so
  # site_require reports them as missing.
  local v
  for v in SITE_AD_ADMIN_GROUP SITE_FILE_SERVER SITE_FILE_SERVER_QUMULO \
           SITE_MDRIVE_SERVER SITE_AIT_O_SHARE SITE_PRINT_SERVER \
         SITE_SUSTAIN_PLOT_SERVER \
           SITE_DEFENDER_ONBOARDING_URL SITE_SUSTAIN_Q_SHARE_QUMULO \
           SITE_SUSTAIN_P_SUBPATH_QUMULO; do
    if site_is_placeholder "${!v-}"; then
      printf -v "$v" '%s' ""
    fi
  done

  export SITE_CONF_LOADED
  export SITE_AD_DOMAIN SITE_AD_REALM SITE_AD_ADMIN_GROUP
  export SITE_FILE_SERVER SITE_FILE_SERVER_QUMULO SITE_USERS_BASE
  export SITE_SUSTAIN_Q_SHARE SITE_SUSTAIN_P_SUBPATH SITE_AIT_O_SHARE
  export SITE_SUSTAIN_Q_SHARE_QUMULO SITE_SUSTAIN_P_SUBPATH_QUMULO
  export SITE_MDRIVE_SERVER SITE_MDRIVE_BASE
  export SITE_PRINT_SERVER SITE_SUSTAIN_PLOT_SERVER SITE_WEBPRINT_URL
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

# ─── CIFS credentials file ──────────────────────────────────────────────────
# The Sustain profile keeps ONE credentials file per user, shared by Q-Drive
# and P-Drive and reused across targets: sustain_pick_target switches $SERVER
# between the Qumulo host and the DFS root at runtime, but the credentials are
# identical on both. The name is therefore derived from SITE_FILE_SERVER
# (configuration, fixed) and never from $SERVER.
#
# Releases up to v1.4.0 wrote the literal path `.smbcred-<fileserver>` — a
# scrubbed placeholder that leaked out of the template and into real machines.
# Writers now use cifs_creds_file; readers use cifs_creds_file_resolve so a
# machine set up by an older release keeps working until qdrive.sh reruns.

CIFS_CREDS_LEGACY_SUFFIX='.smbcred-<fileserver>'

# cifs_creds_file USERNAME → path a writer should create
cifs_creds_file() {
  local user="$1" tag
  tag="$(printf '%s' "${SITE_FILE_SERVER}" | cut -d. -f1)"
  printf '/home/%s/.smbcred-%s' "$user" "$tag"
}

# cifs_creds_file_resolve USERNAME → path a reader should use
# Prefers the current name, falls back to the legacy one if only that exists.
cifs_creds_file_resolve() {
  local user="$1" current legacy
  current="$(cifs_creds_file "$user")"
  legacy="/home/${user}/${CIFS_CREDS_LEGACY_SUFFIX}"
  if [[ -r "$current" ]]; then
    printf '%s' "$current"
  elif [[ -r "$legacy" ]]; then
    printf '%s' "$legacy"
  else
    printf '%s' "$current"
  fi
}

# cifs_creds_drop_legacy USERNAME
# Removes the legacy credentials file once the current one has been written.
# It holds a cleartext domain password, so leaving it behind is a real leak.
cifs_creds_drop_legacy() {
  local legacy="/home/$1/${CIFS_CREDS_LEGACY_SUFFIX}"
  [[ -e "$legacy" ]] || return 0
  rm -f "$legacy" && warn "Removed legacy credentials file ${legacy}"
}

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

# cifs_host_up HOST [PORT] [TIMEOUT_SEC]
# Fast TCP reachability probe (no mount, no extra packages) used to detect
# whether the current network (wired / DTUSecure WiFi / VPN) can route to
# a given file server at all before attempting a CIFS mount.
cifs_host_up() {
  local host="$1" port="${2:-445}" timeout_s="${3:-3}"
  timeout "$timeout_s" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# sustain_pick_target USERNAME
# Picks the Q-Drive/P-Drive CIFS target for the Sustain profile based on
# which server is reachable right now, not just which is configured.
# DTUSecure WiFi and some VPN profiles cannot route to the Qumulo backend
# directly, so falling back to the DFS root keeps Q-Drive (and best-effort
# P-Drive) working there instead of failing outright. Sets SERVER,
# Q_SHARE_PATH, P_SHARE_PATH, CIFS_OPTS, TARGET_LABEL. Returns 1 if neither
# server is reachable.

# SERVER, Q_SHARE_PATH, P_SHARE_PATH, CIFS_OPTS and TARGET_LABEL are the
# function's output: callers read them after it returns.
# shellcheck disable=SC2034
sustain_pick_target() {
  local user="$1"
  # Called from qdrive.sh, dtu-drives-reselect.sh and deploy-drives-autoswitch.sh.
  # Guard here as well so every caller gets the actionable message rather than
  # "neither server is reachable" when the real problem is a missing site.conf.
  site_require SITE_FILE_SERVER
  # Only usable when both the Qumulo host and its share names are configured;
  # otherwise fall through to the DFS root rather than mounting a guessed path.
  if [[ -n "${SITE_FILE_SERVER_QUMULO:-}" && -n "${SITE_SUSTAIN_Q_SHARE_QUMULO:-}" ]] \
     && cifs_host_up "$SITE_FILE_SERVER_QUMULO"; then
    SERVER="$SITE_FILE_SERVER_QUMULO"
    Q_SHARE_PATH="$SITE_SUSTAIN_Q_SHARE_QUMULO"
    P_SHARE_PATH="${SITE_SUSTAIN_P_SUBPATH_QUMULO}/${user}"
    CIFS_OPTS="vers=3.0,sec=ntlmssp,nosharesock,nodfs"
    TARGET_LABEL="qumulo-direct"
    return 0
  fi
  if cifs_host_up "$SITE_FILE_SERVER"; then
    SERVER="$SITE_FILE_SERVER"
    Q_SHARE_PATH="$SITE_SUSTAIN_Q_SHARE"
    P_SHARE_PATH="${SITE_SUSTAIN_P_SUBPATH}/${user}"
    CIFS_OPTS="serverino"
    TARGET_LABEL="dfs-root"
    return 0
  fi
  return 1
}

# sustain_write_fstab MOUNTPOINT P_MOUNTPOINT CREDS_FILE UID GID
# Writes the Q-Drive/P-Drive fstab lines using the SERVER/Q_SHARE_PATH/
# P_SHARE_PATH/CIFS_OPTS globals set by sustain_pick_target, replacing any
# prior entry for either mountpoint. Shared by qdrive.sh (initial setup)
# and dtu-drives-reselect.sh (re-run after a network change) so both stay
# in sync.
sustain_write_fstab() {
  local mp="$1" p_mp="$2" creds="$3" uid="$4" gid="$5"
  local fstab="/etc/fstab"

  # Back up before rewriting. dtu-drives-reselect.sh calls this from a
  # NetworkManager dispatcher hook, i.e. unattended on every network change —
  # a bad edit there would otherwise be unrecoverable at the next boot.
  cp -a "$fstab" "${fstab}.bak-dtu-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

  mkdir -p "$mp" "$p_mp"
  chown "$uid:$gid" "$mp" "$p_mp"
  chmod 0770 "$mp" "$p_mp"

  local q_line="//${SERVER}/${Q_SHARE_PATH}  ${mp}  cifs  credentials=${creds},iocharset=utf8,uid=${uid},gid=${gid},dir_mode=0770,file_mode=0660,${CIFS_OPTS},_netdev,x-systemd.automount  0  0"
  local p_line="//${SERVER}/${P_SHARE_PATH}  ${p_mp}  cifs  credentials=${creds},iocharset=utf8,uid=${uid},gid=${gid},dir_mode=0770,file_mode=0660,${CIFS_OPTS},_netdev,x-systemd.automount  0  0"

  sed -i "\|[[:space:]]${mp}[[:space:]].*cifs|d" "$fstab" 2>/dev/null || true
  sed -i "\|[[:space:]]${p_mp}[[:space:]].*cifs|d" "$fstab" 2>/dev/null || true
  printf '%s\n%s\n' "$q_line" "$p_line" >> "$fstab"

  local m
  for m in "$mp" "$p_mp"; do
    if mount | grep -qE "[[:space:]]${m}[[:space:]]"; then
      umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    fi
  done
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
