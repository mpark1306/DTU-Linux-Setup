#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: Re-bind TPM2 after a firmware change
#
# The BitLocker behaviour, on Linux.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
#
# The disk key is sealed in the TPM behind a policy: release it only if PCR 7
# still holds this exact value. PCR 7 is a running hash over the Secure Boot
# state -- the SecureBoot variable, PK, KEK, db and dbx, and which db entry
# validated each binary that was loaded.
#
# A firmware update almost always ships a new dbx. That alone changes PCR 7,
# the TPM refuses to release the key, and initramfs falls back to asking for
# the passphrase. Nothing is broken and nothing is lost: LUKS is intact and
# the passphrase keyslot still works. The seal simply no longer matches.
#
# Windows handles this by re-sealing after you type the recovery key once.
# Until now we did not: the machine asked for the passphrase at every boot
# from then on, and nobody was told why.
#
# This script is the re-seal. Run it once after the firmware change and the
# machine goes back to unlocking by itself.
#
# ---------------------------------------------------------------------------
# WHAT IT REFUSES TO DO
#
# It will not re-bind while Secure Boot is off. PCR 7 measures exactly that,
# so sealing then would produce a binding that unlocks the disk on a machine
# with Secure Boot disabled -- which is the state an attacker would want. A
# broken binding is an inconvenience; that would be a downgrade.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "TPM2 – bind om efter firmwareændring"

PCR_IDS="${PCR_IDS:-7}"
PCR_BANK="${PCR_BANK:-sha256}"
STATE_DIR=/var/lib/dtu-setup
STATE_FILE="${STATE_DIR}/tpm2-binding-broken"

PASSPHRASE_FILE=""
cleanup() {
    if [[ -n "$PASSPHRASE_FILE" && -f "$PASSPHRASE_FILE" ]]; then
        shred -u "$PASSPHRASE_FILE" 2>/dev/null || rm -f "$PASSPHRASE_FILE"
    fi
}
trap cleanup EXIT

