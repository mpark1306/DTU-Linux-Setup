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
need_root

info() { echo "[i] $*"; }
err()  { fail "$*"; }

PCR_IDS="${PCR_IDS:-7}"
PCR_BANK="${PCR_BANK:-sha256}"
DEVICE_ARG="${1:-}"
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

prompt_secret() {
  local prompt="$1"
  local value=""

  if [[ -t 0 ]]; then
    read -rsp "$prompt: " value
    echo
  elif command -v zenity >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    value="$(zenity --password --title="TPM2 Auto-Unlock" --text="$prompt")" \
      || die "Passphrase prompt was cancelled."
  elif command -v systemd-ask-password >/dev/null 2>&1; then
    value="$(systemd-ask-password "$prompt")" || die "Passphrase prompt failed."
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
    read -rp "Add another binding anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "Skipping additional binding."; return; }
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

generate_recovery_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

format_recovery_key() {
  fold -w8 <<< "$1" | paste -sd'-'
}

offer_recovery_key() {
  local dev="$1"
  read -rp "Generate a recovery key and export it to a local txt file? [Y/n] " ans
  if [[ "$ans" =~ ^[Nn]$ ]]; then
    info "Skipping recovery-key generation."
    return
  fi

  local raw formatted keyfile outfile
  raw="$(generate_recovery_hex)"
  formatted="$(format_recovery_key "$raw")"

  keyfile="$(mktemp)"
  printf '%s' "$formatted" > "$keyfile"
  chmod 600 "$keyfile"

  info "Adding recovery key as a new LUKS keyslot."
  ensure_existing_passphrase_file "$dev"
  if ! cryptsetup luksAddKey --key-file "$EXISTING_PASSPHRASE_FILE" "$dev" "$keyfile"; then
    shred -u "$keyfile" 2>/dev/null || rm -f "$keyfile"
    die "Could not add recovery key to $dev."
  fi

  if cryptsetup luksOpen --test-passphrase --key-file "$keyfile" "$dev" 2>/dev/null; then
    ok "Recovery key verified successfully."
  else
    warn "Automatic recovery key verification failed; inspect keyslots manually."
  fi
  shred -u "$keyfile" 2>/dev/null || rm -f "$keyfile"

  outfile="./LUKS-recovery-key-$(hostname)-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "LUKS recovery key"
    echo "Host:      $(hostname)"
    echo "Device:    $dev"
    echo "Generated: $(date -Iseconds)"
    echo
    echo "$formatted"
    echo
    echo "This key (including dashes) can be entered at boot unlock prompt."
  } > "$outfile"
  chmod 600 "$outfile"

  echo
  warn "RECOVERY KEY (shown once):"
  echo "  $formatted"
  echo
  warn "Saved to: $(readlink -f "$outfile")"
  warn "File contains an unencrypted disk key. Copy it to a secure location, then delete local copy: shred -u \"$outfile\""
}

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
  offer_recovery_key "$device"

  echo
  ok "Done. Reboot and verify auto-unlock."
  info "If auto-unlock does not work after reboot, enter your normal passphrase and see docs/TPM2-LUKS-fejlfinding.md."
}

main "$@"
