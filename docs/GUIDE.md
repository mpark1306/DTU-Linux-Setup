# DTU Linux Setup – Brugerguide

> **Målgruppe:** IT-teknikere der opsætter DTU Sustain/AIT Linux-arbejdsstationer.

---

## Første gang: Komplet installationsvejledning

Følg disse trin præcis i denne rækkefølge første gang du sætter en ny maskine op.

---

### Trin 1 – Skaf `.env`-konfigurationsfilen

Programmet kræver en intern DTU-konfigurationsfil med serveradresser, domænenavne m.m.  
Kontakt **[@mpark1306](https://github.com/mpark1306)** (Mark Parking, DTU Sustain) og bed om:

- `dtu-sustain.env` — hvis maskinen tilhører **Sustain**
- `dtu-ait.env` — hvis maskinen tilhører **AIT**

---

### Trin 2 – Klon repo'etuvz3

```bash
git clone https://github.com/mpark1306/DTU-Linux-Setup
cd DTU-Linux-Setup
```

---

### Trin 3 – Installer afhængigheder og programmet

**Ubuntu 24.04:**
```bash
sudo apt update
sudo apt install kde-standard python3 python3-pyqt6 policykit-1
make deb
sudo dpkg -i dtu-sustain-setup_1.0.0_all.deb
```

**openSUSE Tumbleweed:**
```bash
sudo zypper install python3-qt6 polkit
make rpm
sudo zypper install ~/rpmbuild/RPMS/noarch/dtu-sustain-setup-1.0.0-1.noarch.rpm
```

---

### Trin 4 – Placér konfigurationsfilen

Åbn en terminal i den mappe hvor du har gemt `.env`-filen, f.eks.:

```bash
cd ~/Downloads
```

Kør derefter (erstat `dtu-sustain.env` med `dtu-ait.env` og `sustain` med `ait` for AIT-maskiner):

```bash
sudo install -d /etc/dtu-setup
sudo install -m 0644 dtu-sustain.env /etc/dtu-setup/site.conf
echo "sustain" | sudo tee /etc/dtu-setup/department

eller:
sudo install -m 0644 dtu-ait.env /etc/dtu-setup/site.conf
echo "ait" | sudo tee /etc/dtu-setup/department
```

Filerne lander på:

| Fil | Indhold |
|-----|---------|
| `/etc/dtu-setup/site.conf` | Serveradresser, domæne, printer m.m. |
| `/etc/dtu-setup/department` | Enten `sustain` eller `ait` |

---

### Trin 5 – Sørg for at have disse oplysninger klar

| Hvad                       | Eksempel       | Bruges til                         |
|----------------------------|----------------|------------------------------------|
| DTU-brugernavn             | `mpark`        | Netværksdrev, printer, WiFi |
| DTU-adgangskode            | `*****`        | Netværksdrev, printer, WiFi |
| Adm-brugernavn             | `adm-<username>`    | Domain Join                 |
| Ønsket hostname            | `SUS-EX-PC01`  | Domain Join                 |
| Cisco tarball *(valgfrit)* | `cisco-secure-client-linux64-*.tar.gz` | VPN |

> Du kan hente den sidste nye Cisco tarball på [net.ait.dtu.dk](https://net.ait.dtu.dk/vpn/) → søg efter "Cisco Secure Client" → vælg Linux-versionen. Filen hedder typisk `cisco-secure-client-linux64-X.X.X-XXX.tar.gz`.

---

### Trin 6 – Start programmet

```bash
dtu-sustain-setup
```

Eller find **DTU Linux Setup** i applikationsmenuen.

---

### Trin 7 – Kør alle moduler

1. Vælg korrekt **Department** i dropdown'en øverst (Sustain eller AIT)
2. Klik **▶ Run All Admin Modules**
3. Udfyld de tre dialoger der vises:

   **Dialog 1 – DTU-bruger (til drev, printer og WiFi):**
   ```
   Username: mpark
   Password: ********
   ```

   **Dialog 2 – Domain Join:**
   ```
   Hostname:       DTU-SUS-PC01
   Admin Username: adm-<username>
   ```

4. Godkend PolicyKit-dialogen (din lokale admin-adgangskode)
5. Følg fremgangen i **Output Log** — hvert modul logger sine trin
6. Knapper bliver **grønne** ved succes, **røde** ved fejl

---

### Trin 8 – Genstart

```bash
sudo reboot
```

Genstart er nødvendig for at domæne-login, Flatpak-apps og systemd-automounts virker korrekt.

---

## Opdatering af DTU Linux Setup

Når der er kommet en ny version, opdateres programmet sådan:

```bash
cd ~/Documents/DTU-Linux-Setup
git checkout deploy
git pull
make deb
sudo dpkg -i dtu-sustain-setup_1.0.0_all.deb
```

> Konfigurationsfilen `/etc/dtu-setup/site.conf` og `/etc/dtu-setup/department` røres ikke af en opdatering.

---

### Hvad kører "Run All" i hvilken rækkefølge?

```
 1. Domain Join        ← Joiner WIN.DTU.DK
 2. Network Drives     ← Mounter Q+P (Sustain) / O+M (AIT)
 3. Microsoft Defender ← Installer + onboarding
 4. PolicyKit          ← Domænebruger-rettigheder
 5. Printers           ← FollowMe (Sustain) / WebPrint (AIT)
 6. DTUSecure WiFi     ← WPA2-Enterprise auto-connect
 7. Software           ← Flatpak, Snap, Cisco VPN
 8. Auto-mount         ← USB udev-regler
 9. Sync Home Dirs    ← rsync Desktop/Documents/Pictures
10. RDP (xrdp)        ← Remote Desktop (kun Ubuntu)
11. First-Login Setup ← Welcome-dialog til nye brugere
```

---

## Oversigt

DTU Linux Setup er et grafisk værktøj der automatiserer opsætning af Linux-arbejdsstationer på DTU (Sustain & AIT). Programmet samler alle nødvendige konfigurationsskridt i ét interface — fra domæne-join til printeropsætning.

```
┌───────────────────────────────────────────────────────┐
│                                                       │
│   DTU Linux Setup                                     │
│                                                       │
│   ┌─────────┐  ┌─────────┐                            │
│   │ Domain  │  │ Q-Drive │                            │
│   │ Join    │  │         │                            │
│   └─────────┘  └─────────┘                            │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐               │
│   │Defender │  │PolicyKit│  │FollowMe │               │
│   └─────────┘  └─────────┘  └─────────┘               │
│   ┌─────────┐  ┌─────────┐                            │
│   │Software │  │Automount│                            │
│   └─────────┘  └─────────┘                            │
│   ┌─────────┐                                         │
│   │  RDP    │                                         │
│   └─────────┘                                         │
│                                                       │
│   [ ▶ Run All Admin Modules ]           [ Cancel ]    │
│                                                       │
│   Output Log:                                         │
│   ┌───────────────────────────────────────────────┐   │
│   │                                               │   │
│   └───────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────┘
```

---

## Hurtigstart: Fuld opsætning af en ny maskine

### Trin 1: Installer DTU Linux Setup

**Ubuntu 24.04:**
```bash
sudo apt update && sudo apt install python3-pyqt6
make deb
sudo dpkg -i dtu-sustain-setup_1.0.0_all.deb
```

**openSUSE Tumbleweed:**
```bash
sudo zypper install python3-qt6
make rpm
sudo zypper install ~/rpmbuild/RPMS/noarch/dtu-sustain-setup-1.0.0-1.noarch.rpm
```

### Trin 2: Forberedelser

Inden du starter, sørg for at have:

| Hvad                     | Eksempel                               | Bruges til              |
|--------------------------|-------------------------------------- -|-------------------------|
| DTU-brugernavn           | `mpark`                                | Q-Drive, FollowMe, WiFi |
| DTU-adgangskode          | `*****`                                | Q-Drive, FollowMe       |
| Admin-brugernavn         | `adm-<username>`                            | Domain Join             |
| Ønsket hostname          | `DTU-SUS-PC01`                         | Domain Join             |
| Cisco tarball (valgfrit) | `cisco-secure-client-linux64-*.tar.gz` | VPN                     |

### Trin 3: Start programmet

```bash
dtu-sustain-setup
```

Eller find **DTU Linux Setup** i applikationsmenuen under **Indstillinger**.

### Trin 4: Kør alle moduler

1. Klik **▶ Run All Admin Modules**
2. Udfyld dialogerne:

```
Dialog 1: Domain-bruger
┌──────────────────────────────┐
│  Run All – Domain User       │
│  Credentials                 │
│                              │
│  Username: [ mpark        ]  │
│  Password: [ ************ ]  │
│                              │
│        [ OK ]  [ Cancel ]    │
└──────────────────────────────┘

Dialog 2: Domain Join
┌──────────────────────────────┐
│  Domain Join – WIN.DTU.DK    │
│                              │
│  Hostname:      [ DTU-SUS-01 ]│
│  Admin Username:[ adm-<username>  ]│
│                              │
│        [ OK ]  [ Cancel ]    │
└──────────────────────────────┘
```

3. Godkend PolicyKit (admin-adgangskode)
4. Vent mens alle moduler kører – følg fremgangen i Output Log

```
Output Log:
═══════════════════════════════════════
▶ Running with elevated privileges: domain-join.sh

=== Domain Join ===

[1/7] Setting hostname to DTU-SUS-01...
✅ Hostname set.
[2/7] Installing packages...
[3/7] Discovering WIN.DTU.DK...
    ✅ Domain discovered: WIN.DTU.DK
[4/7] Joining domain...
    Opening terminal for domain join...
✅ Domain join complete.
[5/7] Configuring SSSD...
✅ SSSD configured.
[6/7] Enabling mkhomedir...
[7/7] Restarting SSSD...
✅ Domain Join complete.

▶ Running with elevated privileges: qdrive.sh
=== Q-Drive Setup ===
...
═══ All modules completed ═══
```

### Trin 5: Genstart

```bash
sudo reboot
```

> Genstart er nødvendig for at domæne-login, Flatpak-apps og systemd-automounts virker korrekt.

---

## Guide: Kør moduler enkeltvis

Du behøver ikke køre alle moduler. Klik blot på det ønskede modul.

### Domain Join

**Formål:** Tilslut maskinen til WIN.DTU.DK Active Directory.

```
1. Klik [ Domain Join ]
2. Indtast hostname og admin-brugernavn
3. Et terminalvindue åbner — indtast admin-adgangskode der
4. Vent på "Domain Join complete"
5. Genstart maskinen
```

**Verifikation:**
```bash
# Tjek at maskinen er joined
realm list

# Tjek at en domænebruger kan slås op
id mpark
```

**Forventet output:**
```
win.dtu.dk
  type: kerberos
  realm-name: WIN.DTU.DK
  domain-name: win.dtu.dk
  configured: kerberos-member
```

---

### Q-Drive

**Formål:** Monter DTU's netværksdrev.

```
1. Klik [ Q-Drive ]
2. Indtast brugernavn + adgangskode
3. Vent på "Q-Drive Setup complete"
```

**Verifikation:**
```bash
# Drevene monteres ved adgang (automount)
ls /mnt/Qdrev
ls /mnt/Personal    # kun Ubuntu
```

> **Tip:** Efter opsætning af Q-Drive, kør **Auto-mount / Pdrev** for at få `/mnt/Pdrev`-symlink.

---

### Software

**Formål:** Installer Flatpak-apps, Snap-pakker og Cisco VPN.

```
1. Klik [ Software ]
2. Software-dialogen åbner:

   ┌──────────────────────────────────────────────┐
   │  ┌──────────┬───────┬───────────┐            │
   │  │ Flatpak  │ Snap  │  Cisco    │            │
   │  ├──────────────────────────────┤            │
   │  │ com.microsoft.Edge           │            │
   │  │ com.github.tchx84.Flatseal   │            │
   │  │ org.flameshot.Flameshot      │            │
   │  │ ...                          │            │
   │  └──────────────────────────────┘            │
   │  [ + Add ] [ ✏ Edit ] [ − Remove ]           │
   │                                              │
   │  Cisco tarball: [ ________________ ] [Browse]│
   │                                              │
   │  [ Save ]              [ Save & Install ]    │
   └──────────────────────────────────────────────┘

3. Tilpas listen efter behov:
   - Tilføj: Klik [ + Add ] og indtast Flatpak app-ID
   - Fjern:  Vælg en pakke og klik [ − Remove ]
   - Ret:    Vælg en pakke og klik [ ✏ Edit ]

4. Valgfrit: Vælg Cisco tarball via [ Browse ]
5. Klik [ Save & Install ]
```

**Tilføj en Flatpak-app:**
```
Flatpak app-ID'er finder du på https://flathub.org
Eksempler:
  com.spotify.Client
  org.mozilla.firefox
  org.kde.kate
```

---

### FollowMe Printers

**Formål:** Opsæt DTU's FollowMe multifunction- og plotter-printere.

```
1. Klik [ FollowMe Printers ]
2. Indtast brugernavn + adgangskode (WIN-domæne)
3. Vent på "FollowMe complete"
```

**Verifikation:**
```bash
lpstat -p -d
```

**Forventet output:**
```
printer FollowMe-MFP-PCL is idle.
printer FollowMe-Plot-PS is idle.
```

---

## Anbefalet rækkefølge for moduler

Hvis du kører modulerne enkeltvis, anbefales denne rækkefølge:

```
 1. Domain Join        ← Skal køres først (kræver genstart)
                         ↓ GENSTART
 2. PolicyKit          ← Giver domænebrugere rettigheder
 3. Q-Drive            ← Kræver domæne-credentials
 4. Auto-mount         ← Kræver Q-Drive
 5. FollowMe Printers  ← Kræver domæne-credentials
 6. Microsoft Defender ← Uafhængig
 7. Software           ← Uafhængig
 8. RDP (xrdp)         ← Uafhængig (kun Ubuntu)
```

---

## Konfigurationsfilen software.conf

Filen `data/software.conf` styrer hvilken software der installeres:

```ini
# Kommentarer starter med #
# Tomme linjer ignoreres

[flatpak]
com.microsoft.Edge              # Microsoft Edge browser
com.github.tchx84.Flatseal      # Flatpak permissions manager
org.flameshot.Flameshot          # Screenshot tool
org.libreoffice.LibreOffice       # Office suite
com.github.IsmaelMartinez.teams_for_linux  # Microsoft Teams
org.remmina.Remmina              # Remote Desktop client
us.zoom.Zoom                     # Zoom meetings
com.usebottles.bottles           # Windows app runner
io.github.alescdb.mailviewer     # Mail viewer

[snap]
office365webdesktop              # Office 365 web apps

[cisco]
cisco-secure-client              # Cisco AnyConnect VPN
```

**Rediger manuelt:**
```bash
nano data/software.conf
# eller
nano /opt/dtu-sustain-setup/data/software.conf
```

**Rediger via GUI:** Klik **Software** → tilføj/fjern/ret → **Save**

---

## Fejlsøgning

### Generelt

| Problem                   | Løsning                                                        |
|---------------------------|----------------------------------------------------------------|
| GUI starter ikke          | `python3 -c "from PyQt6.QtWidgets import QApplication"`        |
| pkexec fejler             | Installer `policykit-1` (Ubuntu) eller `polkit` (openSUSE)     |
| Forkert distro detekteret | Tjek `/etc/os-release`                                         |
| Script not found          | Tjek at scripts er i `/opt/dtu-sustain-setup/scripts/<distro>/`|

### Domain Join

| Problem                         | Løsning                              |
|---------------------------------|--------------------------------------|
| "Domain not found"              | Tjek DNS: `nslookup WIN.DTU.DK`      |
| "Failed to join"                | Tjek admin-bruger har join-rettighed |
| Domænebruger kan ikke logge ind | Tjek SSSD: `systemctl status sssd`   |

### Q-Drive

| Problem             | Løsning                                                         |
|---------------------|-----------------------------------------------------------------|
| Mount fejler        | Tjek credentials og netværk: `smbclient -L //<fileserver> -U <username>` |
| "Permission denied" | Tjek `/etc/fstab` entries og credentials-fil                    |

### Cisco VPN

| Problem             | Løsning                                                       |
|---------------------|---------------------------------------------------------------|
| "Tarball not found" | Placer `cisco-secure-client-linux64-*.tar.gz` vælg via Browse |
| NVM fejler          | Forventet på nye kerner — Cisco-begrænsning, kan ignoreres    |
| VPN virker ikke     | Tjek `libxml2.so.2` er installeret                            |


---

## Kontakt

- **Team:** DTU Sustain IT
- **E-mail:** mpark@dtu.dk
- **Repository:** https://github.com/DTU-Sustain/DTU-Umbrella
