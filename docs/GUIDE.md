# DTU Sustain Setup – Brugerguide

> **Målgruppe:** IT-teknikere der opsætter DTU Sustain Linux-arbejdsstationer.

---

## Oversigt

DTU Sustain Setup er et grafisk værktøj der automatiserer opsætning af Linux-arbejdsstationer på DTU Sustain. Programmet samler alle nødvendige konfigurationsskridt i ét interface — fra domæne-join til printeropsætning.

```
┌───────────────────────────────────────────────────────┐
│                                                       │
│   DTU Sustain Setup                                   │
│                                                       │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐              │
│   │ Domain  │  │ Q-Drive │  │ Brother │              │
│   │ Join    │  │         │  │ P950NW  │              │
│   └─────────┘  └─────────┘  └─────────┘              │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐              │
│   │Defender │  │PolicyKit│  │FollowMe │              │
│   └─────────┘  └─────────┘  └─────────┘              │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐              │
│   │OneDrive │  │Software │  │Automount│              │
│   └─────────┘  └─────────┘  └─────────┘              │
│   ┌─────────┐  ┌─────────┐                            │
│   │  RDP    │  │ Ansible │                            │
│   └─────────┘  └─────────┘                            │
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

### Trin 1: Installer DTU Sustain Setup

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

| Hvad | Eksempel | Bruges til |
|------|----------|-----------|
| DTU-brugernavn | `mpark` | Q-Drive, FollowMe, OneDrive |
| DTU-adgangskode | `*****` | Q-Drive, FollowMe |
| Admin-brugernavn | `adm-<username>` | Domain Join |
| Ønsket hostname | `DTU-SUS-PC01` | Domain Join |
| sus-root adgangskode | `*****` | Ansible Onboarding |
| Cisco tarball (valgfrit) | `cisco-secure-client-linux64-*.tar.gz` | VPN |

### Trin 3: Start programmet

```bash
dtu-sustain-setup
```

Eller find **DTU Sustain Setup** i applikationsmenuen under **Indstillinger**.

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

Dialog 3: Ansible
┌──────────────────────────────┐
│  Run All – Ansible           │
│  Onboarding                  │
│                              │
│  sus-root password:          │
│  [ ************ ]            │
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

   ┌─────────────────────────────────────────────┐
   │  ┌──────────┬───────┬──────────┐            │
   │  │ Flatpak  │ Snap  │  Cisco   │            │
   │  ├──────────────────────────────┤            │
   │  │ com.microsoft.Edge           │            │
   │  │ com.github.tchx84.Flatseal   │            │
   │  │ org.flameshot.Flameshot      │            │
   │  │ ...                          │            │
   │  └──────────────────────────────┘            │
   │  [ + Add ] [ ✏ Edit ] [ − Remove ]          │
   │                                              │
   │  Cisco tarball: [ ________________ ] [Browse]│
   │                                              │
   │  [ Save ]              [ Save & Install ]    │
   └─────────────────────────────────────────────┘

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

### OneDrive

**Formål:** Opsæt OneDrive for Business med mappesynkronisering.

```
1. Klik [ OneDrive ]
2. Indtast målbrugerens brugernavn
3. Vent på installation
4. Ved FØRSTE login: Et terminalvindue åbner med login-URL
5. Kopier URL'en til en browser og log ind med DTU-konto
```

**Mappestruktur efter opsætning:**
```
~/
├── OneDrive/
│   ├── Dokumenter/
│   ├── Skrivebord/
│   └── Billeder/
├── Documents → OneDrive/Dokumenter    (symlink)
├── Desktop   → OneDrive/Skrivebord    (symlink)
└── Pictures  → OneDrive/Billeder      (symlink)
```

---

### Ansible Onboarding

**Formål:** Opret sus-root service-konto til central administration.

```
1. Klik [ Ansible Onboarding ]
2. Indtast sus-root adgangskode
3. Vent på "Ansible Onboarding complete"
```

**Verifikation:**
```bash
# Tjek at kontoen eksisterer
id sus-root

# Tjek SSH-nøgle
ls -la /home/sus-root/.ssh/authorized_keys

# Tjek sudo
sudo -l -U sus-root
```

---

## Anbefalet rækkefølge for moduler

Hvis du kører modulerne enkeltvis, anbefales denne rækkefølge:

```
 1. Domain Join        ← Skal køres først (kræver genstart)
                         ↓ GENSTART
 2. PolicyKit          ← Giver domænebrugere rettigheder
 3. Q-Drive            ← Kræver domæne-credentials
 4. Auto-mount / Pdrev ← Kræver Q-Drive
 5. FollowMe Printers  ← Kræver domæne-credentials
 6. Brother P950NW     ← Uafhængig
 7. Microsoft Defender ← Uafhængig
 8. OneDrive           ← Kræver domæne-brugernavn
 9. Software           ← Uafhængig
10. RDP (xrdp)         ← Uafhængig (kun Ubuntu)
11. Ansible Onboarding ← Bør køres sidst
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
org.onlyoffice.desktopeditors    # Office suite
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

## Netværkskrav

Følgende netværksadgang er nødvendig under opsætning:

| Tjeneste | Adresse | Port |
|----------|---------|------|
| Active Directory | `WIN.DTU.DK` | 389, 636, 88, 464 |
| Filserver (Q-Drive) | `<fileserver>` / `<qumulo-server>` | 445 |
| Printserver | `konfigureret via site.conf` | 445 |
| Defender onboarding | `<defender-server>` | 443 |
| Flathub | `dl.flathub.org` | 443 |
| Snap Store | `api.snapcraft.io` | 443 |
| Microsoft repos | `packages.microsoft.com` | 443 |
| OneDrive | `login.microsoftonline.com` | 443 |

---

## Fejlsøgning

### Generelt

| Problem | Løsning |
|---------|---------|
| GUI starter ikke | `python3 -c "from PyQt6.QtWidgets import QApplication"` — installer PyQt6 |
| pkexec fejler | Installer `policykit-1` (Ubuntu) eller `polkit` (openSUSE) |
| Forkert distro detekteret | Tjek `/etc/os-release` |
| Script not found | Tjek at scripts er i `/opt/dtu-sustain-setup/scripts/<distro>/` |

### Domain Join

| Problem | Løsning |
|---------|---------|
| "Domain not found" | Tjek DNS: `nslookup WIN.DTU.DK` |
| "Failed to join" | Tjek admin-bruger har join-rettighed |
| Domænebruger kan ikke logge ind | Tjek SSSD: `systemctl status sssd` |

### Q-Drive

| Problem | Løsning |
|---------|---------|
| Mount fejler | Tjek credentials og netværk: `smbclient -L //<fileserver> -U <username>` |
| "Permission denied" | Tjek `/etc/fstab` entries og credentials-fil |

### Cisco VPN

| Problem | Løsning |
|---------|---------|
| "Tarball not found" | Placer `cisco-secure-client-linux64-*.tar.gz` i repo-roden eller vælg via Browse |
| NVM fejler | Forventet på nye kerner — Cisco-begrænsning, kan ignoreres |
| VPN virker ikke | Tjek `libxml2.so.2` er installeret |

### OneDrive

| Problem | Løsning |
|---------|---------|
| Sync starter ikke | Kør `systemctl --user status onedrive` som brugeren |
| Login fejler | Åbn URL manuelt i browser, log ind med DTU-konto |

---

## Kontakt

- **Team:** DTU Sustain IT
- **E-mail:** support@sustain.dtu.dk
- **Repository:** https://github.com/DTU-Sustain/DTU-Umbrella
