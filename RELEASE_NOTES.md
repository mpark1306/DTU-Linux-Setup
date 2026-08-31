## Ikke udgivet endnu

### Ny funktionalitet

- **Domain Join gør nu login markant hurtigere.** Indholdet af det løse
  `Speedup_Login.sh` er flyttet ind i modulet, hvor det hører til: så gælder
  det også for maskiner der ikke er kommet fra imaget, og det kan ikke længere
  komme i karambolage med resten.

  Det løse script kunne ikke bare køres som det var. Det skrev
  `services = nss, pam` tilbage i `sssd.conf` — netop den linje der blev
  fjernet i v1.4.0, fordi SSSD's monitor på 24.04 kappes med systemd om nss-
  og pam-socket'en og crash-looper. Kørte man Speedup efter Domain Join, var
  fejlen tilbage. Den linje fjernes stadig.

  **Kerberos.** Uden en KDC-liste slår klienten realmet op via DNS SRV ved
  hver billet. Er `SITE_AD_KDCS` sat i `site.conf`, skrives KDC'erne ind i
  `krb5.conf`, og `dns_lookup_kdc`/`dns_lookup_realm` slås fra sammen med
  `rdns`. De to ting hænger uløseligt sammen: slås opslaget fra uden
  kdc-linjer, kan klienten ikke finde en KDC overhovedet, og hvert login
  fejler. Er variablen tom, røres `krb5.conf` ikke.

  **SSSD.** `ad_enable_gc=False`, `ldap_use_tokengroups=False`,
  `ldap_group_nesting_level=0` og `enumerate=False` stopper den fulde
  gruppetræ-gennemgang ved hvert login, som var der de flersekunders-pauser
  kom fra. `ignore_group_members=True` i `[nss]` sparer opslag af hvert enkelt
  medlem af de store AD-grupper. `ad_gpo_access_control=permissive` henter
  ikke længere GPO'er ved hvert login og nægter adgang når de ikke kan læses.

  **Cachen tømmes** ved omkonfiguration. Ellers slår de nye indstillinger
  først igennem efterhånden som gamle poster udløber — hvilket ved fire timer
  ikke er noget nogen sidder og venter på.

- **`SITE_AD_KDCS`** og **`SITE_AD_ACCESS_PROVIDER`** er nye, valgfrie
  variabler i `site.conf`. Begge er tomme som default.

### Ændringer

- **`entry_cache_timeout` er hævet fra 300 til 14400 sekunder** (5 minutter →
  4 timer), sammen med `entry_cache_user_timeout` og
  `entry_cache_group_timeout`. Et login på en varm cache laver dermed ingen
  LDAP-rundtur.

  Prisen skal kendes: en ændring i AD — især et gruppemedlemskab, og det er
  gruppemedlemskab der giver sudo og polkit-rettigheder — kan tage op til fire
  timer om at nå maskinen. `sudo sss_cache -E` tømmer cachen med det samme.

- **`access_provider` sættes ikke.** `Speedup_Login.sh` satte `permit`, som
  lader enhver domænebruger logge ind. Det er en adgangsbeslutning, ikke en
  hastighedsindstilling, så den skal skrives eksplicit i `site.conf` som
  `SITE_AD_ACCESS_PROVIDER="permit"` for at gælde.

- **`ldap_id_mapping` overskrives ikke længere**, hvis den allerede står i
  `sssd.conf`. Den afgør om UID'er beregnes ud fra AD-SID'en eller læses fra
  POSIX-attributter; ændres den på en maskine der allerede er joinet,
  omnummereres hver eneste domænebruger, og deres hjemmemapper bliver
  forældreløse.

- **TPM2-modulet laver ikke længere en recovery-nøgle.** Det tilføjede en ny
  LUKS-keyslot og skrev en ukrypteret disknøgle til en fil. Modulet rører nu
  ikke ved de eksisterende nøgler: den adgangskode disken blev krypteret med
  ved installationen er uændret og fortsat gyldig, og den dækker allerede det
  behov en recovery-nøgle skulle dække — hvis TPM2-oplåsningen holder op med at
  virke efter en firmwareændring, taster man sin adgangskode og kører modulet
  igen.

  Auto-unlock virker uændret. Clevis tilføjer stadig sin egen keyslot med den
  TPM-forseglede nøgle — det er den mekanisme oplåsningen bygger på — men intet
  eksisterende nøglemateriale ændres eller erstattes.

  `DTU_TPM2_RECOVERY_KEY` er dermed væk; den styrer ikke længere noget.

