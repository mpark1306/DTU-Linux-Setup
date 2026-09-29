#!/usr/bin/env bash
###############################################################################
# Opdager at TPM2-bindingen er holdt op med at virke.
#
# Køres som en systemd-service efter hver opstart. Den retter ingenting og
# spørger ikke om noget; den skriver kun en tilstandsfil som sessionen kan
# reagere på.
#
# ---------------------------------------------------------------------------
# HVORFOR DEN FINDES
#
# Uden den ser en brudt binding ud som ingenting. Maskinen booter, brugeren
# taster sin kode, alt virker, og ingen opdager at auto-oplåsningen er død.
# Den næste opstart spørger igen. Og den næste. Den tilstand kan stå i
# månedsvis, og den eneste der ved det er brugeren, som tror det er normalt.
#
# Windows har samme situation efter en firmwareopdatering, men fortæller om
# den. Det er det her script, plus notifikationen, gør.
#
# ---------------------------------------------------------------------------
# HVAD DEN IKKE GØR
#
# Den binder ikke om af sig selv. Ombinding kræver LUKS-adgangskoden, og den
# kode ligger ikke på maskinen. Skulle den det, ville hele opsætningen være
# meningsløs: en angriber med adgang til disken ville have både låsen og
# nøglen. Derfor skal et menneske taste den, og derfor er det her kun en
# detektor.
###############################################################################
set -uo pipefail
# Bevidst uden "set -e". En detektor der selv afslutter ved første uventede
# svar, er værre end ingen detektor: den fejler stille på præcis de maskiner
# der har et problem.

STATE_DIR=/var/lib/dtu-setup
STATE_FILE="${STATE_DIR}/tpm2-binding-broken"
TAG=dtu-tpm2

log() { logger -t "$TAG" -- "$*"; }

command -v clevis >/dev/null 2>&1 || {
    log "clevis is not installed; TPM2 is not in use on this machine."
    exit 0
}

install -d -m 0755 "$STATE_DIR"

find_luks_devices() {
    local devs=() name source rest
    if [[ -r /etc/crypttab ]]; then
        while read -r name source rest; do
            [[ "$name" == \#* || -z "$name" ]] && continue
            case "$source" in
                UUID=*) source="/dev/disk/by-uuid/${source#UUID=}" ;;
            esac
            [[ -b "$source" ]] && devs+=("$(readlink -f "$source")")
        done < /etc/crypttab
    fi
    if (( ${#devs[@]} == 0 )); then
        while read -r dev; do
            [[ -n "$dev" ]] && devs+=("$dev")
        done < <(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print "/dev/"$1}')
    fi
    printf '%s\n' "${devs[@]}"
}

BROKEN=()
BOUND=0
while read -r dev; do
    [[ -n "$dev" ]] || continue
    slot="$(clevis luks list -d "$dev" 2>/dev/null | awk -F: '/tpm2/{gsub(/ /,"",$1); print $1; exit}')"
    [[ -z "$slot" ]] && continue          # ingen binding: intet at overvåge
    BOUND=$((BOUND + 1))
    # Selve prøven. Output ER disknøglen og må aldrig nå en log.
    if ! clevis luks pass -d "$dev" -s "$slot" >/dev/null 2>&1; then
        BROKEN+=("$dev")
    fi
done < <(find_luks_devices)

if (( BOUND == 0 )); then
    rm -f "$STATE_FILE"
    log "No TPM2 bindings on this machine."
    exit 0
fi

if (( ${#BROKEN[@]} == 0 )); then
    rm -f "$STATE_FILE"
    log "The TPM2 binding works (${BOUND} device(s))."
    exit 0
fi

# Tilstandsfilen er det sessionen læser. Den er verdenslæsbar med vilje:
# den indeholder ingen hemmelighed, kun at der skal gøres noget.
{
    echo "# Written by dtu-tpm2-watch.sh $(date -Is)"
    echo "DEVICES=\"${BROKEN[*]}\""
} > "${STATE_FILE}.tmp"
chmod 0644 "${STATE_FILE}.tmp"
mv -f "${STATE_FILE}.tmp" "$STATE_FILE"

log "The TPM2 binding no longer unlocks: ${BROKEN[*]}"
log "Usual cause: a firmware update changed PCR 7, the Secure Boot state."
log "Fix it with the 'TPM2 Re-bind' module in DTU Linux Setup."
