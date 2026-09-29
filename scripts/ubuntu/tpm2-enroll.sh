#!/usr/bin/env bash
#
# tpm2-clevis-luks-setup.sh
# =============================================================
# Configure TPM2 auto-unlock for a LUKS encrypted disk on
# Ubuntu/Kubuntu (and other Debian/Ubuntu-based distros with
# initramfs-tools).
#
# Why clevis and not systemd-cryptenroll + crypttab option?
# initramfs-tools (default on Ubuntu/Kubuntu) does not consume
# tpm2-device=auto in /etc/crypttab. Clevis ships an initramfs-tools
# hook and works independently of crypttab TPM options.
# =============================================================

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# Parathedskontrollen læser kun og skal kunne køres uden rettigheder, så
# brugeren kan se hvad der mangler uden først at taste en adgangskode. De
# punkter der faktisk kræver root rapporterer sig selv som "unknown".
if [[ "${1:-}" != "--check" && -z "${DTU_TPM2_CHECK_ONLY:-}" ]]; then
  need_root
fi

info() { echo "[i] $*"; }
err()  { fail "$*"; }

PCR_IDS="${PCR_IDS:-7}"
PCR_BANK="${PCR_BANK:-sha256}"
DEVICE_ARG="${1:-${DTU_LUKS_DEVICE:-}}"
EXISTING_PASSPHRASE_FILE=""

cleanup_secret_files() {
  if [[ -n "$EXISTING_PASSPHRASE_FILE" && -f "$EXISTING_PASSPHRASE_FILE" ]]; then
    shred -u "$EXISTING_PASSPHRASE_FILE" 2>/dev/null || rm -f "$EXISTING_PASSPHRASE_FILE"
    EXISTING_PASSPHRASE_FILE=""
  fi
}

# Yes/no der også virker uden terminal.
#
# Modulet startes fra GUI'en med "pkexec bash -s", hvor scriptet selv er stdin.
# Når det er læst står stdin på EOF, så "read" returnerer 1 med det samme — og
# med set -e afbryder det hele kørslen. Det var netop fejlen på linje 164.
#
# prompt_secret nedenfor havde allerede løst det for adgangskoden; de øvrige
# prompts fik bare aldrig samme behandling.
#
# ask_yes_no <spørgsmål> <default: y|n> <miljøvariabel>
ask_yes_no() {
  local question="$1" default="$2" envvar="$3"
  local override="${!envvar:-}"

  if [[ -n "$override" ]]; then
    case "$override" in
      1|y|Y|yes|YES|true)  return 0 ;;
      0|n|N|no|NO|false)   return 1 ;;
      *) die "$envvar='$override' — forventet 1/0, yes/no." ;;
    esac
  fi

  if [[ -t 0 ]]; then
    local ans
    read -rp "$question [$([[ $default == y ]] && echo 'Y/n' || echo 'y/N')] " ans
    if [[ -z "$ans" ]]; then
      [[ "$default" == y ]]
    else
      [[ "$ans" =~ ^[YyJj]$ ]]
    fi
    return
  fi

  # Ingen terminal: brug default og sig det højt, så valget står i modul-loggen.
  if [[ "$default" == y ]]; then
    info "$question  No terminal, choosing YES (set $envvar=0 to skip it)."
    return 0
  fi
  info "$question  No terminal, choosing NO (set $envvar=1 to do it)."
  return 1
}

prompt_secret() {
  local prompt="$1"
  local value=""

  if [[ -n "${DTU_LUKS_PASSPHRASE:-}" ]]; then
    value="$DTU_LUKS_PASSPHRASE"
  elif [[ -t 0 ]]; then
    read -rsp "$prompt: " value
    echo
  elif command -v zenity >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    value="$(zenity --password --title="TPM2 Auto-Unlock" --text="$prompt")" \
      || die "Passphrase prompt was cancelled."
  elif command -v systemd-ask-password >/dev/null 2>&1; then
    value="$(systemd-ask-password --timeout=0 "$prompt")" || die "Passphrase prompt failed."
  else
    die "No interactive passphrase prompt available. Run this script from a terminal."
  fi

  [[ -n "$value" ]] || die "Empty passphrase is not allowed."
  printf '%s' "$value"
}

