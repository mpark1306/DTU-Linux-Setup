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

banner "TPM2 – re-bind after a firmware change"

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
        echo "    Enter the LUKS passphrase for ${dev}."
        echo "    It is the code you were given, the same one you typed at"
        echo "    boot just now. It is not shown while you type."
        read -rsp "    Passphrase: " passphrase
        echo
        [[ -z "$passphrase" ]] && { warn "Empty passphrase."; continue; }

        PASSPHRASE_FILE="$(mktemp)"
        chmod 600 "$PASSPHRASE_FILE"
        printf '%s' "$passphrase" > "$PASSPHRASE_FILE"
        unset passphrase

        if cryptsetup luksOpen --test-passphrase --key-file "$PASSPHRASE_FILE" "$dev" 2>/dev/null; then
            ok "The passphrase was accepted."
            return 0
        fi
        warn "Wrong passphrase (attempt ${try} of 3)."
        cleanup
    done
    return 1
}

# ─── 1. Precondition ────────────────────────────────────────────────────────
echo "[1/4] Checking the requirements..."
for verktoej in clevis cryptsetup; do
    command -v "$verktoej" >/dev/null 2>&1 \
        || die "'$verktoej' is missing. Run the TPM2 Auto-Unlock module first."
done

# Status fanges eksplicit. "elif [[ $? -eq 2 ]]" ville virke, men afhaenger af
# at $? stadig er funktionens status naar elif'ens betingelse evalueres, og
# under "set -e" ville et kald uden || desuden afslutte scriptet.
SB_STATE=0
secure_boot_on || SB_STATE=$?
if (( SB_STATE == 0 )); then
    echo "    Secure Boot: enabled"
elif (( SB_STATE == 2 )); then
    warn "mokutil is missing, so the Secure Boot state cannot be read. Continuing."
else
    die "Secure Boot is turned off.

       PCR ${PCR_IDS} measures exactly the Secure Boot state, so a binding made
       now would unlock the disk on a machine with Secure Boot disabled. That
       is worse than having to type the passphrase.

       Turn Secure Boot on in the firmware, then run this again."
fi

mapfile -t LUKS_DEVS < <(find_luks_devices)
(( ${#LUKS_DEVS[@]} > 0 )) || die "No LUKS devices found."
echo "    LUKS devices: ${LUKS_DEVS[*]}"

# ─── 2. Which bindings are actually dead ────────────────────────────────────
echo "[2/4] Testing the existing bindings..."
BROKEN=()
for dev in "${LUKS_DEVS[@]}"; do
    slot="$(tpm2_slot "$dev")"
    if [[ -z "$slot" ]]; then
        echo "    ${dev}: no TPM2 binding. Use the TPM2 Auto-Unlock module."
        continue
    fi
    if binding_works "$dev"; then
        echo "    ${dev}: the binding works, nothing to do."
    else
        echo "    ${dev}: the binding no longer unlocks (slot ${slot})."
        BROKEN+=("$dev")
    fi
done

if (( ${#BROKEN[@]} == 0 )); then
    rm -f "$STATE_FILE"
    ok "Every binding works. The machine will unlock itself at the next boot."
    exit 0
fi

# ─── 3. Re-bind ─────────────────────────────────────────────────────────────
echo "[3/4] Re-binding against the current PCR values..."
REBOUND=0
for dev in "${BROKEN[@]}"; do
    echo
    echo "  --- ${dev} ---"
    if ! ask_passphrase "$dev"; then
        warn "Skipping ${dev}: the passphrase was not accepted."
        continue
    fi

    # Den døde binding fjernes FØR den nye laves. Ellers samler der sig en
    # ubrugelig keyslot for hver firmwareopdatering maskinen har set, og
    # LUKS2 har kun 32 af dem.
    old_slot="$(tpm2_slot "$dev")"
    if [[ -n "$old_slot" ]]; then
        echo "    Removing the dead binding in slot ${old_slot}..."
        clevis luks unbind -d "$dev" -s "$old_slot" -f \
            || warn "Could not remove slot ${old_slot}; continuing."
    fi

    echo "    Sealing against PCR ${PCR_IDS} (bank ${PCR_BANK})..."
    if clevis luks bind -k "$PASSPHRASE_FILE" -d "$dev" tpm2 \
         "{\"pcr_bank\":\"${PCR_BANK}\",\"pcr_ids\":\"${PCR_IDS}\"}"; then
        REBOUND=$((REBOUND + 1))
    else
        warn "Re-binding ${dev} failed."
    fi
    cleanup
done

# ─── 4. Prove it works, do not assume ───────────────────────────────────────
echo
echo "[4/4] Testing the new bindings..."
STILL_BROKEN=0
for dev in "${BROKEN[@]}"; do
    if binding_works "$dev"; then
        ok "${dev}: unlocks from the TPM again."
    else
        warn "${dev}: still does not unlock."
        STILL_BROKEN=$((STILL_BROKEN + 1))
    fi
done

# initramfs indeholder clevis' hook, men ikke bindingen. Den læses fra
# LUKS-headeren ved boot, så der skal ikke bygges initramfs igen. Det er
# derfor dette script er hurtigt og ikke rører boot-kæden.

if (( STILL_BROKEN == 0 && REBOUND > 0 )); then
    rm -f "$STATE_FILE"
    echo
    ok "Done. ${REBOUND} binding(s) renewed."
    echo "    The machine will not ask for the passphrase at the next boot."
    echo "    Keep the passphrase anyway: it is the only way in if the TPM"
    echo "    is cleared or the firmware is replaced."
else
    echo
    die "The re-binding did not succeed. The disk can still be unlocked with
       the passphrase. The log from the last attempt is in the journal:
       journalctl -t dtu-tpm2"
fi

# Overvaagningen installeres her, ikke som et separat modul. Den der binder
# disken til TPM'en, er ogsaa den der skal sikre at nogen opdager naar
# bindingen holder op med at virke.
if [[ -x "${SCRIPT_DIR}/../setup-tpm2-watch.sh" ]]; then
    "${SCRIPT_DIR}/../setup-tpm2-watch.sh" || warn "Could not install the monitoring of the binding."
fi
