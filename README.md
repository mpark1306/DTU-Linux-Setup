# DTU Sustain Setup

Et grafisk opsætningsværktøj til DTU Sustain Linux-arbejdsstationer. Understøtter **Ubuntu 24.04 LTS** og **openSUSE Tumbleweed**.

<p align="center">
  <img src="data/dtu-sustain-setup.svg" alt="DTU Sustain Setup" width="128">
</p>

---

## Indholdsfortegnelse

- [Funktioner](#funktioner)
- [Installation](#installation)
- [Brug](#brug)
- [Moduler i detaljer](#moduler-i-detaljer)
- [Software-styring](#software-styring)
- [Arkitektur](#arkitektur)
- [Filstruktur](#filstruktur)
- [Udvikling](#udvikling)
- [Fejlfinding](#fejlfinding)

---

## Funktioner

| Modul | Beskrivelse | Kræver root |
|-------|-------------|:-----------:|
| **Domain Join** | Join WIN.DTU.DK via realmd + SSSD + mkhomedir | ✅ |
| **Q-Drive** | CIFS-mount af `\\<fileserver>\Qdrev\SUS` | ✅ |
| **Brother P950NW** | Labelprinter (CUPS + ptouch-driver) | ✅ |
| **Microsoft Defender** | Defender for Endpoint (install + onboard) | ✅ |
| **PolicyKit** | IT-admin rettigheder (SUS-ITAdm-Client-Admins) | ✅ |
| **FollowMe Printers** | MFP-PCL + Plot-PS (CUPS + SMB-auth) | ✅ |
| **OneDrive** | OneDrive for Business (sync + folder symlinks) | ✅ |
| **Software** | Flatpak, Snap & Cisco Secure Client VPN | ✅ |
| **Auto-mount / Pdrev** | Pdrev-symlink + desktop polkit (USB, WiFi m.m.) | ✅ |
| **RDP (xrdp)** | Remote Desktop (KDE Plasma via xrdp) | ✅ |
| **Ansible Onboarding** | sus-root konto + SSH-nøgle + sudo | ✅ |

---

## Installation

### Forudsætninger

|                | Ubuntu 24.04        | openSUSE Tumbleweed |
|----------------|---------------------|---------------------|
| **KDE**        | `kde-standard`      | `pre-installed`     |
| **Python**     | `python3` (≥ 3.10)  | `python3` (≥ 3.10)  |
| **GUI**        | `python3-pyqt6`     | `python3-qt6`       |
| **Privilegier**| `policykit-1`       | `polkit`            |
| **Shell**      | `bash`              | `bash`              |


### Ubuntu 24.04

```bash
# Kør disse for manuel installation

# 1. Installer KDE
sudo apt install kde-standard

# 2. Installer forudsætninger
sudo apt update
sudo apt install python3 python3-pyqt6 policykit-1 

# 2a. Installer direkte
sudo make install

# 2b. Eller byg DEB-pakke (anbefalet)
make deb
sudo dpkg -i dtu-sustain-setup_1.0.0_all.deb
```

### openSUSE Tumbleweed
openSUSE Tumbleweed kører **KDE** som standard, så her skal pakker installeres manuelt.

```bash
# 1. Installer forudsætninger
sudo zypper install python3-qt6

# 2a. Installer direkte
sudo make install

# 2b. Eller byg RPM-pakke (anbefalet)
make rpm
sudo zypper install ~/rpmbuild/RPMS/noarch/dtu-sustain-setup-1.0.0-1.noarch.rpm
```

### Afinstallation

```bash
sudo make uninstall
```

---

## Brug

### Start programmet

**Fra applikationsmenuen:**
Efter installation findes **DTU Sustain Setup** i systemets applikationsmenu under **Indstillinger** (Settings). Det er synligt for alle brugere, inklusiv domænebrugere.

**Fra terminalen:**
```bash
# Kør installeret version
dtu-sustain-setup

# Kør fra kildekode (development)
make run
```

### Hovedvinduet

Når programmet starter, vises hovedvinduet med et grid af modulknapper:

```
┌─────────────────────────────────────────────────────────────────┐
│  🔴  DTU Sustain Setup                                          │
│  Detected: Ubuntu 24.04.1 LTS                                   │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ Domain Join  │  │ Q-Drive      │  │ Brother      │           │
│  │ Join         │  │ Map CIFS     │  │ P950NW       │           │
│  │ WIN.DTU.DK   │  │ mount        │  │ Label printer│           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ MS Defender  │  │ PolicyKit    │  │ FollowMe     │           │
│  │ Endpoint     │  │ IT admin     │  │ Printers     │           │
│  │ protection   │  │ backdoor     │  │ MFP + Plot   │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ OneDrive     │  │ Software     │  │ Auto-mount   │           │
│  │ Business sync│  │ Flatpak/Snap │  │ Pdrev/USB    │           │
│  │ + symlinks   │  │ + Cisco VPN  │  │ polkit       │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│  ┌──────────────┐  ┌──────────────┐                             │
│  │ RDP (xrdp)   │  │ Ansible      │                             │
│  │ Remote       │  │ Onboarding   │                             │
│  │ Desktop      │  │ sus-root     │                             │
│  └──────────────┘  └──────────────┘                             │
│                                                                 │
│  [ ▶  Run All Admin Modules ]                       [ Cancel ]  │
│                                                                 │
│  Output Log:                                                    │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ ▶ Running with elevated privileges: domain-join.sh          ││
│  │ === Domain Join ===                                         ││
│  │ [1/7] Setting hostname...                                   ││
│  │ ✅ Hostname set to DTU-SUS-PC01                             ││
│  └─────────────────────────────────────────────────────────────┘│
│  Ready                                                          │
└─────────────────────────────────────────────────────────────────┘
```

### Sådan kører du et enkelt modul
Vær opmærksom på at nogle moduler kræver at brugeren som skal bruge computeren skal inputte username og password (fra domainet) for at kunne kører.

1. Klik på modulets knap (f.eks. **Domain Join**)
2. Udfyld den dialog der dukker op (brugernavn, adgangskode, etc.)
3. Godkend privilegieeskalering via PolicyKit (indtast admin-adgangskode)
4. Følg fremgangen i **Output Log** nederst i vinduet
5. Knappen skifter farve: **grøn** = succes, **rød** = fejl

### Kør alle moduler på én gang (KUN hvis du har bruger med dig)

1. Klik **▶ Run All Admin Modules**
2. Indtast dine credentials i de dialoger der vises:
   - *Domain-bruger (brugernavn + adgangskode)
   - Domain Join info (hostname + admin-brugernavn)
   - Ansible-adgangskode for sus-root (Se Bitwarden)
3. Alle moduler kører automatisk i rækkefølge
4. Brug **Cancel** for at stoppe køen

* = kræver, at brugeren selv taster username og password.

---

## Moduler i detaljer

### 🌐 Domain Join

Joiner maskinen til DTU's Active Directory-domæne (`WIN.DTU.DK`).

```
Bruger-input:
  ├── Hostname      (f.eks. DTU-SUS-PC01)
  └── Admin bruger  (f.eks. adm-<username>)
```

**Hvad sker der:**
1. Sætter maskinens hostname
2. Installerer `realmd`, `sssd`, `sssd-ad`, `adcli`, `krb5-user`
3. Opdager domænet via DNS
4. Åbner et terminalvindue til domæne-join (interaktiv adgangskode)
5. Konfigurerer SSSD: korte brugernavne, `/home/<user>` som hjemmemappe
6. Aktiverer mkhomedir (auto-opret hjemmemappe ved første login)

**Resultat:** Domænebrugere kan logge ind med deres DTU-brugernavn.

---

### 📁 Q-Drive

Monterer DTU's delte netværksdrev som CIFS-mount.

```
Bruger-input:
  ├── Brugernavn  (WIN-domæne)
  └── Adgangskode
```

**Mount-oversigt:**

| Drev | Netværkssti | Lokalt mountpoint |
|------|-------------|-------------------|
| Q-Drive | `konfigureret via site.conf` | `/mnt/Qdrev` |
| P-Drive (Ubuntu) | `konfigureret via site.conf<user>` | `/mnt/Personal` |

> **openSUSE note:** Bruger direkte sti `konfigureret via site.conf` for at omgå en kernel DFS-bug.

**Automount:** Drevene monteres automatisk ved adgang (systemd automount).

---

### 🏷️ Brother P950NW

Opsætter Brother PT-P950NW labelprinter via CUPS.

| | Detalje |
|-|---------|
| **IP** | `10.61.1.9:9100` |
| **Driver** | ptouch (Ubuntu: pakke, openSUSE: bygget fra kilde) |
| **Standard** | 12mm tape, 360 dpi |

---

### 🛡️ Microsoft Defender

Installerer Microsoft Defender for Endpoint.

**Hvad sker der:**
1. Tilføjer Microsofts pakke-repository + GPG-nøgle
2. Installerer `mdatp`
3. Aktiverer realtidsbeskyttelse
4. Kører onboarding fra `konfigureret via site.conf`
5. Konfigurerer network protection

> **openSUSE note:** Bruger SLES 15-pakker — ikke officielt understøttet på Tumbleweed.

---

### 🔑 PolicyKit

Konfigurerer PolicyKit-regler for domænebrugere og IT-administratorer.

**Domænebrugere får UDEN adgangskode:**
- 🔌 USB-devices: mount/unmount/eject
- 📶 WiFi/VPN/netværk: tilslut og konfigurer
- ⏻ Strøm: sluk, genstart, dvale
- 🖨️ CUPS: admin egne printjobs
- 🔵 Bluetooth-operationer

**IT-administratorer (`SUS-ITAdm-Client-Admins`) får:**
- Fuld adgang til alt via polkit + sudoers

---

### 🖨️ FollowMe Printers

Opsætter DTU's FollowMe-printere.

```
Bruger-input:
  ├── Brugernavn  (WIN-domæne)
  └── Adgangskode
```

| Printer          | Type          |      Server            |
|------------------|---------------|------------------------|
| FollowMe-MFP-PCL | Multifunktion | `konfigureret via site.conf` |
| FollowMe-Plot-PS | Plotter       | `konfigureret via site.conf` |

Bruger tilpasset `smbspool-auth` CUPS-backend til SMB-autentificering.

---

### ☁️ OneDrive

Opsætter OneDrive for Business via [abraunegg/onedrive](https://github.com/abraunegg/onedrive).

```
Bruger-input:
  └── Brugernavn (målbruger)
```

**Mappestruktur:**
```
~/OneDrive/
├── Dokumenter/   ← ~/Documents symlink
├── Skrivebord/   ← ~/Desktop symlink
└── Billeder/     ← ~/Pictures symlink
```

> Eksisterende mapper flyttes til backup (`Documents.bak.YYYYMMDD-HHMMSS`).

**Autentificering** sker ved første login via Konsole-terminal.

---

### 💻 Software

Installerer software fra Flatpak, Snap og Cisco Secure Client VPN.

Se afsnittet [Software-styring](#software-styring) for detaljer.

---

### 🔁 Auto-mount / Pdrev

Opsætter automatisk Pdrev-symlink og desktop-polkit.

**Hvad sker der:**
1. Opretter polkit-regler så brugere kan bruge USB, WiFi m.m. uden adgangskode
2. Installerer PAM-session script der opretter `/mnt/Pdrev → /mnt/Qdrev/Personal/<user>` ved login

> **Krav:** Q-Drive-modulet skal køres først.

---

### 🖥️ RDP (xrdp) — kun Ubuntu

Opsætter Remote Desktop via xrdp med KDE Plasma.

|    Detalje       |------------------------------|
|  **Port**        | 3389/tcp                     |
|  **Session**     | KDE Plasma X11               |
|  **Sikkerhed**   | TLS (ingen plain RDP)        |
|  **Features**    | Clipboard, drive redirection |

Forbind fra enhver RDP-klient (Windows Remote Desktop, Remmina, etc.).

---

### ⚙️ Ansible Onboarding

Opretter `sus-root` service-konto til Ansible-automatisering.

```
Bruger-input:
  └── sus-root adgangskode
```

**Hvad sker der:**
1. Installerer `openssh-server` + `python3`
2. Opretter systembruger `sus-root` (skjult fra loginskærm)
3. Deployer SSH-nøgle (ed25519)
4. Konfigurerer passwordless sudo

---

## Software-styring

Softwaremodulet bruger en konfigurerbar liste i stedet for hardkodede pakker.

### Konfigurationsfil

Software-listen gemmes i `data/software.conf`:

```ini
# Sektioner: flatpak, snap, cisco

[flatpak]
com.microsoft.Edge
com.github.tchx84.Flatseal
org.flameshot.Flameshot
org.onlyoffice.desktopeditors
com.github.IsmaelMartinez.teams_for_linux
org.remmina.Remmina
us.zoom.Zoom
com.usebottles.bottles
io.github.alescdb.mailviewer

[snap]
office365webdesktop

[cisco]
cisco-secure-client
```

### Software-dialogen

Når du klikker på **Software**-knappen, åbnes en dialog til at administrere pakkelisten:

```
┌─────────────────────────────────────────────────────┐
│  Software – Manage Packages                         │
│                                                     │
│  Manage which software packages will be installed.  │
│  Add, remove or edit entries, then click Install.   │
│                                                     │
│  ┌──────────┬───────┬──────────┐                    │
│  │ Flatpak  │ Snap  │  Cisco   │                    │
│  ├──────────┴───────┴──────────┤                    │
│  │ com.microsoft.Edge          │                    │
│  │ com.github.tchx84.Flatseal  │  ◄── vælg pakke    │
│  │ org.flameshot.Flameshot     │                    │
│  │ org.onlyoffice.desktoped... │                    │
│  │ com.github.IsmaelMartine... │                    │
│  │ org.remmina.Remmina         │                    │
│  │ us.zoom.Zoom                │                    │
│  │ com.usebottles.bottles      │                    │
│  │ io.github.alescdb.mailvi... │                    │
│  └─────────────────────────────┘                    │
│  [ + Add ]   [ ✏ Edit ]   [ − Remove ]              │
│                                                     │
│  Cisco tarball (.tar.gz):                           │
│  [ /home/user/cisco-secure-client.tar.gz ] [Browse] │
│                                                     │
│  [ Save ]                   [ Save & Install ] [X]  │
└─────────────────────────────────────────────────────┘
```

**Funktioner:**
- **Tabs:** Skift mellem Flatpak, Snap og Cisco-sektioner
- **+ Add:** Tilføj en ny pakke-ID til den aktive sektion
- **✏ Edit:** Ret den valgte pakkes ID
- **− Remove:** Fjern den valgte pakke
- **Browse…:** Vælg Cisco Secure Client tarball (.tar.gz)
- **Save:** Gem ændringer til `software.conf` uden at installere
- **Save & Install:** Gem og kør installationen

### Cisco Secure Client VPN

Cisco-installationen kører alle moduler i tarball'en (ikke kun VPN):

```
Installationsrækkefølge:
  1. vpn (VPN-klient — altid først)
  2. dart (Diagnostic And Reporting Tool)
  3. fireamp (AMP for Endpoints)
  4. iseposture (ISE Posture)
  5. nvm (Network Visibility Module — kan fejle på nyere kerner)
  6. ... øvrige moduler
```

> **Tip:** Placer tarball'en i repo-roden (`cisco-secure-client-linux64-*.tar.gz`), så findes den automatisk.

---

## Arkitektur

```
                    ┌──────────────────┐
                    │      Bruger      │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  PyQt6 GUI       │
                    │  main_window.py  │
                    │                  │
                    │  ┌────────────┐  │
                    │  │ Input      │  │
                    │  │ Dialogs    │  │
                    │  └────────────┘  │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  ModuleRunner    │
                    │  module_runner.py│
                    │                  │
                    │  QProcess +      │
                    │  pkexec wrapper  │
                    └────────┬─────────┘
                             │
                ┌────────────┼────────────┐
                │                         │
       ┌────────▼────────┐      ┌────────▼────────-┐
       │ scripts/ubuntu/ │      │scripts/opensuse/ │
       │                 │      │                  │
       │ domain-join.sh  │      │ domain-join.sh   │
       │ qdrive.sh       │      │ qdrive.sh        │
       │ brother.sh      │      │ brother.sh       │
       │ defender.sh     │      │ defender.sh      │
       │ polkit.sh       │      │ polkit.sh        │
       │ followme.sh     │      │ followme.sh      │
       │ onedrive.sh     │      │ onedrive.sh      │
       │ software.sh     │      │ software.sh      │
       │ automount.sh    │      │ automount.sh     │
       │ rdp.sh          │      │                  │
       │ ansible.sh      │      │                  │
       └─────────────────┘      └──────────────────┘
                │                         │
                └────────────┬────────────┘
                             │
                    ┌────────▼─────────┐
                    │  common.sh       │
                    │  (delte helpers) │
                    └──────────────────┘
```

**Dataflow:**

1. **GUI** samler bruger-input via Qt-dialogs (credentials, hostname, etc.)
2. **ModuleRunner** opretter en wrapper-script der eksporterer `DTU_*` env vars
3. **pkexec** eskalerer til root via PolicyKit
4. **Bash-scripts** udfører den egentlige opsætning
5. **Live output** streames tilbage til GUI'ens log-widget via QProcess

**Environment-variabler:**

| Variabel              | Bruges af                        |
|-----------------------|----------------------------------|
| `DTU_USERNAME`        | Q-Drive, FollowMe, OneDrive      |
| `DTU_PASSWORD`        | Q-Drive, FollowMe                |
| `DTU_HOSTNAME`        | Domain Join                      |
| `DTU_ADMIN_USERNAME`  | Domain Join                      |
| `DTU_ANSIBLE_PASSWORD`| Ansible Onboarding               |
| `DTU_SOFTWARE_CONF`   | Software (sti til software.conf) |
| `DTU_CISCO_TARBALL`   | Software (sti til Cisco .tar.gz) |

---

## Filstruktur

```
DTU-Umbrella/
├── src/dtu_sustain_setup/          # PyQt6 GUI-applikation
│   ├── __init__.py                 # Pakke-definition
│   ├── __main__.py                 # Entry point
│   ├── main_window.py              # Hovedvindue med modul-grid
│   ├── module_runner.py            # QProcess wrapper + pkexec
│   ├── input_dialog.py             # Credential/username/software dialogs
│   └── distro.py                   # Distro-detektion (/etc/os-release)
├── scripts/
│   ├── common.sh                   # Fælles bash-helpers (banner, ok, warn, etc.)
│   ├── ubuntu/                     # Ubuntu 24.04 modul-scripts
│   │   ├── domain-join.sh
│   │   ├── qdrive.sh
│   │   ├── brother.sh
│   │   ├── defender.sh
│   │   ├── polkit.sh
│   │   ├── followme.sh
│   │   ├── onedrive.sh
│   │   ├── software.sh
│   │   ├── automount.sh
│   │   ├── rdp.sh
│   │   └── ansible.sh
│   └── opensuse/                   # openSUSE Tumbleweed modul-scripts
│       ├── domain-join.sh
│       ├── qdrive.sh
│       ├── brother.sh
│       ├── defender.sh
│       ├── polkit.sh
│       ├── followme.sh
│       ├── onedrive.sh
│       ├── software.sh
│       └── automount.sh
├── data/
│   ├── dtu-sustain-setup.desktop   # XDG desktop entry
│   ├── dtu-sustain-setup.svg       # App-ikon
│   ├── dk.dtu.sustain.setup.policy # Polkit policy
│   └── software.conf               # Software-pakkeliste
├── bin/
│   └── dtu-sustain-setup           # Launcher-script
├── packaging/
│   ├── debian/                     # DEB-pakke filer (control, rules, etc.)
│   └── rpm/                        # RPM spec-fil
├── Makefile                        # Build, install, deb, rpm
├── pyproject.toml                  # Python project metadata
└── README.md                       # Denne fil
```

---

## Udvikling

### Kør fra kildekode

```bash
# Direkte
PYTHONPATH=src python3 -m dtu_sustain_setup

# Via Makefile
make run
```

### Byg pakker

```bash
# DEB (Ubuntu)
make deb

# RPM (openSUSE)
make rpm
```

### Tilføj et nyt modul

1. **Opret script:** `scripts/ubuntu/mit-modul.sh` (og evt. `scripts/opensuse/mit-modul.sh`)
   - Start med `source "${SCRIPT_DIR}/../common.sh"` og `need_root`
   - Brug `banner`, `ok`, `warn`, `fail` helpers
2. **Registrer i GUI:** Tilføj en `ModuleDef` til `MODULES`-listen i `main_window.py`
3. **Vælg input_type:**
   - `"none"` — ingen brugerinput
   - `"credentials"` — brugernavn + adgangskode
   - `"username"` — kun brugernavn
   - `"password"` — kun adgangskode
   - `"domain_join"` — hostname + admin-brugernavn
   - `"software"` — software-dialog med pakkeliste

### Tilføj standard-software

Rediger `data/software.conf`:

```ini
[flatpak]
com.spotify.Client          # ← tilføj Flatpak-ID her

[snap]
slack                       # ← tilføj Snap-navn her
```

Eller brug Software-dialogen i GUI'en.

---

## Fejlfinding

### Programmet starter ikke

```bash
# Tjek PyQt6 er installeret
python3 -c "from PyQt6.QtWidgets import QApplication; print('OK')"

# Tjek at launcher virker
which dtu-sustain-setup
```

### "pkexec not found"

```bash
# Ubuntu
sudo apt install policykit-1

# openSUSE
sudo zypper install polkit
```

### Modul fejler med "Script Missing"

Forkert distro detekteret? Tjek:
```bash
cat /etc/os-release
```

Programmet søger scripts i:
- Installeret: `/opt/dtu-sustain-setup/scripts/<ubuntu|opensuse>/`
- Development: `<repo>/scripts/<ubuntu|opensuse>/`

### Domain Join fejler

- Tjek DNS: `nslookup WIN.DTU.DK`
- Tjek netværk: Maskinen skal kunne nå DTU's DC'er
- Brug en admin-konto med rettighed til at joine maskiner

### Cisco VPN installerer ikke

- Sørg for at tarball'en er tilgængelig (vælg via **Browse…** eller placer i repo-roden)
- NVM-modulet fejler typisk på nyere kerner — dette er en Cisco-begrænsning
- Tjek afhængigheder: `libxml2`, `linux-headers`, `gcc`, `make`

### Software.conf ikke fundet

Filen forventes i:
1. `<repo>/data/software.conf` (development)
2. `/opt/dtu-sustain-setup/data/software.conf` (installeret)

---

## Licens

MIT

## Domain Join & mkhomedir

Domain-join modulet:
1. Installerer `realmd`, `sssd`, `adcli`, `krb5-user`/`krb5-client`
2. Kører `realm join WIN.DTU.DK` med admin-credentials
3. Konfigurerer SSSD: `use_fully_qualified_names = False`, `fallback_homedir = /home/%u`
4. Aktiverer `mkhomedir` (automatisk oprettelse af home-dir ved første login)

Efter domain join:
- Domænebrugere kan logge ind med korte brugernavne (f.eks. `mpark` i stedet for `mpark@WIN.DTU.DK`)
- Home-directories oprettes automatisk under `/home/`
- App-ikonet er synligt i menuen for alle brugere (`.desktop`-filen er i `/usr/share/applications/`)

## Afinstallation

```bash
sudo make uninstall
# eller
sudo dpkg -r dtu-sustain-setup      # Ubuntu
sudo zypper remove dtu-sustain-setup # openSUSE
```