ensure_existing_passphrase_file() {
  local dev="$1"
  if [[ -n "$EXISTING_PASSPHRASE_FILE" && -f "$EXISTING_PASSPHRASE_FILE" ]]; then
    return
  fi

  local passphrase
  passphrase="$(prompt_secret "Enter your existing LUKS passphrase")"

  EXISTING_PASSPHRASE_FILE="$(mktemp)"
  chmod 600 "$EXISTING_PASSPHRASE_FILE"
  printf '%s' "$passphrase" > "$EXISTING_PASSPHRASE_FILE"
  unset DTU_LUKS_PASSPHRASE
  unset passphrase

  if cryptsetup luksOpen --test-passphrase --key-file "$EXISTING_PASSPHRASE_FILE" "$dev" 2>/dev/null; then
    ok "Existing passphrase verified."
  else
    die "The provided passphrase could not unlock $dev."
  fi
}

trap 'err "Unexpected error on line $LINENO. See docs/TPM2-LUKS-fejlfinding.md."; exit 1' ERR
trap cleanup_secret_files EXIT

require_apt() {
  command -v apt-get >/dev/null 2>&1 \
    || die "This script requires apt-get (Ubuntu/Kubuntu/Debian)."
}

check_tpm2_presence() {
  if [[ ! -e /dev/tpmrm0 && ! -e /dev/tpm0 ]]; then
    die "No TPM2 device found (/dev/tpm0 or /dev/tpmrm0). Enable TPM/fTPM/PTT in BIOS first."
  fi
  ok "TPM2 device found."
}

check_secure_boot() {
  if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
      ok "Secure Boot appears enabled (recommended for PCR ${PCR_IDS})."
    else
      warn "Secure Boot does not appear enabled. PCR ${PCR_IDS} binding may fail at boot."
    fi
  else
    warn "mokutil not installed; cannot auto-check Secure Boot state."
  fi
}

# Finder LUKS-containere på maskinen.
#
# lsblk alene er ikke nok. FSTYPE-kolonnen kommer fra udev's ID_FS_TYPE, og
# kan udev ikke svare, falder lsblk tilbage til at probe rådisken selv — hvilket
# kræver læseadgang til /dev/nvme0n1p3 og den har en almindelig bruger ikke.
# Så er kolonnen tom for ALLE partitioner, og kontrollen melder "ingen
# LUKS-partition" på en maskine der tydeligvis beder om LUKS-adgangskoden ved
# boot. Parathedskontrollen kører netop uden rettigheder, så det rammer den.
#
# Derfor tre uafhængige kilder, forenet:
#
#   1) lsblk/udev        — den normale vej, når udev svarer
#   2) /sys/…/dm/uuid    — den åbne mapping siger CRYPT-LUKS1/2, og slaves/
#                          peger på selve containeren. Verdenslæsbar, ingen
#                          udev og ingen root involveret
#   3) /etc/crypttab     — hvad boot faktisk låser op. Mode 0644
#
# Kilde 2 er den vigtige: kører maskinen overhovedet fra en LUKS-disk, ER
# mappingen åben lige nu — ellers var vi ikke nået hertil.
# Stierne kan overskrives, så testene kan lægge et falsk sysfs-træ op uden
# root og uden en rigtig krypteret disk. I drift er de altid defaults.
SYSFS_BLOCK="${SYSFS_BLOCK:-/sys/class/block}"
CRYPTTAB_PATH="${CRYPTTAB_PATH:-/etc/crypttab}"

# Kilde 1 har ingen sti at pege et andet sted hen, og uden en sådan kunne
# testene ikke stille en maskine hvor lsblk intet ser: de lagde et falsk
# sysfs og crypttab op, mens værtens egen krypterede disk sev ind ad den
# tredje dør. Syv tests fejlede derfor på enhver maskine med LUKS — altså
# netop de maskiner værktøjet findes for — og bestod kun i CI.
#
# Sat, læses filen i stedet for at køre lsblk. Formatet er lsblk's eget:
# "NAVN FSTYPE" pr. linje.
#
# Bevidst en fixture med DATA og ikke en sti til en binær: scriptet kører
# som root på enroll-stien, og en miljøvariabel skal ikke kunne bestemme
# hvad der bliver eksekveret. Som root efterprøves hver kandidat desuden
# med `cryptsetup isLuks`, så en løgnagtig fixture bliver filtreret fra.
LSBLK_FIXTURE="${LSBLK_FIXTURE:-}"

