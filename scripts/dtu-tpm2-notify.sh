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

TITLE="The disk's automatic unlock"
TEXT="Your machine asked for the disk passphrase at boot.

There is nothing wrong with the disk or with your passphrase. The machine's
firmware has been updated, and the lock that normally opens the disk
automatically was set up against the old firmware.

It needs to be set up once more. After that the machine stops asking.

Open DTU Linux Setup and press 'TPM2 Re-bind'. You will need your disk
passphrase once along the way."

# Vent til skrivebordet er der. Autostart kører tidligt, og en besked der
# kommer før panelet er tegnet, forsvinder uset.
sleep 20

vist=0
if command -v kdialog >/dev/null 2>&1; then
    kdialog --title "$TITLE" --msgbox "$TEXT" && vist=1
elif command -v zenity >/dev/null 2>&1; then
    zenity --info --title="$TITLE" --text="$TEXT" --width=480 && vist=1
elif command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical -t 0 "$TITLE" \
        "The machine asked for the disk passphrase because the firmware was updated. Open DTU Linux Setup and press 'TPM2 Re-bind'." \
        && vist=1
fi

if (( vist )); then
    install -d -m 0700 "$(dirname "$SEEN_FILE")"
    printf '%s' "$STATE_STAMP" > "$SEEN_FILE"
fi
