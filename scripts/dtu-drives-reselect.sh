#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Re-pick Q-Drive/P-Drive target after a network change
#
# DTUSecure WiFi and some VPN profiles cannot route to the Qumulo backend
# used for the direct CIFS mount, while the DFS root is reachable from
# (almost) anywhere. This re-tests reachability and, if the reachable
# target changed since the last run, rewrites the fstab entries and
# remounts — so Q-Drive/P-Drive keep working when moving between wired,
# DTUSecure WiFi and VPN, instead of failing silently.
#
# Invoked by the NetworkManager dispatcher hook installed by
# deploy-drives-autoswitch.sh; safe to run manually as root too.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="/var/log/dtu-drives-reselect.log"
log() { echo "$(date '+%F %T'): $*" >> "$LOG" 2>/dev/null || true; }

if [[ $EUID -ne 0 ]]; then
  fail "Must run as root."
  exit 1
fi

DRIVES_CONF="/etc/dtu-setup/drives.conf"
[[ -f "$DRIVES_CONF" ]] || exit 0

DEPARTMENT="$(grep -E '^DEPARTMENT=' "$DRIVES_CONF" | cut -d= -f2-)"

# ── AIT ─────────────────────────────────────────────────────────────────────
#
# Målskift er Sustain-only: AIT har ét filserver-mål, så der er ikke noget at
# vælge imellem. Men frysningen er ikke Sustain-only, og det var netop på en
# AIT-maskine den blev meldt ind. Scriptet afsluttede her for alt andet end
# sustain, så AIT havde hook'en installeret og fik intet ud af den: kunne
# serveren ikke nås, blev automount'en ved med at være armet, og hver adgang
# til /mnt blokerede.
#
# For AIT er opgaven derfor kun den ene: arm automount'en når serveren svarer,
# og afvæbn den når den ikke gør.
if [[ "$DEPARTMENT" == "ait" ]]; then
  AIT_SERVER="$(grep -E '^SERVER=' "$DRIVES_CONF" | cut -d= -f2-)"
  AIT_SERVER="${AIT_SERVER:-${SITE_MDRIVE_SERVER:-${SITE_FILE_SERVER:-}}}"
  [[ -n "$AIT_SERVER" ]] || exit 0

  ait_mounts=()
  while IFS= read -r mp; do
    [[ -n "$mp" ]] && ait_mounts+=("$mp")
  done < <(grep -E '^(MOUNT_POINT|O_MOUNT_POINT)=' "$DRIVES_CONF" | cut -d= -f2-)
  [[ ${#ait_mounts[@]} -gt 0 ]] || ait_mounts=(/mnt/Mdrev)

  if cifs_host_up "$AIT_SERVER" 445 3; then
    for mp in "${ait_mounts[@]}"; do
      cifs_automount_active "$mp" || {
        log "${AIT_SERVER} kan nås igen — armer automount for ${mp}."
        cifs_start_automount "$mp"
      }
    done
  else
    for mp in "${ait_mounts[@]}"; do
      if cifs_automount_active "$mp"; then
        log "${AIT_SERVER} kan ikke nås — afvæbner automount for ${mp} så stien ikke blokerer."
        cifs_stop_automount "$mp"
      fi
    done
  fi
  exit 0
fi

[[ "$DEPARTMENT" == "sustain" ]] || exit 0

USERNAME="$(grep -E '^USERNAME=' "$DRIVES_CONF" | cut -d= -f2-)"
PREV_TARGET="$(grep -E '^TARGET=' "$DRIVES_CONF" | cut -d= -f2-)"
[[ -n "$USERNAME" ]] || exit 0
id "$USERNAME" >/dev/null 2>&1 || exit 0

UID_NUM="$(id -u "$USERNAME")"
GID_NUM="$(id -g "$USERNAME")"
CREDS_FILE="$(cifs_creds_file_resolve "$USERNAME")"
[[ -r "$CREDS_FILE" ]] || { log "Credentials file missing: ${CREDS_FILE}"; exit 0; }

MOUNTPOINT="/mnt/Qdrev"
P_MOUNTPOINT="/mnt/Personal"

# Kan ingen af målene nås, er den rigtige tilstand ingen automount. Før stod
# der "leaving mounts as-is", hvilket lod stierne blive ved med at være
# autofs-fælder mod en server der ikke svarer — det er den frysning der er
# meldt ind. Hook'en kører ved hvert netværksskift, så de armes igen af sig
# selv, så snart et mål svarer.
if ! sustain_pick_target "$USERNAME"; then
  for mp in "$MOUNTPOINT" "$P_MOUNTPOINT"; do
    if cifs_automount_active "$mp"; then
      log "Hverken Qumulo eller DFS-roden kan nås — afvæbner automount for ${mp}."
      cifs_stop_automount "$mp"
    fi
  done
  exit 0
fi

# Uændret mål er ikke i sig selv grund til at gøre ingenting: er automount'en
# afvæbnet af grenen ovenfor, skal den armes igen, også selvom vi lander på
# samme mål som sidst. Uden det ville drevene aldrig komme tilbage efter en
# tur uden netværk.
if [[ "$TARGET_LABEL" == "$PREV_TARGET" ]] \
   && cifs_automount_active "$MOUNTPOINT" \
   && cifs_automount_active "$P_MOUNTPOINT"; then
  exit 0
fi

log "Network target changed: ${PREV_TARGET:-none} -> ${TARGET_LABEL}. Remounting Q-Drive/P-Drive for ${USERNAME}."

sustain_write_fstab "$MOUNTPOINT" "$P_MOUNTPOINT" "$CREDS_FILE" "$UID_NUM" "$GID_NUM"
systemctl daemon-reload
cifs_start_automount "$MOUNTPOINT"
cifs_start_automount "$P_MOUNTPOINT"

sed -i "s/^TARGET=.*/TARGET=${TARGET_LABEL}/" "$DRIVES_CONF"
log "Remounted using ${TARGET_LABEL} target //${SERVER}"
