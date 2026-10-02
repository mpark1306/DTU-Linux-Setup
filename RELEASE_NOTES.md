## v1.8.1 (2. oktober 2026)

### Sikkerhed

- **Defenders onboarding-script kontrolleres foer det koeres som root.** Det
  hentes fra en intern server og koeres med fulde rettigheder, samme slags
  hul som installationsvejene havde. `SITE_DEFENDER_ONBOARDING_SHA256` i
  `site.conf` laaser det fast; `site.conf` foelger med imaget, altsaa en
  anden kanal end serveren. Passer det ikke, koeres scriptet ikke. Er
  vaerdien tom, koeres det med en advarsel, og modulet skriver den checksum
  det fik, saa den kan udfyldes.

- **En mislykket onboarding melder ikke laengere succes.** Kaldet havde
  `|| true`, saa en maskine med Defender installeret men ikke tilmeldt
  organisationen saa helt normal ud. Nu stopper modulet, og til sidst
  kontrolleres `mdatp health --field licensed`, mdatp's eget svar paa om
  tilmeldingen lykkedes.

### Rettet

- **Defender-modulet fejlede efter opgradering til 26.04.** Det slettede
  `/etc/apt/sources.list.d/microsoft-prod.list` og installerede derefter
  `packages-microsoft-prod`. Filen er en konfigurationsfil i den pakke. Ved en
  ny version af pakken, som efter en opgradering fra 24.04 til 26.04, spurgte
  dpkg, om den skulle laegges tilbage. Modulet har intet tastatur, saa det
  fejlede med "end of file on stdin at conffile prompt" og efterlod pakken
  halvinstalleret. Derefter fejlede alle moduler der bruger apt, indtil der
  blev ryddet op. Det samme sker, hvis opgraderingen selv har rettet i filen.

  Nu installeres pakken med `--force-confnew --force-confmiss`, som aldrig
  spoerger, og modulet stopper, hvis kilden mangler bagefter. Forloebene er
  efterproevet med Microsofts egen pakke i et testtrae. Paa 24.04 og ved
  genkoersel paa samme udgave gjorde sletningen ingen skade, fordi pakkens
  eget installationsscript laegger filen tilbage.

  **Bemaerk for support:** en maskine der har ramt fejlen, rydder op med
  `sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confnew --force-confmiss --configure -a`.