---

## v1.5.1 — 24. august 2026

### Ny funktionalitet

- **TPM2-modulet viser nu hvad der mangler, før det forsøger noget.**
  Forudsætningerne for TPM2-oplåsning kan brugeren ikke gøre noget ved inde fra
  programmet: TPM'en skal være slået til i firmware, disken skal have været
  krypteret ved installationen, og Secure Boot skal stå i sin endelige tilstand
  **før** enrollment, ikke efter. Hidtil viste alle tre sig som en fejlet
  modulkørsel — og rækkefølgen omkring Secure Boot viste sig slet ikke, men
  som en maskine der holdt op med at låse op efter næste firmwareændring.

  `tpm2-enroll.sh --check` kører nu forudsætningerne som ren læsning og
  udskriver én struktureret linje pr. fund, med status og — hvor der er noget
  at gøre — hvad man gør. En ny dialog kører den før enrollment og viser
  resultatet som en liste. Et blokerende fund deaktiverer Fortsæt.

  Tjeklisten ligger i scriptet, ikke i GUI'en. Ét sted skal vide hvad TPM2
  kræver; en kopi i Python ville være den der driver fra virkeligheden.

  `--check` kører **uden root**, så man opdager at maskinen ikke har en TPM før
  man bliver bedt om en adgangskode. De to punkter der reelt kræver root — en
  eksisterende binding, og om clevis er i initramfs — melder sig som ukendte, og
  dialogen tilbyder at køre resten med rettigheder frem for at lade som om alt
  er kontrolleret.

### Rettelser

- **TPM2-modulet afbrød med exit 1 på maskiner der allerede havde en binding.**
  Linje 164 i `tpm2-enroll.sh` var en bar `read -rp`, og modulet kører fra
  GUI'en gennem `pkexec bash -s`, hvor scriptet selv er stdin. Når det er læst
  står stdin på EOF, så `read` returnerer 1 med det samme, og `set -e` tager
  hele kørslen ned.

  `prompt_secret` havde allerede løst det for LUKS-adgangskoden — env var, så
  TTY, så zenity, så `systemd-ask-password`. De tre øvrige prompts fik aldrig
  samme behandling og ville alle fejle på samme måde: valg mellem flere
  LUKS-partitioner (linje 133), ekstra binding (164) og recovery-nøgle (218).

  De går nu gennem `ask_yes_no`, som respekterer en miljøvariabel, spørger
  interaktivt hvis der er en TTY, og ellers tager en dokumenteret default og
  skriver i loggen hvilken den tog. Enhedsvalget kan ikke defaultes forsvarligt
  og fejler i stedet med navnet på den variabel der skal sættes.

  Default for en ekstra binding er nej — disken låser allerede op fra TPM'en,
  og endnu en identisk binding bruger blot en keyslot. Default for
  recovery-nøglen er ja: TPM2-oplåsning holder op med at virke hvis firmware
  eller Secure Boot-tilstand ændrer sig, og den ekstra nøgle er forskellen på
  en genstart og en geninstallation.

  `DTU_LUKS_DEVICE`, `DTU_TPM2_REBIND` og `DTU_TPM2_RECOVERY_KEY` genkendes nu
  af env-indlæseren og sendes videre fra GUI'en, så de kan sættes fra en
  env-fil.

- **Recovery-nøglen blev skrevet til en uforudsigelig mappe.** Filen gik til
  `./`, som under `pkexec` fra GUI'en kan være hvad som helst, og den blev
  oprettet med den gældende umask og først `chmod 600` bagefter — et vindue
  hvor en ukrypteret disknøgle var læsbar for andre. Den oprettes nu lukket med
  `install -m 600` i hjemmemappen hos den bruger der startede modulet.

---

## v1.5.0 — 24. august 2026

### ⚠️ Brydende ændring: moduler stopper ved manglende site-konfiguration

Tidligere havde `load_site_conf()` i `common.sh` placeholder-værdier som defaults
— `SITE_FILE_SERVER` faldt tilbage til den bogstavelige streng `<fileserver>`,
`SITE_PRINT_SERVER` til `konfigureret via site.conf`. Manglede `site.conf`, kørte
modulet derfor videre og forsøgte at mounte `//<fileserver>/Qdrev/SUS`. Det var
den fejl der gjorde 2026.07.01-imaget ubrugeligt.

Nu gælder:

