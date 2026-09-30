#!/usr/bin/env bash
###############################################################################
# DTU – Ubuntu 24.04 / 26.04 – Module: DTUSecure WiFi auto-connect
#
# Creates a NetworkManager WPA2-Enterprise (PEAP/MSCHAPv2) profile for
# DTUSecure with stored domain credentials so the machine connects
# automatically when DTUSecure is in range and no Ethernet is available.
#
# Env: DTU_USERNAME, DTU_PASSWORD
#      DTU_WIFI_USER  optional; the account the profile is FOR. The first-login
#                     script sets it to the logged-in domain user, so the
#                     machine's Wi-Fi ends up in that user's name and not in
#                     the name of whoever typed something into a dialog.
#
# Hvorfor profilen skrives som fil og ikke med 'nmcli connection add':
# nmcli tager kodeordet som et argument, og argumenter kan enhver lokal
# bruger laese i 'ps' saa laenge kommandoen koerer. En keyfile skrevet med
# printf (et bash-builtin, ingen ny proces) og umask 077 naar aldrig
# proceslisten.
#
# Hvorfor den gamle profil foerst slettes til sidst: faar vi ikke den nye paa
# plads, skal maskinen beholde den WiFi den har. Og der slettes ALLE profiler
# for SSID'et, ikke kun én med et bestemt navn. En profil lagt ind i Plasmas
# netvaerksvindue af den admin der satte maskinen op, hedder ikke
# noedvendigvis det samme, og overlevede ellers med admins kodeord.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NM_DIR="${DTU_NM_DIR:-/etc/NetworkManager/system-connections}"

# keyfile_escape VALUE
# GKeyFile-escaping af en strengvaerdi, som NetworkManager selv laeser den:
# backslash, linjeskift, tab og CR skal skrives som \\ \n \t \r, og et
# foerende mellemrum som \s, ellers forsvinder det. Uden det ville et
# kodeord med en backslash blive gemt forkert, og WiFi'en ville afvise det
# uden nogen synlig grund.
keyfile_escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//$'\n'/\\n}"
  v="${v//$'\t'/\\t}"
  v="${v//$'\r'/\\r}"
  if [[ "$v" == " "* ]]; then v="\\s${v:1}"; fi
  printf '%s' "$v"
}

# write_wifi_keyfile FILE UUID SSID IDENTITY PASSWORD [DOMAIN_SUFFIX_MATCH]
# Skriver profilen med umask 077, altsaa 0600 fra foerste byte. Kun builtins:
# kodeordet optraeder aldrig som argument til en ny proces.
write_wifi_keyfile() {
  local file="$1" uuid="$2" ssid="$3" identity="$4" password="$5" match="${6:-}"
  (
    umask 077
    {
      printf '[connection]\n'
      printf 'id=%s\n' "$(keyfile_escape "$ssid")"
      printf 'uuid=%s\n' "$uuid"
      printf 'type=wifi\n'
      printf 'autoconnect=true\n'
      printf 'autoconnect-priority=10\n'
      printf 'permissions=\n'
      printf '\n[wifi]\n'
      printf 'mode=infrastructure\n'
      printf 'ssid=%s\n' "$(keyfile_escape "$ssid")"
      printf '\n[wifi-security]\n'
      printf 'key-mgmt=wpa-eap\n'
      printf '\n[802-1x]\n'
      printf 'eap=peap;\n'
      printf 'phase2-auth=mschapv2\n'
      printf 'identity=%s\n' "$(keyfile_escape "$identity")"
      printf 'password=%s\n' "$(keyfile_escape "$password")"
      if [[ -n "$match" ]]; then
        printf 'ca-cert=/etc/ssl/certs/ca-certificates.crt\n'
        printf 'domain-suffix-match=%s\n' "$(keyfile_escape "$match")"
      fi
      printf '\n[ipv4]\nmethod=auto\n'
      printf '\n[ipv6]\naddr-gen-mode=default\nmethod=auto\n'
    } > "$file"
  )
}

