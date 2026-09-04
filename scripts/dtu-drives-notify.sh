#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – notificér den indloggede bruger om at drevene skal
# genopfriskes, med en knap der gør det.
#
# Kaldes af NetworkManager-dispatcheren (som root) når et netværksskift
# betyder at netværksdrevene peger på et mål der ikke længere kan nås.
#
# Hvorfor en notifikation og ikke bare en stille genmontering: en
# genmontering tager sekunder og kan fejle, og imens blokerer alt der rører
# /mnt. Sker det uden at nogen får det at vide, ligner det at maskinen er
# gået i stå. Beskeden fortæller hvad der skete, og knappen gør noget ved
# det når brugeren er klar.
#
#   dtu-drives-notify.sh <brugernavn>
###############################################################################
set -uo pipefail

TARGET_USER="${1:-}"
[[ -n "$TARGET_USER" ]] || exit 0
id "$TARGET_USER" >/dev/null 2>&1 || exit 0

UID_NUM="$(id -u "$TARGET_USER")"
BUS="unix:path=/run/user/${UID_NUM}/bus"
[[ -S "/run/user/${UID_NUM}/bus" ]] || exit 0   # ingen grafisk session

# --action medfører --wait: kommandoen bliver stående indtil brugeren
# trykker eller notifikationen lukkes. Derfor timeout omkring den — ellers
# ville dispatcheren efterlade en proces per netværksskift.
# Nogle skriveborde leverer notifikationer gennem XDG-portalen, som ikke
# understøtter knapper. Så vises beskeden uden knap — derfor står den
# manuelle vej også i teksten, og derfor findes menupunktet.
CHOICE="$(timeout 300 sudo -u "$TARGET_USER" \
    DBUS_SESSION_BUS_ADDRESS="$BUS" \
    notify-send \
        --app-name="DTU Linux Setup" \
        --icon=network-workgroup \
        --urgency=normal \
        --action="refresh=Genopfrisk drev" \
        "Netværket er skiftet" \
        "Dine netværksdrev peger på et mål der ikke kan nås herfra.

Tryk for at forbinde dem igen, eller åbn “Genopfrisk netværksdrev” i menuen." \
    2>/dev/null)"

[[ "$CHOICE" == "refresh" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if flock -n /var/lock/dtu-drives-reselect.lock \
        "${SCRIPT_DIR}/dtu-drives-reselect.sh" >> /var/log/dtu-drives-reselect.log 2>&1; then
    sudo -u "$TARGET_USER" DBUS_SESSION_BUS_ADDRESS="$BUS" \
        notify-send --app-name="DTU Linux Setup" --icon=dialog-ok \
        "Netværksdrev genopfrisket" "Drevene er forbundet igen." 2>/dev/null
else
    sudo -u "$TARGET_USER" DBUS_SESSION_BUS_ADDRESS="$BUS" \
        notify-send --app-name="DTU Linux Setup" --icon=dialog-error --urgency=critical \
        "Kunne ikke genopfriske drevene" \
        "Ingen af filserverne svarer på dette netværk. Prøv igen når du er på kabel, DTUSecure eller VPN." 2>/dev/null
fi
