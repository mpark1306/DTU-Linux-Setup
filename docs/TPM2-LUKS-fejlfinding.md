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

### 5) Kan ikke laase op efter BIOS- eller Secure Boot-aendring

Modulet roerer ikke ved dine eksisterende noegler. Den adgangskode disken blev
krypteret med ved installationen virker uaendret, og den er din vej ind hvis
TPM2-oplaasningen holder op med at virke.

Sker det:
1. Indtast den normale adgangskode ved boot-prompten.
2. Koer modulet igen. Det binder mod den nye PCR-tilstand.

Modulet genererer **ikke** en recovery-noegle. Det ville tilfoeje en ny
LUKS-keyslot og skrive en ukrypteret disknoegle til en fil, og den eksisterende
adgangskode daekker allerede samme behov.

### 6) Ingen passphrase-prompt vises

Symptom:
- TPM2 modulet skriver at du skal indtaste eksisterende LUKS passphrase,
  men der kommer ingen prompt i GUI-korlen.

Aarsag:
- Modulet kan koere uden en interaktiv terminal (TTY), saa klassiske
  passphrase-prompts fra clevis/cryptsetup ikke vises.

Løsning:
- Opdater til nyeste version af TPM2 modulet, som bruger en fallback-prompt
  (zenity/systemd-ask-password) og sender passphrase sikkert via keyfile.
- Hvis prompt stadig ikke vises, koer modulet direkte fra terminal:
  ```bash
  sudo scripts/ubuntu/tpm2-enroll.sh
  ```

### 7) "Ingen LUKS-partition fundet" paa en disk der ER krypteret

Symptom: maskinen beder om LUKS-adgangskoden ved boot, men parathedskontrollen
melder at der ingen krypteret partition er.

Aarsag: parathedskontrollen koerer med vilje uden rettigheder, saa brugeren kan
se hvad der mangler uden foerst at taste en adgangskode. Detektionen laenede sig
paa `lsblk`'s FSTYPE-kolonne, og den kolonne kommer fra udev. Kan udev ikke
svare, prober `lsblk` selv raadisken — hvilket kraever laeseadgang til
`/dev/nvme0n1p3`, og den har en almindelig bruger ikke. Saa er kolonnen tom for
ALLE partitioner, og kontrollen konkluderer at disken ikke er krypteret.

Kontrollen bruger nu tre uafhaengige kilder og forener dem:

1. `lsblk`/udev — den normale vej
2. `/sys/class/block/dm-*/dm/uuid` — den aabne mapping siger `CRYPT-LUKS1`
   eller `CRYPT-LUKS2`, og `slaves/` peger paa selve containeren. Verdenslaesbar,
   ingen udev og ingen root involveret
3. `/etc/crypttab` — hvad boot faktisk laaser op. Mode 0644

Kilde 2 er den vigtige: koerer maskinen overhovedet fra en LUKS-disk, er
mappingen aaben lige nu. Krypteret swap med tilfaeldig noegle springes over —
den er plain dm-crypt, ikke LUKS, og maa aldrig blive den enhed modulet binder
sig til.

Sig kontrollen stadig nej, saa afgoer disse tre om det er disken eller
kontrollen der tager fejl:

```bash
lsblk -f                                    # er FSTYPE tom for ALT?
cat /etc/crypttab                           # hvad laaser boot op?
grep . /sys/class/block/dm-*/dm/uuid        # CRYPT-LUKS2-… = krypteret
```

Er FSTYPE tom for alt, er det udev — og saa er disken krypteret, kontrollen kan
bare ikke se det. Kender du enheden, kan du saette den udenom detektionen:

```bash
DTU_LUKS_DEVICE=/dev/nvme0n1p3   # i env-filen, eller
sudo scripts/ubuntu/tpm2-enroll.sh /dev/nvme0n1p3
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