# Tests source this file for the functions above and stop here.
if [[ -n "${DTU_WIFI_SOURCE_ONLY:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

need_root

banner "DTUSecure WiFi – WPA2-Enterprise auto-connect"

if [[ -z "${DTU_USERNAME:-}" || -z "${DTU_PASSWORD:-}" ]]; then
  fail "DTU_USERNAME and DTU_PASSWORD must be set."
  exit 1
fi

SSID="${SITE_WIFI_SSID}"
WIFI_USER="${DTU_WIFI_USER:-$DTU_USERNAME}"
WIFI_USER="${WIFI_USER%%@*}"
IDENTITY="${WIFI_USER}${SITE_WIFI_IDENTITY_SUFFIX}"
MATCH="${SITE_WIFI_DOMAIN_SUFFIX_MATCH:-}"

echo "[1/5] Installing NetworkManager WPA-supplicant support..."
apt_wait
apt-get install -y network-manager wpasupplicant >/dev/null

echo "[2/5] Finding existing ${SSID} profiles..."
# Alle wifi-profiler hvis SSID er vores, uanset hvad de hedder og hvem der
# lavede dem. Sammenlignet uden hensyn til store og smaa bogstaver, for
# "DTUsecure" tastet ind i Plasma er det samme net.
mapfile -t OLD_UUIDS < <(
  nmcli -t -f UUID,TYPE connection show 2>/dev/null \
    | awk -F: '$2 == "802-11-wireless" { print $1 }' \
    | while read -r u; do
        s="$(nmcli -g 802-11-wireless.ssid connection show uuid "$u" 2>/dev/null || true)"
        if [[ "${s,,}" == "${SSID,,}" ]]; then printf '%s\n' "$u"; fi
      done
)
for u in "${OLD_UUIDS[@]}"; do
  printf '    found %s (identity: %s)\n' \
    "$(nmcli -g connection.id connection show uuid "$u" 2>/dev/null)" \
    "$(nmcli -g 802-1x.identity connection show uuid "$u" 2>/dev/null)"
done
if (( ${#OLD_UUIDS[@]} == 0 )); then echo "    none"; fi

echo "[3/5] Writing the new profile for ${IDENTITY}..."
NEW_UUID="$(cat /proc/sys/kernel/random/uuid)"
NEW_FILE="${NM_DIR}/${SSID}-${NEW_UUID}.nmconnection"
install -d -m 0700 "$NM_DIR"
write_wifi_keyfile "$NEW_FILE" "$NEW_UUID" "$SSID" "$IDENTITY" "$DTU_PASSWORD" "$MATCH"
chown root:root "$NEW_FILE"
chmod 0600 "$NEW_FILE"

# Er den ikke indlaest og ikke den vi skrev, beholdes den gamle, og den nye
# fjernes igen. Maskinen maa ikke staa uden WiFi fordi dette trin fejlede.
if ! nmcli connection load "$NEW_FILE" >/dev/null 2>&1 \
   || [[ "$(nmcli -g 802-1x.identity connection show uuid "$NEW_UUID" 2>/dev/null)" != "$IDENTITY" ]]; then
  rm -f "$NEW_FILE"
  nmcli connection reload >/dev/null 2>&1 || true
  die "NetworkManager did not accept the new profile. The existing Wi-Fi setup was left as it was."
fi
if [[ "$(stat -c '%U:%G %a' "$NEW_FILE")" != "root:root 600" ]]; then
  die "${NEW_FILE} is not root:root 600."
fi
ok "new profile loaded (${NEW_UUID})"

echo "[4/5] Removing the previous ${SSID} profiles..."
# Foerst nu, hvor den nye er paa plads.
for u in "${OLD_UUIDS[@]}"; do
  if [[ "$u" != "$NEW_UUID" ]]; then
    nmcli connection delete uuid "$u" >/dev/null && echo "    removed ${u}"
  fi
done

echo "[5/5] Verifying..."
REMAINING=0
while IFS=: read -r u t; do
  if [[ "$t" == "802-11-wireless" ]]; then
    s="$(nmcli -g 802-11-wireless.ssid connection show uuid "$u" 2>/dev/null || true)"
    if [[ "${s,,}" == "${SSID,,}" ]]; then REMAINING=$((REMAINING + 1)); fi
  fi
done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null)
if (( REMAINING != 1 )); then
  die "Expected exactly one ${SSID} profile afterwards, found ${REMAINING}."
fi

# Wired connections have default priority 0 (higher = more preferred in NM,
# but wired is always preferred when the cable is present because NM
# deactivates lower-priority connections when a higher-priority one activates).
# Priority 10 ensures DTUSecure connects automatically among WiFi networks,
# but a connected Ethernet will always win.

ok "DTUSecure WiFi configured."
echo "    SSID     : $SSID"
echo "    Identity : $IDENTITY"
echo "    Auth     : PEAP / MSCHAPv2"
echo "    Auto-connect: yes (priority 10 — Ethernet always wins)"
if [[ -n "$MATCH" ]]; then
  echo "    Server   : certificate checked, must end in ${MATCH}"
else
  warn "The RADIUS server's certificate is NOT checked (SITE_WIFI_DOMAIN_SUFFIX_MATCH is empty)."
  warn "A fake '${SSID}' access point could capture the password hash."
  warn "Set SITE_WIFI_DOMAIN_SUFFIX_MATCH in /etc/dtu-setup/site.conf to the server's domain."
fi
