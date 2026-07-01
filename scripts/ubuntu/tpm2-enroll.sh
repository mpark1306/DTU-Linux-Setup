#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Ubuntu 24.04 – Module: TPM2 LUKS Auto-Unlock
#
# Enrolls the TPM2 chip as a LUKS keyslot so the encrypted disk unlocks
# automatically at boot — no passphrase prompt needed.
#
# Binding policy: PCR 7 (Secure Boot state).
# If BIOS/Secure Boot settings change, auto-unlock stops and the machine
# falls back to the existing passphrase — re-run this module afterwards.
#
# Prerequisites:
#   - LUKS2 encrypted disk (selected during Ubuntu installation)
#   - TPM2 chip present and accessible (/dev/tpm0 or /dev/tpmrm0)
#   - Secure Boot enabled in UEFI
#   - systemd >= 248 (standard on Ubuntu 22.04+)
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "TPM2 LUKS Auto-Unlock"

# ─── 1. Prerequisites ────────────────────────────────────────────────────────
echo "[1/6] Checking prerequisites..."

if ! command -v systemd-cryptenroll >/dev/null 2>&1; then
  fail "systemd-cryptenroll not found. Requires systemd >= 248 (Ubuntu 22.04+)."
  exit 1
fi

if ! command -v cryptsetup >/dev/null 2>&1; then
  apt-get install -y cryptsetup >/dev/null
fi

# ─── 2. Find LUKS partition ──────────────────────────────────────────────────
echo "[2/6] Detecting LUKS partition..."

LUKS_DEV=$(lsblk -rno NAME,FSTYPE | awk '$2 == "crypto_LUKS" {print "/dev/" $1}' | head -1)

if [[ -z "${LUKS_DEV:-}" ]]; then
  fail "No LUKS-encrypted partition found."
  echo "  Run: lsblk -f   to inspect your partition layout."
  echo "  The disk must be encrypted (LUKS2) — this is selected during Ubuntu installation."
  exit 1
fi

LUKS_UUID=$(blkid -s UUID -o value "$LUKS_DEV" 2>/dev/null)
ok "Found LUKS partition: $LUKS_DEV  (UUID: $LUKS_UUID)"

# ─── 3. Check TPM2 ──────────────────────────────────────────────────────────
echo "[3/6] Checking TPM2 device..."

TPM2_OUTPUT=$(systemd-cryptenroll --tpm2-device=list 2>&1 || true)
if ! echo "$TPM2_OUTPUT" | grep -q "PATH\|/dev/tpm"; then
  fail "No TPM2 device detected."
  echo "$TPM2_OUTPUT"
  echo "  Make sure TPM is enabled in UEFI/BIOS."
  exit 1
fi
ok "TPM2 device detected."

# ─── 4. Enroll TPM2 ─────────────────────────────────────────────────────────
echo "[4/6] Enrolling TPM2 keyslot (PCR 7 — Secure Boot state)..."
echo "  Enter your existing LUKS passphrase when prompted."
echo ""

systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-pcrs=7 \
  "$LUKS_DEV"

ok "TPM2 enrolled as LUKS keyslot."

# ─── 5. Update /etc/crypttab ─────────────────────────────────────────────────
echo "[5/6] Updating /etc/crypttab..."

if [[ -f /etc/crypttab ]]; then
  if grep -q "$LUKS_UUID" /etc/crypttab; then
    if grep "$LUKS_UUID" /etc/crypttab | grep -q "tpm2-device"; then
      ok "tpm2-device=auto already in /etc/crypttab — no change needed."
    else
      # Insert tpm2-device=auto into the options field (4th column)
      awk -v uuid="$LUKS_UUID" '
        $0 ~ uuid {
          if ($4 == "" || $4 == "none" || $4 == "-") {
            $4 = "luks,tpm2-device=auto"
          } else {
            $4 = $4 ",tpm2-device=auto"
          }
        }
        { print }
      ' /etc/crypttab > /tmp/crypttab.new
      mv /tmp/crypttab.new /etc/crypttab
      ok "Updated /etc/crypttab with tpm2-device=auto."
    fi
  else
    warn "UUID $LUKS_UUID not found in /etc/crypttab."
    echo "  Current /etc/crypttab:"
    cat /etc/crypttab
    echo ""
    echo "  Add tpm2-device=auto to the options column for your LUKS entry manually."
  fi

  echo "  /etc/crypttab after update:"
  cat /etc/crypttab
else
  warn "/etc/crypttab not found — skipping crypttab update."
fi

# ─── 5b. Rebuild initramfs ───────────────────────────────────────────────────
echo "  Rebuilding initramfs (this may take a minute)..."
update-initramfs -u -k all
ok "initramfs rebuilt."

# ─── 6. Recovery key ────────────────────────────────────────────────────────
echo "[6/6] Generating recovery key..."
echo ""
echo "  ┌──────────────────────────────────────────────────────────────────┐"
echo "  │  A recovery key will now be added as an extra LUKS keyslot.     │"
echo "  │  This is your fallback if TPM2 unlock fails (BIOS update,       │"
echo "  │  Secure Boot change, hardware replacement, TPM reset, etc.).    │"
echo "  │                                                                  │"
echo "  │  The key is shown ONCE — write it down or save it in your       │"
echo "  │  password manager (e.g. Vaultwarden) before closing this window.│"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""

systemd-cryptenroll --recovery-key "$LUKS_DEV"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
ok "TPM2 LUKS auto-unlock configured."
echo ""
echo "  LUKS device : $LUKS_DEV"
echo "  UUID        : $LUKS_UUID"
echo "  TPM binding : PCR 7 (Secure Boot state)"
echo ""
echo "  Active keyslots:"
cryptsetup luksDump "$LUKS_DEV" | grep -E "Keyslot|State|Type" || true
echo ""
echo "  ⚠  Keep your recovery key and install passphrase in a safe place."
echo "  ⚠  After BIOS/Secure Boot changes: re-run this module to re-enroll."
echo "  Reboot to verify automatic unlock."