- Værdier der identificerer konkret infrastruktur har **ingen default**.
- Enhver værdi der indeholder `<vinkelparenteser>` behandles som placeholder og
  tømmes aktivt ved indlæsning.
- Hvert modul erklærer sit behov med `site_require`, og stopper med en besked
  der navngiver den manglende variabel og viser hvordan den sættes.

| Modul | Kræver nu |
|---|---|
| Network Drives, `repair-pdrive.sh` | `SITE_FILE_SERVER` |
| Printers (Sustain-grenen) | `SITE_PRINT_SERVER` |
| Microsoft Defender | `SITE_DEFENDER_ONBOARDING_URL` |
| PolicyKit | `SITE_AD_ADMIN_GROUP` |

**Konsekvens:** en maskine uden `/etc/dtu-setup/site.conf` — som hidtil fik
Sustain-defaults stiltiende — vil nu få en fejl fra disse fire moduler. Det er
tilsigtet. Installér den rette profil først (se README, afsnittet
"Site-konfiguration").

### Sikkerhed

- **pkexec-wrapperen skrives ikke længere til disk.** Både `module_runner.py` og
  `dtu-first-login.sh` sendte wrapper-scriptet til en fil i `/tmp` (ejet af den
  ualmindelige bruger) og lod root eksekvere den *efter* PolicyKit-prompten. I
  det vindue kunne en anden proces under samme bruger udskifte indholdet og få
  egen kode kørt som root. Wrapperen sendes nu på stdin til `pkexec bash -s`.
  Det fjerner både tidsvinduet og kodeordet fra filsystemet.
  PolicyKit-action'en er annoteret på `/usr/bin/bash` og er uændret.
- **Legacy credential-fil ryddes op.** Se "Rettelser" nedenfor.
- **Interne værdier fjernet fra kørende kode.** Scrubbingen havde efterladt tre
  forekomster i selve koden, ikke kun i skabeloner:
  - `common.sh` brugte et hardkodet internt share-navn som faktisk værdi i
    `sustain_pick_target`. Det er flyttet til to nye site-variabler,
    `SITE_SUSTAIN_Q_SHARE_QUMULO` og `SITE_SUSTAIN_P_SUBPATH_QUMULO` (sidstnævnte
    afledes af den første hvis den ikke sættes). Qumulo-stien bruges nu kun når
    både host og share er konfigureret — ellers falder modulet tilbage til
    DFS-roden i stedet for at mounte en gættet sti.
  - `opensuse/qdrive.sh` ryddede gamle fstab-linjer ud fra et hardkodet internt
    værtsnavn; reglen afledes nu af konfigurationen.
  - En kommentar i `opensuse/polkit.sh` navngav AD-admingruppen direkte.
- **Afdelingsprofilerne er fjernet fra repoet.** `examples/dtu-ait.env` og
  `examples/dtu-sustain.env` indeholdt AD-admingrupper og distribueres
  out-of-band, hvilket README allerede påstod. Kun de generiske skabeloner
  (`data/site.conf.example`, `examples/dtu-runtime.env.example`) følger med
  pakken nu. Historikken indeholder stadig værdierne — se noten nedenfor.

> **Bemærk om git-historikken:** værdierne ligger fortsat i tidligere commits
> (49 commits, 15+ filstier). En omskrivning kræver `git filter-repo` og et
> force-push der brækker alle eksisterende kloner. Værktøj og afvejning er
> forberedt separat og køres ikke automatisk.


### Rettelser

- **Scrub-artefakter i kørende kodestier.** En søg-erstat havde efterladt
  placeholder-tekst som faktiske værdier flere steder:
  - `qdrive.sh` (Ubuntu + openSUSE) skrev Sustain-brugerens CIFS-credentials til
    den bogstavelige sti `/home/<bruger>/.smbcred-<fileserver>`. Filnavnet
    udledes nu af `SITE_FILE_SERVER` via de nye helpers `cifs_creds_file` /
    `cifs_creds_file_resolve` i `common.sh`. Maskiner sat op med v1.4.0 eller
    tidligere læses stadig korrekt (fallback), og den gamle fil — der indeholder
    kodeordet i klartekst — slettes når den nye er skrevet.
  - `reset-test-user.sh` forsøgte at fjerne fstab-linjer der matchede den
    bogstavelige streng `smbcred-<fileserver>`; den matcher nu `.smbcred-`
    generelt, så oprydningen faktisk virker.
  - `opensuse/qdrive.sh` ryddede gamle fstab-linjer med `/<fileserver>.*[Qq]drev/`,
    som aldrig matchede en rigtig linje — den bruger nu `$SITE_FILE_SERVER` og
    beholder den gamle regel som ekstra oprydning.
  - Rettet i `site.conf.example`, `examples/dtu-ait.env`, `error_dialog.py`,
    `docs/GUIDE.md` og en kommentar i `ubuntu/qdrive.sh`.
