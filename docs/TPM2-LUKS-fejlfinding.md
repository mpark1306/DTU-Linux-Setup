# TPM2 LUKS Fejlfinding

Denne guide bruges sammen med TPM2 auto-unlock modulet (clevis) i DTU Linux Setup.

## Typiske problemer

### 1) Ingen TPM fundet

Symptom:
- Scriptet fejler med besked om manglende `/dev/tpm0` eller `/dev/tpmrm0`.

Løsning:
- Aktiver TPM/fTPM/PTT i BIOS.
- Gem BIOS-indstillinger og genstart.
- Bekraeft i Linux:
  ```bash
  ls -l /dev/tpm0 /dev/tpmrm0
  ```

### 2) Secure Boot er ikke enabled

Symptom:
- PCR 7 binding virker ustabilt eller unlock fejler ved boot.

Løsning:
- Slå Secure Boot til i BIOS.
- Kontroller i Linux:
  ```bash
  mokutil --sb-state
  ```

### 3) clevis hook ikke i initramfs

Symptom:
- LUKS bliver ikke auto-unlocked ved opstart.

Løsning:
- Genbyg initramfs:
  ```bash
  sudo update-initramfs -u -k all
  ```
- Verificer hook:
  ```bash
  sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep clevis
  ```

### 4) BIOS/TPM ændringer efter enrollment

Symptom:
- Auto-unlock virkede foer, men virker ikke laengere.

Aarsag:
- PCR maalinger aendres ofte efter BIOS opdatering, TPM reset, Secure Boot certifikat- eller policy-aendringer.

Løsning:
1. Boot med normal passphrase.
2. Koer TPM2 modulet igen for at re-binde clevis token.

### 5) Recovery-key mangler

Anbefaling:
- Generer altid recovery-key i modulet og opbevar den sikkert.
- Slet lokal, ukrypteret kopi efter sikker overfoersel:
  ```bash
  shred -u ./LUKS-recovery-key-*.txt
  ```

## Nyttige kommandoer

```bash
# Vis LUKS keyslots og tokens
sudo cryptsetup luksDump /dev/<din-partition>

# Vis clevis bindinger
sudo clevis luks list -d /dev/<din-partition>

# Test TPM respons
sudo tpm2_getcap properties-fixed
```

## Sikkerhedsbemaerkning

TPM2 auto-unlock er en trade-off mellem brugervenlighed og fysisk sikkerhed. Brug kun funktionen på maskiner hvor risikoaccept er afklaret.
