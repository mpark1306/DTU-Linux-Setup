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

die() {
  err "$*"
  exit 1
}

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
    info "$question — ingen terminal, vælger JA (sæt $envvar=0 for at undlade)."
    return 0
  fi
  info "$question — ingen terminal, vælger NEJ (sæt $envvar=1 for at gøre det)."
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

detect_luks_device() {
  if [[ -n "$DEVICE_ARG" ]]; then
    [[ -b "$DEVICE_ARG" ]] || die "'$DEVICE_ARG' does not exist or is not a block device."
    echo "$DEVICE_ARG"
    return
  fi

  local candidates
  mapfile -t candidates < <(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print "/dev/"$1}')

  if [[ ${#candidates[@]} -eq 0 ]]; then
    die "No LUKS partitions found. Pass a device explicitly: sudo $0 /dev/sdXN"
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
      die "Flere LUKS-partitioner fundet, og der er ingen terminal at spørge i.
       Angiv enheden eksplicit:
         DTU_LUKS_DEVICE=${candidates[0]} (fra GUI'en: sæt den i env-filen)
         sudo $0 ${candidates[0]}         (fra terminal)"
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
    ask_yes_no "Tilføj endnu en binding alligevel?" n DTU_TPM2_REBIND \
      || { info "Springer ekstra binding over — disken er allerede bundet."; return; }
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
    warn "Fandt ingen tpm2-binding at teste på $dev."
    return 1
  fi

  info "Tester at TPM'en kan låse slot $slot op..."
  if clevis luks pass -d "$dev" -s "$slot" >/dev/null 2>&1; then
    ok "TPM2 unseal virker — disken låser op uden adgangskode ved næste boot."
    return 0
  fi

  err "TPM'en kunne IKKE låse slot $slot op."
  err ""
  err "Bindingen findes, men den kan ikke bruges. Ved boot vil du stadig blive"
  err "bedt om LUKS-adgangskoden. Den hyppigste årsag er at PCR ${PCR_IDS} ikke"
  err "har samme værdi nu som ved boot:"
  err ""
  err "  • Secure Boot er slået fra. PCR ${PCR_IDS} måler netop Secure Boot-"
  err "    tilstanden. Slå den til i BIOS/UEFI og kør modulet igen."
  err "  • BIOS eller Secure Boot-certifikater er opdateret efter bindingen."
  err "  • TPM'en er nulstillet eller ejet af noget andet."
  err ""
  err "Se docs/TPM2-LUKS-fejlfinding.md."
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
    emit_check distro ok "Understøttet distribution" \
      "apt-get fundet" ""
  else
    emit_check distro fail "Ikke-understøttet distribution" \
      "Dette modul bruger clevis via initramfs-tools og kræver apt." \
      "TPM2-oplåsning skal sættes op manuelt på denne distribution."
  fi

  # 2. TPM2-enhed
  if [[ -e /dev/tpmrm0 ]]; then
    emit_check tpm-device ok "TPM2-enhed til stede" "/dev/tpmrm0" ""
  elif [[ -e /dev/tpm0 ]]; then
    emit_check tpm-device warn "TPM2-enhed til stede uden resource manager" \
      "/dev/tpm0 findes, men /dev/tpmrm0 mangler." \
      "Normalt uskadeligt. Mangler tpm2-abrmd, kan clevis stadig bruge /dev/tpm0."
  else
    emit_check tpm-device fail "Ingen TPM2-enhed fundet" \
      "Hverken /dev/tpm0 eller /dev/tpmrm0 findes." \
      "Slå TPM, fTPM eller Intel PTT til i BIOS/UEFI. På AMD hedder den ofte fTPM, på Intel PTT."
  fi

  # 3. Svarer TPM'en
  if command -v tpm2_pcrread >/dev/null 2>&1; then
    if tpm2_pcrread "${PCR_BANK}:${PCR_IDS}" >/dev/null 2>&1; then
      emit_check tpm-responds ok "TPM svarer" "Kunne læse PCR ${PCR_IDS} i bank ${PCR_BANK}." ""
    else
      emit_check tpm-responds fail "TPM svarer ikke" \
        "Enheden findes, men PCR ${PCR_IDS} kunne ikke læses i bank ${PCR_BANK}." \
        "Tjek at TPM'en ikke er deaktiveret eller ejet af noget andet. Prøv: tpm2_pcrread ${PCR_BANK}:${PCR_IDS}"
    fi
  else
    emit_check tpm-responds unknown "TPM-respons ikke kontrolleret" \
      "tpm2-tools er ikke installeret endnu." \
      "Installeres automatisk når modulet køres."
  fi

  # 4. Secure Boot
  #
  # Binding sker mod PCR 7, som måler Secure Boot-tilstanden. Slås Secure Boot
  # til eller fra EFTER enrollment, ændrer PCR 7 sig og oplåsningen holder op
  # med at virke. Derfor er rækkefølgen vigtig, ikke bare tilstanden.
  if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
      emit_check secure-boot ok "Secure Boot er slået til" \
        "PCR ${PCR_IDS} måler Secure Boot-tilstanden." \
        "Slå den ikke fra bagefter — så ændrer PCR ${PCR_IDS} sig og oplåsningen stopper."
    else
      emit_check secure-boot warn "Secure Boot er slået fra" \
        "Binding mod PCR ${PCR_IDS} virker stadig, men beskytter mindre, og slår du Secure Boot til bagefter holder oplåsningen op med at virke." \
        "Slå Secure Boot til i BIOS/UEFI FØR du kører modulet. Gør du det bagefter, skal bindingen laves om."
    fi
  else
    emit_check secure-boot unknown "Secure Boot-tilstand ukendt" \
      "mokutil er ikke installeret." \
      "Installér mokutil, eller aflæs tilstanden i BIOS/UEFI."
  fi

  # 5. LUKS-partition
  local candidates
  mapfile -t candidates < <(lsblk -rno NAME,FSTYPE 2>/dev/null | awk '$2=="crypto_LUKS"{print "/dev/"$1}')
  if [[ -n "$DEVICE_ARG" ]]; then
    if [[ -b "$DEVICE_ARG" ]]; then
      dev="$DEVICE_ARG"
      emit_check luks-device ok "LUKS-enhed valgt" "$dev (angivet eksplicit)" ""
    else
      emit_check luks-device fail "Angivet enhed findes ikke" \
        "$DEVICE_ARG er ikke en blokenhed." \
        "Ret DTU_LUKS_DEVICE, eller lad den være tom så enheden findes automatisk."
    fi
  elif [[ ${#candidates[@]} -eq 1 ]]; then
    dev="${candidates[0]}"
    emit_check luks-device ok "LUKS-partition fundet" "$dev" ""
  elif [[ ${#candidates[@]} -eq 0 ]]; then
    emit_check luks-device fail "Ingen LUKS-partition fundet" \
      "Disken ser ikke ud til at være krypteret." \
      "TPM2-oplåsning kræver en LUKS-krypteret disk. Kryptering skal vælges ved installationen og kan ikke slås til bagefter."
  else
    emit_check luks-device warn "Flere LUKS-partitioner fundet" \
      "${candidates[*]}" \
      "Sæt DTU_LUKS_DEVICE til den rigtige, ellers kan modulet ikke vælge uden en terminal."
  fi

  # 6. Pakker
  local missing=()
  for pkg in clevis clevis-luks clevis-tpm2 clevis-initramfs cryptsetup tpm2-tools; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    emit_check packages ok "Nødvendige pakker installeret" "clevis, cryptsetup, tpm2-tools" ""
  else
    emit_check packages info "Pakker mangler endnu" \
      "Mangler: ${missing[*]}" \
      "Modulet installerer dem selv. Kræver netværk."
  fi

  # 7. Eksisterende binding — kræver root
  if ! have_root; then
    emit_check already-bound unknown "Eksisterende binding ikke kontrolleret" \
      "Kræver administratorrettigheder." ""
    emit_check initramfs unknown "initramfs ikke kontrolleret" \
      "Kræver administratorrettigheder." ""
    return 0
  fi

  if [[ -n "$dev" ]]; then
    if clevis luks list -d "$dev" 2>/dev/null | grep -q tpm2; then
      emit_check already-bound warn "Disken er allerede bundet til TPM2" \
        "$(clevis luks list -d "$dev" 2>/dev/null | tr '\n' ' ')" \
        "Kør kun modulet igen hvis bindingen skal laves om — fx efter en BIOS-opdatering."
    else
      emit_check already-bound ok "Ingen eksisterende TPM2-binding" "$dev er ikke bundet endnu." ""
    fi
  else
    emit_check already-bound unknown "Eksisterende binding ikke kontrolleret" \
      "Ingen entydig LUKS-enhed at kontrollere." ""
  fi

  # 8. clevis i initramfs
  local initrd
  initrd="/boot/initrd.img-$(uname -r)"
  if [[ ! -f "$initrd" ]]; then
    emit_check initramfs unknown "initramfs ikke fundet" "$initrd findes ikke." ""
  elif lsinitramfs "$initrd" 2>/dev/null | grep -q clevis; then
    emit_check initramfs ok "clevis er i initramfs" "$(basename "$initrd")" ""
  else
    emit_check initramfs info "clevis er ikke i initramfs endnu" \
      "Forventet før modulet har kørt." \
      "Modulet kører update-initramfs selv."
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
    ok "Done. Genstart og bekræft at der ikke kommer en adgangskode-prompt."
  else
    die "TPM2 auto-unlock er IKKE aktivt. Ret ovenstående og kør modulet igen."
  fi
}

main "$@"