- **GUI'en viste forkert version.** `__version__` stod på `1.2.1` mens pakken var
  1.4.0; strengen vises i vinduets header. Rettet, og `make check-version`
  (kørt i CI) fejler nu hvis `Makefile`, `pyproject.toml` og `__init__.py` er
  uenige.
- **WiFi-modulet fik ikke `DTU_DEPARTMENT`** ved første login, så
  `load_site_conf()` ikke kunne vælge afdelingsprofilen. Tilføjet.
- `sustain_write_fstab()` tager nu backup af `/etc/fstab` før den skriver. Den
  kaldes af `dtu-drives-reselect.sh` fra en NetworkManager-hook, altså
  uovervåget ved hvert netværksskift.
- Rettet forkert repo-navn i `SECURITY.md`s link til sårbarhedsrapportering,
  samt en henvisning til variablen `SITE_ADMIN_GROUP` (hedder
  `SITE_AD_ADMIN_GROUP`) og til et "Ansible Onboarding"-modul der ikke findes.

### Mørkt tema

- **GUI'en er nu læsbar på et mørkt skrivebord.** Farverne stod som hex-litteraler
  spredt ud over widget-koden og var alle valgt til et lyst tema; på mørk Plasma
  betød det mørkegrå tekst på systemets mørke baggrund. Titlen i DTU-rød
  (`#990000`) mod en mørk vinduesbaggrund giver et kontrastforhold på ca. 2:1 —
  langt under det læsbare.
- Alle farver kommer nu fra `src/dtu_sustain_setup/theme.py`, som har ét navngivet
  token pr. rolle og to komplette sæt værdier bag dem. Hvilket sæt der bruges
  afgøres én gang ved opstart ud fra applikationens egen Qt-palet, så værktøjet
  følger skrivebordet i stedet for at påtvinge et udseende.
- DTU-rød findes som to tokens, ikke ét: `accent` er et fyld der altid bærer hvid
  tekst, `accent_text` er den samme røde justeret så den kan læses *som tekst* på
  den aktuelle baggrund. Det er netop den skelnen der manglede før.
- `DTU_SETUP_THEME=dark|light` tvinger et tema — til test, og til de tilfælde hvor
  en distro rapporterer sin palet forkert.
- Temaet slår ikke om mens vinduet er åbent. Et skift af skrivebordstema kræver en
  genstart af værktøjet.

### Opdeling af `main_window.py`

Filen var på 1.050 linjer og blandede modulkatalog, farver, kø-logik, dialoger og
UI-opbygning. Den er nu på ca. 780 linjer og handler om at bygge og forbinde UI.
Fire moduler er trukket ud, alle uden vinduestilstand:

| Modul | Indhold |
|---|---|
| `modules.py` | `ModuleDef` + kataloget over de 15 moduler |
| `theme.py` | Farvepaletten, lys og mørk |
| `batch.py` | Køen bag de to "Run All"-knapper |
| `prompts.py` | Hvilken dialog et modul kræver, og hvornår en env-fil erstatter den |

En reel fejlkilde forsvandt undervejs: køen lå i attributter som `_run_all_admin`
oprettede dovent, så enhver læser skulle gardere med
`hasattr(self, "_queued_modules")` først. Glemte man det én gang, rejste Run All
`AttributeError` på et friskt vindue. `BatchQueue` findes altid og fjerner
spørgsmålet.

Reglerne om hvilke moduler en samlet kørsel må røre — og hvorfor TPM2 aldrig må
køre som sidegevinst — står nu ét sted i `batch.py` frem for i en lokal mængde
inde i metoden.

### Test

- **Første automatiserede tests i projektet.** `make test` kører uden root og
  uden netværk:
  - `tests/test_site_conf.sh` — 25 assertions mod site-konfigurationslaget:
    placeholder-detektion, at ægte værdier overlever, at `site_require` faktisk
    stopper modulet og navngiver variablen, at credential-stien ikke indeholder
    placeholders, og at `sustain_pick_target` aldrig gætter en share-sti.
  - `tests/test_env_loader.py` — 10 unittests mod env-parseren, herunder at et
    kodeord med mellemrum, apostroffer og `$` overlever parsing intakt, og at
    ingen hemmelig variabel optræder i klartekst i `summary()`.