# Én kilde, ét sted. Begge kaldesteder skal bruge den samme: noten nedenfor
# er dét brugeren får at se når intet blev fundet, og en note der siger
# noget andet end detektionen ville være værre end ingen note.
lsblk_fstypes() {
  if [[ -n "$LSBLK_FIXTURE" ]]; then
    cat "$LSBLK_FIXTURE" 2>/dev/null || true
  else
    lsblk -rno NAME,FSTYPE 2>/dev/null || true
  fi
}

luks_candidates() {
  local -a found=()
  local d dev uuid slave src real

  while IFS= read -r dev; do
    [[ -n "$dev" ]] && found+=("$dev")
  done < <(lsblk_fstypes | awk '$2=="crypto_LUKS"{print "/dev/"$1}')

  for d in "$SYSFS_BLOCK"/dm-*; do
    [[ -r "$d/dm/uuid" ]] || continue
    uuid="$(cat "$d/dm/uuid" 2>/dev/null || true)"
    [[ "$uuid" == CRYPT-LUKS* ]] || continue
    for slave in "$d"/slaves/*; do
      [[ -e "$slave" ]] || continue
      found+=("/dev/$(basename "$slave")")
    done
  done

  if [[ -r "$CRYPTTAB_PATH" ]]; then
    while read -r _ src key opts; do
      [[ -z "$src" ]] && continue
      # Krypteret swap med tilfældig nøgle er plain dm-crypt, ikke LUKS. Den
      # linje står i crypttab på helt almindelige Ubuntu-installationer, og
      # uden det her filter ville kontrollen melde "flere LUKS-partitioner" og
      # i værste fald lade modulet binde sig til swap-partitionen.
      [[ "$key" == /dev/urandom || "$key" == /dev/random ]] && continue
      [[ ",${opts}," == *,swap,* ]] && continue
      case "$src" in
        UUID=*)     src="/dev/disk/by-uuid/${src#UUID=}" ;;
        PARTUUID=*) src="/dev/disk/by-partuuid/${src#PARTUUID=}" ;;
        PARTLABEL=*) src="/dev/disk/by-partlabel/${src#PARTLABEL=}" ;;
        LABEL=*)    src="/dev/disk/by-label/${src#LABEL=}" ;;
      esac
      found+=("$src")
    done < <(grep -v '^[[:space:]]*\(#\|$\)' "$CRYPTTAB_PATH" 2>/dev/null || true)
  fi

  # Afdupliker på den opløste sti: samme disk hedder /dev/nvme0n1p3 fra én
  # kilde og /dev/disk/by-uuid/… fra en anden, og bliver ellers talt to gange
  # — hvorefter kontrollen beder brugeren vælge mellem den samme disk og sig
  # selv.
  local -A seen=()
  for dev in ${found[@]+"${found[@]}"}; do
    [[ -n "$dev" ]] || continue
    real="$(readlink -f "$dev" 2>/dev/null || true)"
    [[ -n "$real" && -b "$real" ]] || continue
    [[ -n "${seen[$real]:-}" ]] && continue
    seen[$real]=1
    # Har vi rettighederne, så spørg disken selv frem for at tro på kilden.
    # Uden root kan cryptsetup ikke læse headeren, og så tæller kandidaten med
    # på kildens ord — det er stadig bedre end at melde "ingen kryptering".
    if [[ $EUID -eq 0 ]] && command -v cryptsetup >/dev/null 2>&1; then
      cryptsetup isLuks "$real" 2>/dev/null || continue
    fi
    printf '%s\n' "$real"
  done
}

# Hvad kilderne hver især sagde. Bruges kun når vi INTET fandt: forskellen på
# "disken er ikke krypteret" og "vi kunne ikke se det" er hele forskellen på
# hvad brugeren skal gøre bagefter.
luks_sources_note() {
  local via_lsblk via_dm via_crypttab
  # Bemærk || true på hver: med "set -o pipefail" fælder en grep uden træffere
  # hele pipen, og så river ERR-trap'en kontrollen ned midt i en fejlbesked.
  via_lsblk="$(lsblk_fstypes | awk '$2=="crypto_LUKS"' | wc -l || true)"
  via_dm="$(grep -l '^CRYPT-LUKS' "$SYSFS_BLOCK"/dm-*/dm/uuid 2>/dev/null | wc -l || true)"
  via_crypttab="$(grep -c -v '^[[:space:]]*\(#\|$\)' "$CRYPTTAB_PATH" 2>/dev/null || true)"
  [[ -n "$via_lsblk" ]]    || via_lsblk=0
  [[ -n "$via_dm" ]]       || via_dm=0
  [[ -n "$via_crypttab" ]] || via_crypttab=0
  printf 'lsblk: %s, aabne dm-mappings: %s, crypttab-linjer: %s' \
    "$via_lsblk" "$via_dm" "$via_crypttab"
}

