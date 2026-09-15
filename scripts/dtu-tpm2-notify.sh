#!/usr/bin/env bash
###############################################################################
# Fortæller brugeren at disken ikke længere låser sig selv op.
#
# Køres i brugerens session via en autostart-post. Læser kun tilstandsfilen
# som dtu-tpm2-watch.sh har skrevet; den rører hverken TPM eller disk.
#
# Formuleringen er valgt med omhu. Brugeren har lige tastet sin kode ved
# opstart og tror måske noget er gået i stykker. Det er ikke tilfældet, og
# beskeden skal sige det først, ikke til sidst.
###############################################################################
set -uo pipefail

STATE_FILE=/var/lib/dtu-setup/tpm2-binding-broken
# Vises én gang per tilstandsfil. Uden det ville beskeden komme ved hvert
# login indtil nogen når at gøre noget, og så bliver den til støj man klikker
# væk uden at læse.
SEEN_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/dtu-tpm2-notified"

[[ -r "$STATE_FILE" ]] || exit 0

STATE_STAMP="$(stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)"
if [[ -r "$SEEN_FILE" ]] && [[ "$(cat "$SEEN_FILE" 2>/dev/null)" == "$STATE_STAMP" ]]; then
    exit 0
fi

TITEL="Diskens automatiske oplåsning"
TEKST="Din maskine bad om diskkoden ved opstart.

Der er ikke noget galt med disken eller med din kode. Maskinens firmware er
blevet opdateret, og den lås der plejer at åbne disken automatisk, blev sat
op mod den gamle firmware.

Den skal sættes op igen én gang. Så spørger maskinen ikke mere.

Åbn DTU Linux Setup og tryk på 'TPM2 – Bind om'. Du skal bruge din diskkode
én gang undervejs."

# Vent til skrivebordet er der. Autostart kører tidligt, og en besked der
# kommer før panelet er tegnet, forsvinder uset.
sleep 20

vist=0
if command -v kdialog >/dev/null 2>&1; then
    kdialog --title "$TITEL" --msgbox "$TEKST" && vist=1
elif command -v zenity >/dev/null 2>&1; then
    zenity --info --title="$TITEL" --text="$TEKST" --width=480 && vist=1
elif command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical -t 0 "$TITEL" \
        "Maskinen spurgte om diskkoden, fordi firmwaren er opdateret. Åbn DTU Linux Setup og tryk 'TPM2 – Bind om'." \
        && vist=1
fi

if (( vist )); then
    install -d -m 0700 "$(dirname "$SEEN_FILE")"
    printf '%s' "$STATE_STAMP" > "$SEEN_FILE"
fi