- **Spærre mod tilbagefald:** `tests/check-no-internal-values.sh` fejler
  bygget hvis en commit lægger konkret DTU-infrastruktur i en tracket fil.
  Den bygger på struktur frem for en blokliste — en liste over de interne
  værdier ville i et offentligt repo udgive præcis det den skal holde ude.
  Tre regler: `SITE_*` må kun tildeles godkendte defaults eller
  `<placeholders>`; kun offentligt annoncerede `*.dtu.dk`-værtsnavne må
  optræde; og mount-mål skal sættes fra konfiguration, aldrig fra literaler
  (også når værdien står i enkelte anførselstegn — det var netop sådan det
  hardkodede Qumulo-share slap igennem). Verificeret mod alle seks historiske
  regressioner plus seks lovlige mønstre: 13/13.
  - `tests/test_theme.py` — 10 tests der **måler** WCAG-kontrast for hvert
    forgrund/baggrund-par UI'en rent faktisk tegner, i begge temaer. Det er
    afgørende at det er en måling og ikke et øjekast: testen fandt tre reelle
    fejl ved første kørsel, hvoraf de to sad i den *eksisterende* lyse palet
    (fejl-rammen på et kort var 2,58:1 mod vinduet, under de 3:1 en ramme der
    bærer betydning skal have). Rammer der kun pynter holdes mod en lavere
    tærskel end rammer der skelner succes fra fejl; begrundelsen står i testen.
  - `tests/test_batch.py` — 21 tests mod kø-reglerne: at TPM2 aldrig havner i en
    samlet kørsel, at en afbrudt admin-kørsel ikke tilbyder genstart, at
    `reset()` rydder det delte miljø så et domænekodeord ikke overlever kørslen,
    og at en frisk `BatchQueue` kan bruges uden `start()`.
  - `tests/test_main_window_smoke.py` — bygger hele vinduet under offscreen Qt i
    både lyst og mørkt tema og fejler på enhver hex-farve der ikke er et
    palet-token. En forkert formateret Qt-stylesheet kaster ikke en exception —
    Qt dropper reglen i stilhed og widget'en renderes ustylet — så testen
    kontrollerer også at ingen f-string-parenteser er sluppet uopløst igennem.
    Begge fejltyper er verificeret ved at injicere dem.
- Testfixtures bruger den reserverede `.invalid`-TLD, så `tests/` kan scannes
  af spærren i stedet for at være undtaget.
- Testene og spærren kører i CI som en del af `lint`-jobbet. Lint-jobbet
  installerer nu offscreen-Qt så vindues-røgtesten faktisk kører der; er PyQt6
  utilgængeligt springer testen sig selv over frem for at fælde bygget.

### Oprydning

- **Fjernet OneDrive-modulet** (`scripts/ubuntu/onedrive.sh` +
  `scripts/opensuse/onedrive.sh`, 422 linjer). Der har ikke været nogen
  `ModuleDef` for det, så det kunne ikke nås fra GUI'en; de eneste spor var en
  forældet id i `DEFERRED_MODULES` og to linjer i READMEs filstruktur.
  Pakkebeskrivelserne nævner det ikke længere.
- Fjernet ubrugte variabler `HOME_DIR` (`repair-pdrive.sh`) og `PPD_MODEL`
  (`opensuse/followme.sh`).
- **Fjernet `scripts/deploy-sync.yml`** — Ansible-playbook der ikke blev
  refereret fra README, Makefile eller nogen kodesti.
- Rettet `setup-sync-homedir.sh`, som omtalte sig selv ved et gammelt filnavn.

### Byg og CI

- **Nyt lint-job** der kører på hvert push og pull request — ikke kun ved
  release. `build-deb` og `build-rpm` afhænger nu af det. Jobbet kører
  `make check-version`, `shellcheck --severity=warning` på alle 32 scripts, og
  byte-compiler Python og kører smoke-testene. Træet er rent på det niveau i dag.
- Nye targets: `make lint`, `make check-version` og `make test`.
- README's install-eksempler slår nu nyeste version op via GitHub API i stedet
  for at hardkode et versionsnummer der bliver forældet.
- README dokumenterer nu modul 15 (**Repair Home Folders**, tilføjet i v1.4.0)
  og det korrekte modultal: 15 i alt, 14 synlige.

---

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