- **Fejldialogen gav forkert diagnose.** Moenstret for "loebet toer for
  hukommelse" matchede "oom" uden ordgraenser, og fandt det i `us.zoom.Zoom`,
  som altid staar i Software-modulets output. Enhver fejl i det modul blev
  derfor meldt som hukommelsesmangel. Det samme gjaldt EIO, EROFS og EPIPE
  inde i andre ord. Nu kraeves ordgraenser.

  Dialogen kender desuden to nye fejl: en pakke der er efterladt
  halvinstalleret ("end of file on stdin at conffile prompt", "dpkg was
  interrupted"), med kommandoen der rydder op, og en generel dpkg-fejl. Den
  foerste rammer alle moduler der bruger apt, indtil der er ryddet op, saa
  den skal kunne genkendes uanset hvilket modul der fejler.

- **Auto Update-modulet fejlede med "warn: command not found".** Scriptet
  kaldte `warn`, som ikke var defineret i det, og under `set -e` stoppede det
  dér med exit 127. Testen der fanger kald til udefinerede hjaelpere,
  daekker nu ogsaa scripts der ikke bruger `common.sh`.

- **CI-trinnet der byggede kildearkivet fejlede paa GitHub.** Kontrollen
  `tar | grep -q` stopper ved foerste traef, tar faar en skrivefejl, og GitHub
  koerer med `pipefail`. Rettet, og CI-trinnene koeres nu selv i testene med
  GitHubs flag.

## v1.8.0 — 30. september 2026

### Sikkerhed

- **Installationsvejene kontrollerer nu det de henter.** `bin/dtu-install.sh`
  og `scripts/update-latest.sh` hentede kode fra GitHub og koerte
  `make install` som root uden nogen kontrol. Nu henter de udgivelsens
  kildearkiv og `sha256sums.txt`, og intet pakkes ud foer de passer sammen.

  Vurderingen sagde at CI allerede lavede `sha256sums.txt`, saa rettelsen bare
  var at hente den. Det holdt ikke: filen daekkede kun `.deb`-pakken, med
  `dist/`-praefiks, og installationsvejene hentede GitHubs automatisk
  genererede arkiv, som ingen checksum daekkede. CI bygger derfor nu selv et
  kildearkiv med `git archive`, og `sha256sums.txt` daekker det med rene
  filnavne.

  **Hvad det beskytter mod, og hvad ikke.** Det fanger en afkortet eller
  oedelagt download og en manipuleret kopi fra en cache eller et spejl. Det
  fanger ikke nogen der kan udskifte baade arkivet og checksumfilen, altsaa en
  kompromitteret GitHub-konto eller en aflytning med et CA maskinen stoler
  paa. Til det kan `SHA256=` laase en checksum fast, som er kommet ad en anden
  vej. Testen daekker den graense eksplicit, saa ingen senere tror at
  checksummen alene er nok.

  Udgivelser til og med v1.7.1 har intet kildearkiv og kan kun installeres med
  `DTU_ALLOW_UNVERIFIED=1`. `BRANCH=` er altid ukontrolleret og siger det
  hoejt. En `SHA256=` sammen med en af dem afvises, fordi en pin der aldrig
  kontrolleres er vaerre end ingen.

- **DTUSecure-profilen skiftes til brugerens egen ved foerste login.**
  Maskinen saettes op af en admin, og WiFi-profilen blev lagt ind med admins
  egne domaeneoplysninger. Foerste login koerte allerede `wifi.sh` med
  brugerens oplysninger, men den slettede kun en profil med ét bestemt navn.
  En profil admin havde lagt ind i Plasmas netvaerksvindue, eller med et
  andet navn, overlevede, og saa havde maskinen to, hvoraf NetworkManager
  kunne vaelge admins.

  Nu oprettes den nye profil foerst og kontrolleres, og **derefter** fjernes
  alle profiler for SSID'et, uanset navn og store og smaa bogstaver. Fejler
  oprettelsen, beholder maskinen den WiFi den har. Til sidst efterproeves det
  at der er praecis én tilbage.

  Identiteten er den konto brugeren er logget ind med, ikke det navn der
  tastes i dialogen, og feltet er forudfyldt med den. Taster brugeren et
  andet navn, roeres WiFi'en ikke, fordi vi ikke kan vide om kodeordet hoerer
  til den indloggede konto.

  **Bemaerk:** profilen er fortsat faelles for maskinen, saa den virker ved
  loginskaermen foer nogen er logget ind. Paa en delt maskine ender den derfor
  i navnet paa den seneste bruger der har haft sit foerste login.

- **WiFi-kodeordet staar ikke laengere i proceslisten.** `wifi.sh` gav det
  som argument til `nmcli`, hvor enhver lokal bruger kunne laese det med
  `ps`, i modstrid med `SECURITY.md`. Profilen skrives nu direkte som
  NetworkManager-fil med kun bash-builtins og `umask 077`. Escapingen er
  testet med GLib's egen keyfile-parser, den samme NetworkManager bruger,
  mod 16 kodeord med backslash, foerende mellemrum, linjeskift, semikolon,
  anfoerselstegn og ikke-ASCII tegn.

- **Serverens certifikat kan nu kontrolleres.** PEAP/MSCHAPv2 uden
  certifikatkontrol betyder at et falsk DTUSecure-accesspoint kan opsnappe
  kodeordshashen. Det stod ikke i vurderingen. `SITE_WIFI_DOMAIN_SUFFIX_MATCH`
  i `site.conf` slaar kontrollen til; den er tom som standard, fordi DTU's
  RADIUS-domaene skal komme fra netvaerksteamet og ikke gaettes, og saa
  advarer modulet hoejt.

- **FollowMe's kodeordsfil er privat fra foerste byte.** Den blev oprettet
  med roots umask, altsaa 0644, og foerst sat til 640 bagefter. Nu `umask 077`
  og en efterkontrol af `root:lp 640`, som `sustain-printers.sh` allerede
  gjorde.

- **Defender henter ikke laengere til faste stier i `/tmp`.** Root
  installerede en `.deb` og koerte et Python-script fra kendte navne i `/tmp`,
  hvor en lokal bruger kan oprette en fil foerst. Nu en privat `mktemp -d`.

- **GUI'ens opdateringsknap installerer nu den nyeste udgivelse.** Dialogen
  lovede "the latest release", men `update-latest.sh` hentede hovedet af
  `main`, som ikke noedvendigvis har bestaaet CI og ikke har nogen checksum.

- **`bin/dtu-deploy-from-github.sh` er fjernet.** Den havde grenen `deploy`
  som standard, og den gren findes ikke laengere paa GitHub, saa scriptet
  virkede ikke. Den klonede desuden fra en `REPO_URL` som miljoeet kunne
  overskrive, og intet kaldte den. `dtu-install.sh BRANCH=` daekker brugen.

Begge fund er fra sikkerhedsgennemgangen 22. september 2026 og er efterproevet
ved direkte laesning af koden.

- **`polkit.sh` fortsatte efter en `visudo`-fejl.** Kontrollen var skrevet som
  `visudo -cf ... || { fail ...; rm -f ...; }`. `rm -f` returnerer 0, saa hele
  `||`-gruppen returnerede 0, `set -e` udloeste ikke, og scriptet koerte videre.

  Konsekvensen var den vaerst taenkelige: ved en syntaksfejl blev den
  **kodeordsbeskyttede** sudo-fil slettet, mens den **prompt-frie** polkit-regel
  blev skrevet bagefter. Gruppen mistede den sikre vej til root og beholdt den
  usikre. Nu stopper scriptet, og ingen polkit-regler skrives.

- **`49-domain-admins.rules` gav AD-admingruppen `YES` paa alle polkit-actions.**
  Uden `subject.local && subject.active`, saa det gjaldt ogsaa over RDP og SSH.
  Da `dk.dtu.sustain.setup.policy` annoterer action'en paa `/usr/bin/bash`,
  daekkede den enhver `pkexec bash ...`: prompt-fri root.

  Reglen er nu snaevret ind til lokale, aktive sessioner og til vaerktoejets
  egen action, `dk.dtu.sustain.setup.*`. Alt andet falder igennem til polkits
  normale `auth_admin`, og vejen dertil er `sudo`, som kraever kodeord og
  allerede er givet i samme script.

  **Admins mister ikke deres daglige rettigheder.** USB, WiFi, pakker og stroem
  ligger i `48-domain-users.rules`, som nu ogsaa daekker admingruppen. Listen
  staar dermed ét sted i stedet for to.

  **Bemaerk for support:** en IT-admin der er koblet ind over RDP eller SSH, vil
  nu blive bedt om sit kodeord for at koere modulerne. Det er tilsigtet. Den
  lokale konsol spoerger ikke.

- **`exec.path` er bevidst IKKE aendret.** Gennemgangen anbefaler at pege den paa
  en konkret wrapper frem for `/usr/bin/bash`. Det ville braekke
  `pkexec bash -s`, som netop findes for at holde wrapperen ude af filsystemet
  og lukke et TOCTOU-vindue. De to anbefalinger staar i modstrid, og
  begrundelsen plus den rigtige langsigtede rettelse staar nu i `.policy`-filen
  ved siden af annoteringen.

### Rettet

- **Drev-notifikationen laeste brugernavnet ud af en kolonne.**
  `deploy-drives-autoswitch.sh` tog kolonne 3 fra `loginctl list-sessions`.
  Kolonnerne er ikke et stabilt format: 26.04 har faaet LEADER og CLASS, og
  "manager"-sessioner staar nu paa listen ved siden af de rigtige. Nu laeses
  kun sessions-ID'et, og resten spoerges der om med `show-session -p`, som
  `setup-dtu-auto-update_Version4.sh` allerede gjorde. Notifikationen gaar kun
  til grafiske sessioner, de eneste der kan vise den.

- **`tpm2-rebind.sh` kunne ikke skrive sine egne fejlbeskeder.** Scriptet kaldte
  `die` fire steder uden at nogen definerede den, saa under `set -euo pipefail`
  blev hver fejlvej til `die: command not found` og exit 127. Den vaerste var
  afvisningen naar Secure Boot er slaaet fra, altsaa scriptets egen vigtigste
  sikkerhedsbesked: den blev aldrig vist. `die` ligger nu i `common.sh` ved
  siden af `fail`, og den lokale kopi i `tpm2-enroll.sh` er fjernet.

  shellcheck fanger ikke udefinerede funktioner, saa `make lint` og CI var
  groenne hele tiden. Der er nu en test der daekker hele klassen: hver hjaelper
  et script kalder, skal kunne naas.

- **`linux-headers-$(uname -r)` hentede byggemaskinens kerne i en chroot.**
  Begge kaldsteder forgrener nu paa `in_chroot` og bruger
  `linux-headers-generic` naar de koerer under imagebygningen.

- **`first-login-deploy.sh` skrev en fil ingen laeste.** Trinnet lagde
  `/etc/skel/.dmrc` for at saette X11 som standard for nye brugere. `~/.dmrc`
  laeses af GDM og LightDM; imaget koerer SDDM, som holder sin egen tilstand og
  styres af `login-screen.sh`'s `RememberLastSession=true`. Trinnet er fjernet,
  og scriptet rydder nu op efter sig selv paa maskiner der allerede har filen,
  men kun hvis indholdet er praecis de to linjer vi selv skrev.

  26.04 staver sessionsfilen `plasmax11.desktop` med lille x. At rette
  stavningen ville have faaet doed kode til at se vedligeholdt og
  26.04-efterproevet ud.

- **`make test` kunne ikke fejle paa trin 3.** Linjen roerte `unittest` gennem
  `tail -5`, saa exitstatus var `tail`s. Det er verificeret at trin 3 nu
  propagerer.

### Nyt

- **Én gren koerer paa baade 24.04 og 26.04.** `common.sh` har tre nye
  hjaelpere, `os_release_value`, `ubuntu_version` og `version_at_least`, plus
  `in_chroot`. De er det ene sted der kender udgaven, i stedet for et
  `. /etc/os-release` spredt ud over scriptene. Sammenligningen er numerisk per
  felt, saa `24.10` sorterer rigtigt mellem `24.04` og `26.04`, og `10#`-
  praefikset betyder at et felt som `09` ikke laeses som oktal.

- **`policykit-1` er skiftet til `polkitd` og `pkexec`.** Pakken findes ikke paa
  26.04, og de to findes paa begge udgaver, saa det kraever ingen forgrening.
  Det er ogsaa den aerligere afhaengighed: GUI'en bruger `pkexec` direkte, og
  `polkitd` er den der haandhaever reglerne modulerne installerer.

- **RDP overlever flytningen af `startplasma-x11`.** Den ligger i
  `plasma-session-x11` paa 26.04, som `kubuntu-desktop` ikke traekker ind.
  Modulet installerer den nu paa 26.04 og efterproever til sidst at en
  sessionsstarter faktisk findes, saa en manglende session bliver en fejl paa
  stedet frem for en sort skaerm uger senere. `startwm.sh`-faldbacken
  `exec xterm` er vaek: xterm er ikke i imaget, saa den doede tavst.

- **`login-screen.sh` afviser nu FOER den skriver noget.** Modulet goer
  brugerlisten tom og hviler paa at temaet selv skifter til et navnefelt. Det
  staar i temaets QML og kan aendre sig med en udgivelse, saa nu efterproeves
  det mod den QML der faktisk ligger paa maskinen, og temaet oploeses som SDDM
  selv goer det: paa en provisioneret maskine siger `default.conf` "kubuntu" og
  `kde_settings.conf` "ubuntu-theme", og den sidste vinder.

  Holder invarianten ikke, skrives der intet. Maskinen beholder standard-SDDM,
  den lokale konto staar paa listen, og nogen kan komme ind og rette det. Efter
  skrivningen efterlignes SDDM's egen brugerliste, og er der én konto tilbage i
  intervallet, rulles konfigurationen tilbage frem for at efterlade en
  loginskaerm uden navnefelt.

  Modulet advarer ogsaa hvis temamappen ikke ejes af en pakke. Det er
  tilfaeldet paa en maskine hvor nogen har aabnet Systemindstillinger ->
  Loginskaerm: temaet er da en kopi som apt aldrig opdaterer, og som derfor kan
  blive ved at virke ved et tilfaelde efter en opgradering.

- **`defender.sh` doer ikke laengere paa en 404.** Microsoft udgiver ikke en
  config-mappe for en ny Ubuntu-udgivelse med det samme, saa modulet falder nu
  tilbage til den nyeste der findes og siger det hoejt.

- **`domain-join.sh` har faaet en vagt om `services =`.** Baade 24.04 og 26.04
  socket-aktiverer nss/pam-responderne, saa linjen skal fortsat slettes.
  Fjernede en udgivelse den socket-aktivering, ville en sletning efterlade
  maskinen uden responder, og ingen domaenebruger kunne slaas op: samme udfald
  som den crash-loop sletningen loeser, naaet fra den anden side. Der spoerges
  nu om unitfilerne findes, og begge grene er daekket af tests.

- **CI er pinnet til `ubuntu-24.04`.** `ubuntu-latest` ruller selv videre til
  26.04 og ville aendre hvad der testes paa et tidspunkt ingen har valgt.

- **Programmet taler engelsk.** Alt brugeren møder er lagt om: GUI'en,
  fejldialogen med dens 55 diagnoser og forslag, velkomstdialogen ved første
  login, TPM2-dialogen og -beskederne, notifikationerne om netværksdrev,
  genstartsvarslerne fra auto-update, og den konsoloutput modulerne skriver i
  logruden. Baggrunden er praktisk: flere af dem der skal bruge maskinerne,
  læser ikke dansk.

  Fejldialogens 55 regulære udtryk er uændrede, og det er efterprøvet
  maskinelt frem for påstået: mønstrene blev trukket ud med `ast` før og efter
  oversættelsen og sammenlignet. Kun titler og forslagstekster er rørt.

  **Kommentarer i koden og dokumentationen er stadig på dansk.** De er til os,
  ikke til brugerne, og en oversættelse af dem ville fordoble ændringen uden
  at løse det problem der blev meldt.

  To .desktop-poster havde i forvejen både `Name=` og `Name[da]=`. Det er den
  rigtige måde, og de er derfor urørte: skrivebordet vælger selv efter
  maskinens sprog.

- **Brugeren vælger tastaturlayout ved første login, og valget gælder også
  loginskærmen.** 16 layouts, med maskinens nuværende valgt på forhånd.

  Trinnet ligger **før** brugernavn og kodeord. Taster man sin domænekode
  gennem et forkert layout, afviser serveren den, og intet på skærmen
  forklarer hvorfor: feltet viser prikker uanset hvad. Lagde vi spørgsmålet
  efter, ville vi have bygget netop den fælde.

  Layoutet sættes systemvidt med `localectl set-x11-keymap`, som skriver
  `/etc/default/keyboard` og `/etc/X11/xorg.conf.d/00-keyboard.conf`. Den
  sidste er den X-serveren læser, og SDDM kører på X, så loginskærmen får
  samme layout. Havde vi sat det i KDE's egne indstillinger i stedet, ville
  sessionen være rigtig og loginskærmen blive stående på det gamle, og det er
  den halvdel der tæller når man taster et kodeord man ikke kan se.

  Domænebrugere har allerede `org.freedesktop.locale1.set-keyboard` gennem
  PolicyKit-modulet, så på en færdig maskine sker det uden en eneste
  rettighedsprompt. Er reglerne ikke på plads endnu, hvilket netop er
  tilstanden på en maskine der har sit første login, falder scriptet tilbage
  til `pkexec` og skriver de samme to filer selv. Sessionen skiftes med
  `setxkbmap`, så det næste felt brugeren taster i, allerede er rigtigt.

  Annullerer brugeren, beholder maskinen sit layout, og resten af opsætningen
  kører videre.

- **Den lokale administratorkode skiftes ved første login, på Sustain-profilen.**
  Billedet udrulles med den samme lokale kode på hver eneste maskine. Den kode
  er kendt af alle der har sat en maskine op, og den står uændret på maskiner
  der har været i drift i årevis. Ét sted kan den skiftes til noget maskinen
  selv ejer: ved første login, hvor der sidder et menneske foran skærmen.

  Trinnet ligger til sidst i `dtu-first-login.sh`, efter drev, printere og
  WiFi. Brugeren har på det tidspunkt set hvad maskinen er, og har lige tastet
  sin domænekode. Blev der spurgt som det allerførste, ville koden blive valgt
  i blinde og glemt inden frokost.

  Krav til koden: mindst 12 tegn, mindst 3 af de fire tegntyper, ingen
  mellemrum i hver ende, og hverken kontonavnet, brugernavnet eller
  WIN-domænekoden. Det sidste er ikke pedanteri: to konti med samme kode er
  én konto.

  Kontonavnet gættes ikke. `admin-mpark`, `admin-alton` og `administrator` er
  alle set i flåden, så kontoen findes ud fra hvad den er: en lokal konto med
  rigtig skal, UID i brugerintervallet, og ret til at hæve rettigheder. Er der
  flere kandidater og ingen af dem står i `sudo` eller `admin`, springes
  trinnet over i stedet for at skifte kode på den forkerte konto.

  Koden når hverken disk eller proceslinje. Den sendes gennem samme
  `pkexec bash -s`-rør som resten af scriptet bruger, og `chpasswd` læser den
  på sin standardinddata.

  Afbryder brugeren, sker der ingenting, og spørgsmålet kommer igen ved næste
  login. Markøren ligger i `/var/lib/dtu-setup/admin-password-changed` og ikke
  i hjemmemappen: der er én lokal konto på maskinen, ikke én per bruger. Lå
  den i `$HOME`, ville bruger nummer to på en delt maskine blive bedt om at
  sætte en ny kode oven i bruger nummer ets, uden at nogen af dem vidste det.

  **Bemærk for support:** efter dette er den lokale administratorkode
  forskellig fra maskine til maskine, og den kendes kun af brugeren. Skal IT
  kunne hæve rettigheder på en maskine, skal det gå gennem domænet, ikke
  gennem den delte lokale kode.

## v1.7.1 — 15. september 2026

### Nyt

- **TPM2 binder om efter en firmwareopdatering, i stedet for at spørge om
  koden resten af maskinens levetid.** Disknøglen er forseglet i TPM'en bag en
  politik: udlevér den kun hvis PCR 7 stadig har denne værdi. PCR 7 er en
  løbende hash over Secure Boot-tilstanden, og næsten alle BIOS-opdateringer
  medbringer en ny dbx, som måles ind i den. Værdien ændrer sig, TPM'en nægter
  at udlevere nøglen, og initramfs falder tilbage til adgangskode-prompten.

  Intet er i stykker: LUKS er urørt, og adgangskode-nøgleslotten virker. Kun
  seglet passer ikke længere. Windows løser det ved at forsegle igen når
  genoprettelsesnøglen er tastet én gang. Det gjorde vi ikke, så maskinen
  spurgte ved hver eneste opstart derefter, og ingen fik at vide hvorfor.

  Tre dele, med vilje adskilt fordi ingen proces har både root og en grafisk
  session:

  - `dtu-tpm2-watch.service` prøver efter hver opstart at unseale rigtigt, med
    `clevis luks pass`, og skriver en tilstandsfil. Den retter ingenting.
  - `dtu-tpm2-notify.sh` kører i brugerens session og siger det på dansk, én
    gang per hændelse. Beskeden starter med at der ikke er noget galt med
    disken eller koden, fordi det er dét brugeren tror.
  - **TPM2 – Bind om** i GUI'en beder om koden én gang, fjerner den døde
    binding, forsegler mod de nye værdier, og afprøver at det virker.

  To ting den nægter at gøre. Den binder ikke om automatisk: det ville kræve
  at koden lå på maskinen, og så havde en angriber med disken både låsen og
  nøglen. Og den nægter at binde om når Secure Boot er slået fra, fordi PCR 7
  måler netop den tilstand: bindingen ville så låse disken op på en maskine
  uden Secure Boot. En brudt binding er en gene; det ville være en forringelse.

  Den døde binding fjernes før den nye laves. Ellers samler der sig en
  ubrugelig keyslot per firmwareopdatering maskinen har set, og LUKS2 har 32.

### Rettelser

- **Software-modulet fyldte hele disken på en ny maskine.** Rapporteret fra en
  maskine med 465 GB, hvoraf 438 GB lå i `/var/log/dtu-setup/`.

  v1.7.0 rettede et hæng ved at lade Ciscos installere skrive til en logfil i
  stedet for til et rør. Det var rigtigt, men byttede hænget ud med en
  diskfylder. Tre ting manglede et loft på én gang: `yes` leverede uendeligt
  input, logfilen havde ingen størrelsesgrænse, og timeouten var 900 sekunder.

  `posture_install.sh` spørger om en **sti**, ikke om ja eller nej. Den afviser
  "y" og spørger igen. Målt på en attrap med samme adfærd: 16 MB i sekundet,
  altså omkring 29 GB i timen, og hurtigere på en NVMe.

  Fire ændringer:

  - **Kun `vpn` installeres som standard.** Tarballen indeholder også posture,
    nvm, dart og umbrella. Ingen af dem bruges på DTU, og hver enkelt er en
    fremmed interaktiv installer kørt som root. At installere noget vi ikke
    bruger er ikke gratis. `[cisco]`-sektionen i `data/software.conf` navngiver
    nu modulerne; en gammel konfiguration med `cisco-secure-client` betyder
    fortsat det samme.
  - **Input er bundet** til 50 svar. En løkke drevet af input rammer EOF og må
    give op.
  - **Vagthund på logfilen**, standard 50 MB (`DTU_CISCO_MAX_LOG`). Den fanger
    en installer der looper uden at læse input, hvilket bundet input ikke gør.
  - **Kun halen af loggen læses** til GUI'en. `cat "$MODULE_LOG"` i en variabel
    var den anden ubundne læsning i samme løkke.

  Logge ældre end 30 dage ryddes ved hver kørsel.

## v1.7.0 — 14. september 2026

### Nyt

- **Microsoft 365 som PWA-genveje i stedet for en snap.** `office365webdesktop`
  var en indpakket browser fra en beta-kanal, kørende ved siden af den browser
  maskinen allerede har. `scripts/install-ms-pwa.sh` skriver i stedet
  almindelige `.desktop`-genveje, der åbner de samme apps i Ungoogled
  Chromium, som i forvejen installeres et trin før.

  Ny `[pwa]`-sektion i `data/software.conf` med de ni app-id'er. Trinnet kører
  også når sektionen er tom, fordi det samtidig fjerner snap'en: ellers ville
  en maskine imaget før denne ændring beholde begge dele for altid. Genvejene
  installeres med `--system`, så de gælder alle brugere.

- **Login Screen-modul.** Viser domænebrugeren som standard på loginskærmen.

### Rettelser

- **Software-modulet hang på Cisco-installationen efter en vellykket
  installation.** Modulerne blev kørt inde i `$( )`, som venter på
  end-of-file på installerens stdout og ikke på at installeren afslutter.
  Ciscos installere efterlader processer, der har arvet netop den stdout, så
  røret aldrig lukkede. GUI'en viste ingenting imens, fordi alt output blev
  opsamlet til en variabel, der aldrig blev tildelt.

  Hver installer skriver nu til sin egen logfil i `/var/log/dtu-setup/`, har
  en timeout omkring sig (`DTU_CISCO_MODULE_TIMEOUT`, standard 900s), og
  exitkoden læses fra `PIPESTATUS` frem for `$?` — med `pipefail` døde `yes`
  af SIGPIPE, så `$?` var 141 for en fuldstændig vellykket installation.

- **Netværksskift-hook'en handlede ikke længere, den målte kun.** Kaldet til
  `dtu-drives-reselect.sh` var faldet ud, så omvalget skete kun hvis nogen
  trykkede på knappen i notifikationen. Maskinen skiftede ikke mål af sig
  selv, automounts blev aldrig afvæbnet når serveren holdt op med at svare,
  og drevene kom ikke tilbage når man nåede et net der virkede. Uden en
  grafisk session skete der slet ingenting.

  Hook'en kører nu reselect ved hvert netværksskift, i baggrunden og under
  `flock`. Notifikationen sendes kun når reselect melder 75, "jeg prøvede, og
  der er stadig intet mål der svarer".

- **Sustains M-drev var ustyret.** Det ligger på en anden server end Q- og
  P-drevet, men stod ikke i `drives.conf`, og reselect rørte kun `/mnt/Qdrev`
  og `/mnt/Personal`. `/mnt/Mdrev` var dermed den ene automount ingen
  afvæbnede, og altså den der kunne fryse skrivebordet.

- **reselect døde på en `drives.conf` uden `USERNAME`.** `grep | cut` under
  `set -euo pipefail`: en grep uden træffere giver 1, og tildelingen tog
  scriptet ned — to linjer før den guard, der skulle fange netop det. Det
  ramte alle maskiner opsat før nøglen fandtes. Læsningerne går nu gennem en
  hjælper, der ikke kan fejle på en manglende nøgle.

- **LUKS-detektionen hang på én skrøbelig kilde.** `lsblk`s FSTYPE-kolonne
  kommer fra udev, og svarer udev ikke, meldes en krypteret disk som
  ukrypteret. Tre uafhængige kilder forenes nu.

### Ændret

- **Portopslag laves med Python i stedet for med shellen.** Bash kan selv
  åbne en TCP-forbindelse gennem sin indbyggede netværks-pseudoenhed, og det
  er samtidig den primitiv en reverse shell er bygget af. Drev- og
  printerscriptene brugte den til at spørge om en server svarede, hvilket
  udløste en reverse shell-alert hos DTU's sikkerhedsteam 14. september 2026.

  Fem kaldesteder er skiftet til `python3` og `socket.create_connection`:
  `cifs_host_up` i `common.sh`, `reachable` i `sustain-printers.sh`, samt
  `host_up` i `ait-drives.sh` og de to scripts den selv skriver ud på
  maskinen. Samme adfærd, uden signaturen. En guard i testsuiten holder
  mønstret ude fremover.

  Det er værd at vide for drift: `reselect` kører nu ved hvert netværksskift,
  så opslaget mod filserveren sker mange gange dagligt på hver maskine.

### Internt

- `make lint` havde aldrig lintet noget. Linjen sluttede på en backslash, der
  fortsatte ind i det følgende `@echo`, så shellcheck fik `@echo` som filnavn.
  CI havde hele tiden den rigtige liste.
- TPM2-LUKS-testene fejlede på enhver maskine med en krypteret disk, altså
  netop de maskiner værktøjet findes for, og bestod kun i CI. Testene kan nu
  selv bestemme hvad `lsblk` ser.

---

## v1.6.3 — 7. september 2026

### Rettelser

- **"Run All Admin Modules" lukkede appen i stedet for at melde fejl.** To
  ting lå bag, og begge er rettet.

  Fejldialogen blev åbnet inde i `QProcess::finished`, og det næste modul
  blev startet fra samme signal. Det er en indlejret event-loop oven på et
  signal, der stadig er under udsendelse, mens runneren udskifter sit
  `QProcess`. Arbejdet lægges nu i næste tur gennem event-loopet, så signalet
  får lov at folde ud først.

  Og der var ingen `sys.excepthook`. Rejser en slot en undtagelse, som PyQt6
  ikke selv fanger, kalder den `abort()`: vinduet forsvinder uden besked, og
  traceback'en går til stderr, som ingen ser, når programmet er startet fra
  menuen. Der er nu en hook, som viser fejlen i en dialog og lader vinduet
  blive stående.

- **En fejl midt i en samlet kørsel spørger nu, hvad der skal ske.**
  Fejldialogen fik kun en "Luk"-knap, og kørslen fortsatte bag om brugeren,
  så en fejl midt i Run All forsvandt op i loggen. Der er nu **Prøv igen**,
  **Spring over** og **Afbryd resten**. Lukkes vinduet på X'et uden et valg,
  springes modulet over — det er det mildeste svar, når brugeren ikke har
  taget stilling.

- **Genstart-spørgsmålet efter Run All dukkede aldrig op.** Køen blev kun
  ført videre, mens der var flere moduler tilbage, så afslutningen — beskeden
  om at alt er kørt, og spørgsmålet om genstart — blev aldrig nået, fordi
  `has_pending()` allerede er falsk mens det sidste modul kører. Kørslen har
  nu sin egen "i gang"-tilstand.

---

## v1.6.2 — 7. september 2026

Én rettelse. v1.6.0 og v1.6.1 kan ikke køre et eneste modul på en installeret
maskine — opgradér direkte hertil.

### Rettelser

- **Ingen moduler kunne findes i v1.6.0 og v1.6.1.** `get_scripts_dir` havde indtil
  september 2026 en hardkodet `/opt/dtu-sustain-setup/scripts`-fallback ved
  siden af den repo-relative sti, og det var den fallback, der fik
  installerede maskiner til at virke. Da distributionsvalget blev skåret ned
  til Debian/Ubuntu, forsvandt den.

  Tilbage stod kun den repo-relative sti, som regner ét niveau for højt op i
  et installeret layout: `/opt/scripts/ubuntu` i stedet for
  `/opt/dtu-sustain-setup/scripts/ubuntu`. Symptomet er "Update Script
  Missing", men det rammer ikke kun update-modulet — `_resolve_script_path`
  bruger samme mappe, så **hvert eneste modul** var utilgængeligt på en
  maskine, der kørte v1.6.0 eller v1.6.1.

  Roden findes nu ved at lede efter `scripts/` frem for at skrive stien af.
  Det dækker begge layouts og samtidig en installation under et andet prefix
  end `/opt`, hvilket den gamle hardkodede sti ikke gjorde.

---

## v1.6.1 — 7. september 2026

To rettelser oven på v1.6.0.

### Rettelser

- **Automounten afvæbnes nu, når filserveren ikke kan nås.** En kortere
  timeout gjorde frysningerne kortere, ikke færre: så længe automount'en er
  armet mod en server der ikke svarer, blokerer hver adgang til stien indtil
  timeouten, og `idle-timeout` får den til at gentage sig resten af dagen.
  Det er dét, der opleves som at konsollen og Dolphin fryser — og en
  plasmashell, der sover uafbrydeligt i kernen mens den overvåger `/mnt`,
  ligner et Plasma-crash.

  Kan målet ikke nås, stoppes automount- og mount-enheden nu, og et hængende
  mount kobles ud med `umount -l` (uden `-l` blokerer `umount` selv mod en
  død server, og så er frysningen bare flyttet). Så er `/mnt/...` en tom
  mappe, der svarer med det samme. Netværksskift-hook'en armer dem igen, så
  snart et mål svarer, og brugeren får stadig besked med en "Genopfrisk
  drev"-knap.

  **AIT var helt udenfor.** Hook'en afsluttede for alt andet end Sustain, så
  AIT-maskiner havde den installeret og fik intet ud af den — og frysningen
  blev meldt ind på netop en AIT-maskine. Målskift er fortsat Sustain-only,
  men arm/afvæbn gælder nu begge afdelinger. AIT's `drives.conf` bærer
  derfor `SERVER`, så hook'en kan spørge om filserveren svarer.

- **TPM2-modulet melder ikke længere færdigt uden at have testet det.** Der
  er forskel på at en clevis-binding *findes* og at den *virker*: `bind`
  forsegler mod PCR-værdierne som de er lige nu, og er de anderledes tidligt
  i boot — Secure Boot slået fra eller ændret, firmware opdateret, TPM
  nulstillet — fejler oplåsningen, og maskinen beder om adgangskoden som før.

  Modulet sluttede med "Done. Reboot and verify auto-unlock." uanset. Det
  eneste, der blev kontrolleret, var at hook-filen lå i initramfs, og at
  bindingen kunne listes; begge dele kan være i orden på en maskine, der
  stadig spørger. Nu hentes passphrasen ud af slotten med `clevis luks pass`,
  som unsealer præcis som boot gør. Output kasseres — det er disknøglen.
  Fejler den, skriver modulet hvorfor og afslutter med fejl i stedet for en
  grøn besked.

---

## v1.6.0 — 7. september 2026

### Fjernet

- **openSUSE Tumbleweed understøttes ikke længere.** Der er ikke længere en
  openSUSE-maskine at teste på, og en utestet kodesti i et værktøj der kører
  som root er værre end ingen kodesti: den ser vedligeholdt ud.

  `scripts/opensuse/` er væk — otte moduler. Distributionsvalget i
  `distro.py`, `common.sh`, `install-software-manual.sh`, `update-latest.sh`,
  `bin/` og auto-updateren er skåret ned til Debian/Ubuntu, og fejldialogens
  zypper-forslag er erstattet af apt-udgaven.

  `distro.py` er bevaret frem for at blive inlinet. Den er det ene sted der
  kender svaret, så skal en distribution tilbage, er det den fil der skal
  rettes og ikke ti andre. Ukendte distributioner får Ubuntu-mappen:
  modulerne tjekker selv efter apt, realmd og cups og stopper med navnet på
  det der mangler, hvilket er en bedre fejl end en sti der ikke findes.

  `scripts/ubuntu/polkit.sh` nævner stadig
  `org.opensuse.cupspkhelper.mechanism.*`. Det er CUPS' egne action-id'er, og
  de hedder det samme på Ubuntu — et blindt søg-og-erstat ville have brækket
  printerrettighederne.


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

- **Sustain-printeropsætningen findes nu som frittstående script.**
  `scripts/standalone/sustain-printers.sh` gør det samme som Printers-modulet
  uden at kræve `common.sh`, `site.conf` eller at GUI'en leverer brugernavn og
  kodeord. Skal en tekniker bare have printerne op på en maskine, er modulet
  for meget maskineri.

  Der er bevidst intet `--password`-flag: det ville lægge et domænekodeord i
  process-listen, hvor enhver bruger på maskinen kan læse det med `ps`. Flaget
  genkendes alligevel — men kun for at afvise det med en forklaring, for
  ellers prøver folk.

  Serveradresserne står ikke i scriptet. De slås op i `print.conf` ved siden af
  scriptet, så `site.conf`, så den forældede `dtu-sustain.env` — og spørges,
  hvis intet findes.

- **Netværksdrev der ikke kan nås, siger det nu selv.** Skifter maskinen
  netværk, og kan det monterede mål ikke længere nås, får hver indlogget bruger
  en notifikation med en "Genopfrisk drev"-knap og en kvittering bagefter.
  Tidligere skete genmonteringen tavst, mens alt der rørte `/mnt` blokerede.

  Nogle skriveborde leverer notifikationer gennem XDG-portalen, som ikke
  understøtter knapper. Derfor står den manuelle vej også i teksten, og derfor
  findes menupunktet **Genopfrisk netværksdrev** under *System*. Den vej findes
  altid.

- **`SITE_SUSTAIN_PLOT_SERVER`** er en ny variabel i `site.conf` til
  BYG-plotteren.

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

- **Sustains `FollowMe-Plot-PS` er erstattet af BYG-plotteren.** Den gamle kø
  pegede på en SMB-kø på FollowMe-serveren. Afløseren er en anden slags ting:
  BYG-plotteren er selve enheden, ikke en printserver. Den har ingen
  SMB-tjeneste — port 445 er lukket — og lytter på JetDirect 9100, så køen
  oprettes med `socket://` og uden credentials. Værtsnavnet står i
  `site.conf` som `SITE_SUSTAIN_PLOT_SERVER`, ikke i repoet.

  Det har en konsekvens der skal siges højt: FollowMe-køer godkender og
  afregner per bruger, og denne gør ikke. Enhver der kan nå enheden på
  netværket, kan printe på den.

  Køen får sin egen PPD frem for at genbruge `KOC751iUX.ppd`. Den er en Konica
  Minolta-driver, og indstillingerne ved siden af — `KMDuplex`,
  `TextPureBlack`, `GlossyMode` — findes ikke i en HP-PPD. Den gamle kø
  arvede dem alle og slap kun af sted med det, fordi FollowMe-serveren
  rendererede jobbet.

- **Printerscriptet kan nu køres hver gang, ikke kun på en tom maskine.** Det
  fjernede tre navngivne køer, oprettede to nye og håbede. Nu konvergerer det:
  hængende jobs annulleres først, `cups-browsed` maskeres frem for blot at
  blive stoppet, pakker installeres kun hvis de mangler, serverne kontaktes på
  445 og 9100 før køerne oprettes, og hver kø verificeres til sidst — findes
  den, peger den rigtigt, er den slået til, tager den imod jobs.

  Fejl samles og listes til sidst frem for at tage resten af scriptet med sig,
  så en fejlende plotter ikke koster FollowMe-køen.

- **Kun scriptets egne køer fjernes.** Standarden ryddede alt. På en maskine
  med en Brother på skrivebordet betød det, at en printeropsætning slettede en
  printer der ikke fejlede noget, og som scriptet ikke ved hvordan man
  genskaber. Der matches nu på navn (`FollowMe-*`, `BYG-PHP03-*`) og på
  device-URI, så en kø nogen har kaldt "Printer-1", men som peger på
  FollowMe-serveren, stadig fjernes som den dublet den er.
  `--remove-all-printers` rydder alt, for de tilfælde hvor det er meningen.

- **Serveradresser vises ikke længere på skærmen.** Scriptet køres typisk på
  en andens maskine med nogen kigge med. Indtastning sker uden ekko, og
  kvitteringen viser kun længden, så en slåfejl stadig kan ses.
  `--show-values` slår maskeringen fra, når man fejlsøger alene.

### Rettelser

- **30 sekunders frysninger ved adgang til `/mnt` er væk.** AIT's drev blev
  monteret med `x-systemd.automount` og `mount-timeout=30`. En automount
  afbryder enhver adgang til stien, og kalderen sover uafbrydeligt indtil
  monteringen lykkes eller timer ud — så kunne filserveren ikke nås, stod
  Dolphins Places-panel, `df` og tab-completion stille i 30 sekunder ad gangen,
  igen og igen. Timeouten er nu 10 sekunder, og Sustain bruger samme
  `CIFS_SYSTEMD_OPTS` som AIT i stedet for sine egne optioner helt uden
  timeout, hvor systemd faldt tilbage på 90 sekunder.

- **AIT fik aldrig netværksskift-hook'en.** Kaldet lå efter AIT-grenens
  `exit 0`, så skiftede maskinen mellem kabel, DTUSecure og VPN, blev drevene
  ved med at pege på et mål der ikke kunne nås. Hook'en og `drives.conf`
  oprettes nu også for AIT.

- **Førstegangsopsætningen dukkede aldrig op.** Autostart-posten blev lagt i
  `/etc/skel`, som kun kopieres når en konto *oprettes*. Modulet kræver at en
  admin er logget ind, så hjemmemappen fandtes altid allerede — posten kom
  derfor aldrig nogen steder hen. Den ligger nu i `/etc/xdg/autostart`, og de
  kopier der allerede var landet i eksisterende hjemmemapper ryddes op, så
  dialogen ikke kommer to gange.

  Scriptet afgør selv om det skal køre: kun for domænebrugere, som findes i
  `getent` men ikke i `/etc/passwd`. Markøren skrives til sidst og kun der —
  afbrydes opsætningen undervejs, kommer dialogen igen ved næste login. En halv
  opsætning skal ikke se færdig ud.

- **Printerscriptet døde tavst, når man sprang plotteren over.** En `&&`-liste
  som sidste sætning i en funktion returnerer 1, når betingelsen er falsk, og
  med `set -e` tager det hele scriptet ned — uden fejlbesked, fordi der ikke
  skete noget forkert. Man trykkede Enter, og så skete der ikke mere.

  Bruger og kodeord spørges nu først, med en forklaring: FollowMe-køen spooler
  som en navngiven bruger, og serveren kan ikke afregne eller frigive et job
  uden at vide hvem det tilhører. Før lå det bag et valgfrit
  plotter-spørgsmål, hvilket er hvordan det kunne forsvinde helt.

- **Domænepræfiks i brugernavnet afvises ikke længere.** Prompten beder om et
  WIN-brugernavn, og folk skriver rimeligvis `WIN\mpark` eller `mpark@dtu.dk`.
  Credentials-filen skal have præcis `WIN\brugernavn`, så `WIN\WIN\mpark`
  fejlede godkendelsen uden at sige hvorfor: jobbet landede i køen og forsvandt.
  Begge former tages nu af, og scriptet siger hvad det endte med at bruge.

- **Auto-updateren krævede ikke root.** Den skriver
  `/etc/default/dtu-auto-update` og systemd-units; kørt som almindelig bruger
  fejlede den halvvejs nede med en permission-fejl per linje og en halv
  opsætning tilbage. Den kræver nu root fra starten. De to apt-kald, der kunne
  vælte den på en maskine uden netværk, advarer nu i stedet for at afbryde — en
  manglende `fwupd` må ikke koste hele opdateringsservicen.

### Test og vedligehold

- **`tests/test_scripts.py`** — 25 tests, der kigger på hvad scripts'ene siger
  frem for hvad kommentarerne påstår. Hver enkelt findes, fordi den fejl den
  beskriver rent faktisk er sluppet ud: `set -e`-fælden, CIFS-automounts uden
  mount-timeout, og at AIT får samme behandling som Sustain.

- **`tests/test_domain_join.py`** — 14 tests, der kører de rigtige blokke ud af
  scriptet, ikke en kopi, mod en `sssd.conf` som `realm join` efterlader den.
  Den genererede `krb5.conf` læses af MIT's egen parser.

- **En udfyldt `print.conf` kan ikke længere committes.** Filen indeholder
  interne værtsnavne og hører ikke i et offentligt repo — kun
  `print.conf.example` med pladsholdere gør.

- **CI lintede en mappe der ikke findes.** `shellcheck`-trinnet pegede stadig
  på `scripts/opensuse/*.sh` og fejlede derfor på hver eneste push, hvilket
  blokerede build og release. Det linter nu `scripts/standalone/` i stedet, som
  ikke var dækket før.

- **En test kunne ikke skippe sig selv.** `TestDesktopEntries` skippede, hvis
  `desktop-file-validate` returnerede 127. Den kode kan aldrig komme: 127 er
  hvad en *shell* returnerer for en kommando, den ikke kan finde, og
  `subprocess.run` exec'er direkte — mangler binæren, kastes
  `FileNotFoundError`, og testen fejler i stedet for at skippe. Runneren har
  ikke `desktop-file-utils`, så det var præcis hvad der skete. Skippet
  afgøres nu af `shutil.which`, og pakken installeres i CI, så testen faktisk
  kører der i stedet for bare at skippe.

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
