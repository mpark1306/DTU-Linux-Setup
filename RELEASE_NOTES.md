## v1.4.0 — 20. august 2026

### Rettelser
- **SSSD nss/pam socket-activation crash-loop** rettet i `domain-join.sh` for både Ubuntu og openSUSE — `services=`-linjen fjernes fra `sssd.conf`, og `sssd-pac.socket`/`.service` deaktiveres, så de ikke længere fejler ved hver realm join.
- **Microsoft Defender Network Protection** fejlede permanent med "unsupported release ring" på Production-kanalen — `NP_MODE` default ændret fra `audit` til `disabled` i `defender.sh` (Ubuntu + openSUSE).
- **PolicyKit domain-user-reglen** (`48-domain-users.rules`) matchede kun `"Domain Users"` med stort forbogstav — SSSD kan resolve AD-gruppen som `"domain users"` (småt), hvilket gjorde reglen virkningsløs for nogle brugere. Rettet i `polkit.sh` (Ubuntu + openSUSE) og xrdp color-manager-reglen i `rdp.sh`.
- `load_site_conf()` i `common.sh`: kalderens `DTU_DEPARTMENT`-værdi (fra GUI/env-fil) vinder nu altid over en eventuel værdi i `site.conf`, i stedet for at blive overskrevet.
- Fjernet en fejlagtig Homebrew-installation fra `dtu-first-login.sh`, som blev forsøgt kørt ved hver ny brugers første login.
- Fjernet to forældede, ubrugte monolitiske scripts (`dtu-setup-ubuntu.sh`, `dtu-setup-opensuse-tw.sh`) som ikke længere blev refereret nogen steder og var drevet ud af sync med de rigtige moduler.
- Normaliseret executable-bit på alle scripts under `bin/` og `scripts/`.

### Ny funktionalitet
- **Nyt modul: "Repair Home Folders"** (`repair-user-folders.sh`) — retter ødelagte Desktop/Documents/Pictures-symlinks fra tidligere installationer og fjerner dubletter i fstab.
- **Qumulo-direct/DFS-root fallback** til Sustain Q-Drive/P-Drive — nye delte helpers `cifs_host_up`, `sustain_pick_target` og `sustain_write_fstab` i `common.sh`, samt `scripts/dtu-drives-reselect.sh` og `scripts/deploy-drives-autoswitch.sh`, der automatisk vælger det rigtige filserver-mål afhængigt af netværk (DTUSecure/VPN vs. kablet), og `scripts/repair-pdrive.sh` til manuel gendannelse.

## v1.3.0 — 15. juli 2026

### Ny funktionalitet
- **Card-baseret UI** i setup-vinduet — moduler præsenteres nu som kort med ikon og beskrivelse i stedet for en flad liste, hvilket giver et mere overskueligt overblik.
- **Nyt script: `scripts/setup-dtu-auto-update_Version4.sh`** — opsætter automatisk opdatering af DTU Linux Setup.
- **Delte CIFS mount-helpers i `scripts/common.sh`** — `cifs_test_mount`, `cifs_setup_share`, `cifs_find_mdrive_subdir` og `cifs_start_automount` er nu fælles for alle profiler og distroer.
- **Nye site-variabler**: `SITE_MDRIVE_SERVER` og `SITE_MDRIVE_BASE` til central konfiguration af M-Drive-serveren.

### Forbedringer
- **AIT qdrive.sh (Ubuntu + openSUSE)** refaktoreret — bruger nu de delte CIFS helpers; forbedret fejlhåndtering, fstab-backup og bruger-feedback under mounting.
- **TPM2-enroll** understøtter nu passphrase via miljøvariablen `DTU_LUKS_PASSPHRASE`, så enrollment kan køres ikke-interaktivt.
- `DTU_LUKS_PASSPHRASE` markeret som sensitiv variabel i `env_loader.py` (maskeres i logning).
- Opdaterede eksempelfiler: `data/site.conf.example`, `examples/dtu-ait.env`, `examples/dtu-sustain.env`.