# ─── Which device holds the encrypted root ──────────────────────────────────
# /etc/crypttab is the authority: it is what boot actually unlocks. lsblk is
# only a fallback, because its FSTYPE comes from udev and is blank when udev
# cannot answer.
find_luks_devices() {
    local devs=()
    if [[ -r /etc/crypttab ]]; then
        while read -r _name source _rest; do
            [[ "$_name" == \#* || -z "$_name" ]] && continue
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

tpm2_slot() {
    clevis luks list -d "$1" 2>/dev/null \
        | awk -F: '/tpm2/{gsub(/ /,"",$1); print $1; exit}'
}

# Does the binding still unlock? This is the only test that counts.
#
# "clevis luks pass" unseals exactly the way boot does. Its output IS the disk
# key, so it goes to /dev/null and never to a terminal or a log.
binding_works() {
    local dev="$1" slot
    slot="$(tpm2_slot "$dev")"
    [[ -z "$slot" ]] && return 1
    clevis luks pass -d "$dev" -s "$slot" >/dev/null 2>&1
}

secure_boot_on() {
    command -v mokutil >/dev/null 2>&1 || return 2
    mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"
}

ask_passphrase() {
    local dev="$1" try passphrase
    for try in 1 2 3; do
        echo
        echo "    Indtast LUKS-adgangskoden for ${dev}."
        echo "    Det er den kode du fik udleveret, og den samme du lige har"
        echo "    tastet ved opstart. Den vises ikke mens du skriver."
        read -rsp "    Adgangskode: " passphrase
        echo
        [[ -z "$passphrase" ]] && { warn "Tom adgangskode."; continue; }

        PASSPHRASE_FILE="$(mktemp)"
        chmod 600 "$PASSPHRASE_FILE"
        printf '%s' "$passphrase" > "$PASSPHRASE_FILE"
        unset passphrase

        if cryptsetup luksOpen --test-passphrase --key-file "$PASSPHRASE_FILE" "$dev" 2>/dev/null; then
            ok "Adgangskoden er accepteret."
            return 0
        fi
        warn "Forkert adgangskode (forsøg ${try} af 3)."
        cleanup
    done
    return 1
}

# ─── 1. Precondition ────────────────────────────────────────────────────────
echo "[1/4] Kontrollerer forudsætninger..."
for verktoej in clevis cryptsetup; do
    command -v "$verktoej" >/dev/null 2>&1 \
        || die "'$verktoej' mangler. Kør TPM2 Auto-Unlock-modulet først."
done

# Status fanges eksplicit. "elif [[ $? -eq 2 ]]" ville virke, men afhaenger af
# at $? stadig er funktionens status naar elif'ens betingelse evalueres, og
# under "set -e" ville et kald uden || desuden afslutte scriptet.
SB_STATE=0
secure_boot_on || SB_STATE=$?
if (( SB_STATE == 0 )); then
    echo "    Secure Boot: slået til"
elif (( SB_STATE == 2 )); then
    warn "mokutil mangler, kan ikke afgøre Secure Boot-tilstanden. Fortsætter."
else
    die "Secure Boot er slået fra.

       PCR ${PCR_IDS} måler netop Secure Boot-tilstanden, så en binding lavet nu
       ville låse disken op på en maskine uden Secure Boot. Det er dårligere
       end at skulle taste koden.

       Slå Secure Boot til i firmwaren, og kør så scriptet igen."
fi

mapfile -t LUKS_DEVS < <(find_luks_devices)
(( ${#LUKS_DEVS[@]} > 0 )) || die "Fandt ingen LUKS-enheder."
echo "    LUKS-enheder: ${LUKS_DEVS[*]}"

# ─── 2. Which bindings are actually dead ────────────────────────────────────
echo "[2/4] Afprøver de eksisterende bindinger..."
BROKEN=()
for dev in "${LUKS_DEVS[@]}"; do
    slot="$(tpm2_slot "$dev")"
    if [[ -z "$slot" ]]; then
        echo "    ${dev}: ingen TPM2-binding. Brug TPM2 Auto-Unlock-modulet."
        continue
    fi
    if binding_works "$dev"; then
        echo "    ${dev}: bindingen virker, intet at gøre."
    else
        echo "    ${dev}: bindingen låser ikke op længere (slot ${slot})."
        BROKEN+=("$dev")
    fi
done

if (( ${#BROKEN[@]} == 0 )); then
    rm -f "$STATE_FILE"
    ok "Alle bindinger virker. Maskinen låser selv op ved næste opstart."
    exit 0
fi

# ─── 3. Re-bind ─────────────────────────────────────────────────────────────
echo "[3/4] Binder om mod de nuværende PCR-værdier..."
REBOUND=0
for dev in "${BROKEN[@]}"; do
    echo
    echo "  --- ${dev} ---"
    if ! ask_passphrase "$dev"; then
        warn "Springer ${dev} over: adgangskoden blev ikke accepteret."
        continue
    fi

    # Den døde binding fjernes FØR den nye laves. Ellers samler der sig en
    # ubrugelig keyslot for hver firmwareopdatering maskinen har set, og
    # LUKS2 har kun 32 af dem.
    old_slot="$(tpm2_slot "$dev")"
    if [[ -n "$old_slot" ]]; then
        echo "    Fjerner den døde binding i slot ${old_slot}..."
        clevis luks unbind -d "$dev" -s "$old_slot" -f \
            || warn "Kunne ikke fjerne slot ${old_slot}; fortsætter."
    fi

    echo "    Forsegler mod PCR ${PCR_IDS} (bank ${PCR_BANK})..."
    if clevis luks bind -k "$PASSPHRASE_FILE" -d "$dev" tpm2 \
         "{\"pcr_bank\":\"${PCR_BANK}\",\"pcr_ids\":\"${PCR_IDS}\"}"; then
        REBOUND=$((REBOUND + 1))
    else
        warn "Ombindingen af ${dev} fejlede."
    fi
    cleanup
done

# ─── 4. Prove it works, do not assume ───────────────────────────────────────
echo
echo "[4/4] Afprøver de nye bindinger..."
STILL_BROKEN=0
for dev in "${BROKEN[@]}"; do
    if binding_works "$dev"; then
        ok "${dev}: låser op fra TPM'en igen."
    else
        warn "${dev}: låser stadig ikke op."
        STILL_BROKEN=$((STILL_BROKEN + 1))
    fi
done

# initramfs indeholder clevis' hook, men ikke bindingen. Den læses fra
# LUKS-headeren ved boot, så der skal ikke bygges initramfs igen. Det er
# derfor dette script er hurtigt og ikke rører boot-kæden.

if (( STILL_BROKEN == 0 && REBOUND > 0 )); then
    rm -f "$STATE_FILE"
    echo
    ok "Færdig. ${REBOUND} binding(er) fornyet."
    echo "    Maskinen spørger ikke om koden ved næste opstart."
    echo "    Gem koden alligevel: den er den eneste vej ind hvis TPM'en"
    echo "    ryddes eller firmwaren udskiftes."
else
    echo
    die "Ombindingen lykkedes ikke. Disken kan stadig låses op med adgangskoden.
       Log fra sidste forsøg ligger i journalen:  journalctl -t dtu-tpm2"
fi

# Overvaagningen installeres her, ikke som et separat modul. Den der binder
# disken til TPM'en, er ogsaa den der skal sikre at nogen opdager naar
# bindingen holder op med at virke.
if [[ -x "${SCRIPT_DIR}/../setup-tpm2-watch.sh" ]]; then
    "${SCRIPT_DIR}/../setup-tpm2-watch.sh" || warn "Kunne ikke installere overvaagningen af bindingen."
fi