detect_luks_device() {
  if [[ -n "$DEVICE_ARG" ]]; then
    [[ -b "$DEVICE_ARG" ]] || die "'$DEVICE_ARG' does not exist or is not a block device."
    echo "$DEVICE_ARG"
    return
  fi

  local candidates
  mapfile -t candidates < <(luks_candidates)

  if [[ ${#candidates[@]} -eq 0 ]]; then
    die "No LUKS container found ($(luks_sources_note)).
       Name the device explicitly if you know which one it is:
         sudo $0 /dev/sdXN"
  elif [[ ${#candidates[@]} -eq 1 ]]; then
    echo "${candidates[0]}"
  else
    warn "Multiple LUKS partitions found:"
    local i=1
    for c in "${candidates[@]}"; do
      echo "  $i) $c"
      ((i++))
    done
    if [[ ! -t 0 ]]; then
      die "Several LUKS partitions found, and there is no terminal to ask in.
       Name the device explicitly:
         DTU_LUKS_DEVICE=${candidates[0]} (from the GUI: set it in the env file)
         sudo $0 ${candidates[0]}         (from a terminal)"
    fi
    local choice
    read -rp "Select number: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )) \
      || die "Invalid selection: $choice"
    echo "${candidates[$((choice-1))]}"
  fi
}

verify_luks() {
  cryptsetup isLuks "$1" 2>/dev/null || die "$1 is not a valid LUKS partition."
  ok "Verified LUKS device: $1"
}

install_packages() {
  info "Installing clevis and TPM2 tooling..."
  apt_wait
  apt-get update || die "apt-get update failed."
  apt-get install -y \
    clevis clevis-luks clevis-tpm2 clevis-initramfs \
    cryptsetup tpm2-tools initramfs-tools || die "Package installation failed."
  ok "Required packages installed."
}

already_bound() {
  clevis luks list -d "$1" 2>/dev/null | grep -q "tpm2"
}

bind_clevis() {
  local dev="$1"
  if already_bound "$dev"; then
    warn "$dev already has a TPM2 clevis binding:"
    clevis luks list -d "$dev" || true
    # Default nej: en ekstra identisk TPM2-binding gør ingen forskel og
    # bruger en LUKS-keyslot. Disken låser allerede op fra TPM'en.
    ask_yes_no "Add another binding anyway?" n DTU_TPM2_REBIND \
      || { info "Skipping the extra binding; the disk is already bound."; return; }
  fi

  info "Binding $dev to TPM2 (PCR ${PCR_IDS}, bank ${PCR_BANK})."
  ensure_existing_passphrase_file "$dev"
  clevis luks bind -k "$EXISTING_PASSPHRASE_FILE" -d "$dev" tpm2 "{\"pcr_bank\":\"${PCR_BANK}\",\"pcr_ids\":\"${PCR_IDS}\"}" \
    || die "Clevis binding failed."
  ok "TPM2 clevis binding created on $dev."
}

clean_crypttab_legacy_option() {
  if grep -q "tpm2-device" /etc/crypttab 2>/dev/null; then
    info "Removing unsupported tpm2-device=auto from /etc/crypttab..."
    cp /etc/crypttab "/etc/crypttab.bak.$(date +%s)"
    sed -i 's/[[:space:]]*tpm2-device=auto//g' /etc/crypttab
    ok "Cleaned /etc/crypttab (backup saved as /etc/crypttab.bak.*)."
  fi
}

rebuild_initramfs() {
  info "Rebuilding initramfs..."
  update-initramfs -u -k all || die "update-initramfs failed."
  ok "initramfs rebuilt."
}

verify_clevis_in_initramfs() {
  if lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -q "scripts/local-top/clevis"; then
    ok "Clevis initramfs hook verified."
  else
    warn "Could not verify clevis hook automatically. Check manually with:"
    warn "  lsinitramfs /boot/initrd.img-$(uname -r) | grep clevis"
  fi
}

verify_binding() {
  info "Current LUKS keyslot/token status for $1:"
  cryptsetup luksDump "$1" || true
}

# Kan TPM'en rent faktisk låse bindingen op?
#
# Det er forskellen på at bindingen FINDES og at den VIRKER. clevis luks bind
# forsegler mod PCR-værdierne som de er lige nu; om de samme værdier står der
# tidligt i boot, er et andet spørgsmål. Er de forskellige — typisk fordi
# Secure Boot er slået fra eller ændret, eller fordi firmwaren er opdateret —
# fejler unseal ved boot, initramfs falder tilbage til adgangskode-prompten,
# og intet i opsætningen har sagt fra. Scriptet sagde "Done. Reboot and verify"
# og lod maskinen om at opdage det.
#
# clevis luks pass henter passphrasen ud af slotten ved at unseale præcis som
# boot ville gøre. Lykkes den, virker bindingen. Output kasseres — det ER
# disknøglen, og den skal ikke stå i en terminal eller en log.
verify_can_unseal() {
  local dev="$1" slot
  slot="$(clevis luks list -d "$dev" 2>/dev/null | awk -F: '/tpm2/{gsub(/ /,"",$1); print $1; exit}')"

  if [[ -z "$slot" ]]; then
    warn "No tpm2 binding found to test on $dev."
    return 1
  fi

  info "Testing that the TPM can unlock slot $slot..."
  if clevis luks pass -d "$dev" -s "$slot" >/dev/null 2>&1; then
    ok "TPM2 unseal works. The disk will unlock without a passphrase at the next boot."
    return 0
  fi

  err "The TPM could NOT unlock slot $slot."
  err ""
  err "The binding exists, but it cannot be used. At boot you will still be"
  err "asked for the LUKS passphrase. The usual cause is that PCR ${PCR_IDS}"
  err "does not hold the same value now as it did at boot:"
  err ""
  err "  • Secure Boot is turned off. PCR ${PCR_IDS} measures exactly that"
  err "    state. Turn it on in BIOS/UEFI and run the module again."
  err "  • The BIOS or the Secure Boot certificates were updated after binding."
  err "  • The TPM was cleared, or is owned by something else."
  err ""
  err "See docs/TPM2-LUKS-fejlfinding.md."
  return 1
}

# ── Parathedskontrol ────────────────────────────────────────────────────────
#
# Kører kun læsninger og ændrer intet. Udskriver én linje pr. punkt i formatet
#
#   TPM2CHECK|<id>|<status>|<overskrift>|<detalje>|<afhjælpning>
#
# hvor status er ok, warn, fail eller unknown. GUI'en parser det og viser en
# liste; køres scriptet i en terminal er linjerne stadig læsbare.
#
# Grunden til at det er en tilstand i selve scriptet og ikke separat kode i
# GUI'en: så er der ét sted der ved hvad TPM2-oplåsning kræver. To lister ville
# drive fra hinanden, og den i GUI'en ville være den forkerte.
#
# Punkter markeret "unknown" kræver root. Uden root udskrives de som unknown i
# stedet for at blive udeladt, så GUI'en kan tilbyde at køre resten med
# rettigheder frem for at lade som om alt er kontrolleret.

emit_check() {
  # id | status | overskrift | detalje | afhjælpning
  printf 'TPM2CHECK|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "${4//|/ }" "${5//|/ }"
}

have_root() { [[ $EUID -eq 0 ]]; }

run_checks() {
  local dev=""

  # 1. Distro
  if command -v apt-get >/dev/null 2>&1; then
    emit_check distro ok "Supported distribution" \
      "apt-get fundet" ""
  else
    emit_check distro fail "Unsupported distribution" \
      "This module uses clevis through initramfs-tools and needs apt." \
      "TPM2 unlocking has to be set up by hand on this distribution."
  fi

  # 2. TPM2-enhed
  if [[ -e /dev/tpmrm0 ]]; then
    emit_check tpm-device ok "TPM2 device present" "/dev/tpmrm0" ""
  elif [[ -e /dev/tpm0 ]]; then
    emit_check tpm-device warn "TPM2 device present, without a resource manager" \
      "/dev/tpm0 exists, but /dev/tpmrm0 is missing." \
      "Usually harmless. Without tpm2-abrmd, clevis can still use /dev/tpm0."
  else
    emit_check tpm-device fail "No TPM2 device found" \
      "Neither /dev/tpm0 nor /dev/tpmrm0 exists." \
      "Enable TPM, fTPM or Intel PTT in BIOS/UEFI. On AMD it is usually called fTPM, on Intel PTT."
  fi

  # 3. Svarer TPM'en
  if command -v tpm2_pcrread >/dev/null 2>&1; then
    if tpm2_pcrread "${PCR_BANK}:${PCR_IDS}" >/dev/null 2>&1; then
      emit_check tpm-responds ok "The TPM responds" "PCR ${PCR_IDS} could be read in bank ${PCR_BANK}." ""
    else
      emit_check tpm-responds fail "The TPM does not respond" \
        "The device exists, but PCR ${PCR_IDS} could not be read in bank ${PCR_BANK}." \
        "Check that the TPM is not disabled or owned by something else. Try: tpm2_pcrread ${PCR_BANK}:${PCR_IDS}"
    fi
  else
    emit_check tpm-responds unknown "TPM response not checked" \
      "tpm2-tools is not installed yet." \
      "It is installed automatically when the module runs."
  fi

  # 4. Secure Boot
  #
  # Binding sker mod PCR 7, som måler Secure Boot-tilstanden. Slås Secure Boot
  # til eller fra EFTER enrollment, ændrer PCR 7 sig og oplåsningen holder op
  # med at virke. Derfor er rækkefølgen vigtig, ikke bare tilstanden.
  if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
      emit_check secure-boot ok "Secure Boot is enabled" \
        "PCR ${PCR_IDS} measures the Secure Boot state." \
        "Do not turn it off afterwards: PCR ${PCR_IDS} would change and the unlocking would stop."
    else
      emit_check secure-boot warn "Secure Boot is turned off" \
        "Binding against PCR ${PCR_IDS} still works, but protects less, and if you enable Secure Boot afterwards the unlocking stops working." \
        "Turn Secure Boot on in BIOS/UEFI BEFORE running the module. Doing it afterwards means the binding has to be redone."
    fi
  else
    emit_check secure-boot unknown "Secure Boot-tilstand ukendt" \
      "mokutil is not installed." \
      "Install mokutil, or read the state in BIOS/UEFI."
  fi

  # 5. LUKS-partition
  local candidates
  mapfile -t candidates < <(luks_candidates)
  if [[ -n "$DEVICE_ARG" ]]; then
    if [[ -b "$DEVICE_ARG" ]]; then
      dev="$DEVICE_ARG"
      emit_check luks-device ok "LUKS-enhed valgt" "$dev (angivet eksplicit)" ""
    else
      emit_check luks-device fail "The named device does not exist" \
        "$DEVICE_ARG is not a block device." \
        "Correct DTU_LUKS_DEVICE, or leave it empty so the device is found automatically."
    fi
  elif [[ ${#candidates[@]} -eq 1 ]]; then
    dev="${candidates[0]}"
    emit_check luks-device ok "LUKS-partition fundet" "$dev" ""
  elif [[ ${#candidates[@]} -eq 0 ]]; then
    emit_check luks-device fail "No LUKS partition found" \
      "None of the sources saw an encrypted container ($(luks_sources_note))." \
      "If the machine asks for a passphrase at boot then it IS encrypted, and it is this check that is blind: run 'lsblk -f' and 'cat /etc/crypttab' in a terminal and point DTU_LUKS_DEVICE at the right device. Otherwise TPM2 unlocking needs a LUKS-encrypted disk, and encryption has to be chosen during installation."
  else
    emit_check luks-device warn "Flere LUKS-partitioner fundet" \
      "${candidates[*]}" \
      "Point DTU_LUKS_DEVICE at the right one, otherwise the module cannot choose without a terminal."
  fi

  # 6. Pakker
  local missing=()
  for pkg in clevis clevis-luks clevis-tpm2 clevis-initramfs cryptsetup tpm2-tools; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    emit_check packages ok "The required packages are installed" "clevis, cryptsetup, tpm2-tools" ""
  else
    emit_check packages info "Packages are still missing" \
      "Missing: ${missing[*]}" \
      "The module installs them itself. It needs network access."
  fi

  # 7. Eksisterende binding — kræver root
  if ! have_root; then
    emit_check already-bound unknown "Existing binding not checked" \
      "Needs administrator rights." ""
    emit_check initramfs unknown "initramfs not checked" \
      "Needs administrator rights." ""
    return 0
  fi

  if [[ -n "$dev" ]]; then
    if clevis luks list -d "$dev" 2>/dev/null | grep -q tpm2; then
      emit_check already-bound warn "The disk is already bound to TPM2" \
        "$(clevis luks list -d "$dev" 2>/dev/null | tr '\n' ' ')" \
        "Only run the module again if the binding has to be redone, for instance after a BIOS update."
    else
      emit_check already-bound ok "No existing TPM2 binding" "$dev is not bound yet." ""
    fi
  else
    emit_check already-bound unknown "Existing binding not checked" \
      "No single LUKS device to check." ""
  fi

  # 8. clevis i initramfs
  local initrd
  initrd="/boot/initrd.img-$(uname -r)"
  if [[ ! -f "$initrd" ]]; then
    emit_check initramfs unknown "initramfs not found" "$initrd does not exist." ""
  elif lsinitramfs "$initrd" 2>/dev/null | grep -q clevis; then
    emit_check initramfs ok "clevis er i initramfs" "$(basename "$initrd")" ""
  else
    emit_check initramfs info "clevis is not in the initramfs yet" \
      "Expected before the module has run." \
      "The module runs update-initramfs itself."
  fi
}

# --check / DTU_TPM2_CHECK_ONLY=1: kontrollér og afslut uden at ændre noget.
if [[ "${1:-}" == "--check" || -n "${DTU_TPM2_CHECK_ONLY:-}" ]]; then
  [[ "${1:-}" == "--check" ]] && DEVICE_ARG="${2:-${DTU_LUKS_DEVICE:-}}"
  run_checks
  exit 0
fi

main() {
  banner "TPM2 LUKS Auto-Unlock (clevis)"
  require_apt
  check_tpm2_presence
  check_secure_boot
  info "Starting TPM2 + clevis LUKS auto-unlock setup."

  local device
  device="$(detect_luks_device)"
  info "Using device: $device"

  verify_luks "$device"
  install_packages
  bind_clevis "$device"
  clean_crypttab_legacy_option
  rebuild_initramfs
  verify_clevis_in_initramfs
  verify_binding "$device"

  echo
  # Sluttilstanden afgøres af om unseal virker, ikke af om vi nåede hertil.
  # En grøn besked oven på en binding der ikke kan låse op, er værre end
  # ingen besked: så tror den der satte maskinen op at den er færdig.
  if verify_can_unseal "$device"; then
    ok "Done. Reboot and confirm that no passphrase prompt appears."
  else
    die "TPM2 auto-unlock is NOT active. Fix the above and run the module again."
  fi
}

main "$@"

# Overvaagningen installeres her, ikke som et separat modul. Den der binder
# disken til TPM'en, er ogsaa den der skal sikre at nogen opdager naar
# bindingen holder op med at virke.
if [[ -x "${SCRIPT_DIR}/../setup-tpm2-watch.sh" ]]; then
    "${SCRIPT_DIR}/../setup-tpm2-watch.sh" || warn "Could not install the monitoring of the binding."
fi
