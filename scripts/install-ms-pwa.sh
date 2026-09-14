#!/usr/bin/env bash
# install-ms-pwa.sh
# Opretter .desktop-genveje til Microsoft 365 web-apps, kørt som PWA i Ungoogled Chromium.
#
#   ./install-ms-pwa.sh                    # installer alle apps for den aktuelle bruger
#   ./install-ms-pwa.sh outlook teams      # kun udvalgte
#   sudo ./install-ms-pwa.sh --system      # installer for alle brugere
#   ./install-ms-pwa.sh --remove [id...]   # fjern igen
#   ./install-ms-pwa.sh --check-icons      # test kun ikonkilderne, installer intet
#   ./install-ms-pwa.sh --icon-dir DIR     # brug lokale ikoner fra DIR (<id>.png/.svg)
#   ./install-ms-pwa.sh --no-theme-icons   # spring ikontemaer over, hent altid fra nettet
#   ./install-ms-pwa.sh --no-deps          # spring pakkeinstallation over
#   ./install-ms-pwa.sh --print-wmclass    # vis forventet WM_CLASS pr. app
#   ./install-ms-pwa.sh --list
#
# Ikoner findes i denne rækkefølge og kopieres ALTID ind i ikonmappen, så genvejene
# ikke afhænger af at et tema eller et CDN stadig er der bagefter:
#   1) --icon-dir            2) installeret ikontema (Papirus m.fl.)
#   3) download fra nettet   4) genereret SVG-flise

set -euo pipefail

SYSTEM=0; REMOVE=0; CHECK_ONLY=0; USE_THEME=1; PRINT_WM=0; DEPS=1; LOCAL_ICONS=""
SELECTED=()

# OneDrive er tenant-specifik. Overstyres med:  MS_TENANT=andet ./install-ms-pwa.sh
# Husk at variablen skal stå før sudo:  sudo MS_TENANT=andet bash ./install-ms-pwa.sh --system
TENANT="${MS_TENANT:-dtudk}"
ONEDRIVE_URL="https://${TENANT}-my.sharepoint.com/"

# ---------------------------------------------------------------------------
# App-katalog
#   id | Navn | URL | Temaikon-navne (;) | Ikon-URL'er (;) | Farve | Bogstav
# ---------------------------------------------------------------------------
APPS=(
  "outlook|Outlook|https://outlook.office.com/mail/|ms-outlook|https://res.cdn.office.net/assets/mail/pwa/v1/pngs/apple-touch-icon-180x180.png|#0F6CBD|O"
  "calendar|Outlook Kalender|https://outlook.office.com/calendar/view/workweek|office-calendar;ms-outlook|https://res.cdn.office.net/assets/mail/pwa/v1/pngs/apple-touch-icon-180x180.png|#0F6CBD|K"
  "word|Word|https://word.cloud.microsoft/|ms-word||#185ABD|W"
  "excel|Excel|https://excel.cloud.microsoft/|ms-excel||#107C41|X"
  "powerpoint|PowerPoint|https://powerpoint.cloud.microsoft/|ms-powerpoint||#C43E1C|P"
  "onenote|OneNote|https://www.onenote.com/notebooks|ms-onenote||#7719AA|N"
  "onedrive|OneDrive|${ONEDRIVE_URL}|ms-onedrive||#0364B8|D"
  "todo|To Do|https://to-do.office.com/tasks/|ms-todo||#3B4CB8|T"
  "m365|Microsoft 365|https://www.microsoft365.com/|microsoft-365;ms-office||#D83B01|M"
)

# ---------------------------------------------------------------------------
# Argumenter
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --system)         SYSTEM=1 ;;
    --remove)         REMOVE=1 ;;
    --check-icons)    CHECK_ONLY=1 ;;
    --no-theme-icons) USE_THEME=0 ;;
    --no-deps)        DEPS=0 ;;
    --print-wmclass)  PRINT_WM=1 ;;
    --icon-dir)       LOCAL_ICONS="${2:?--icon-dir kræver en sti}"; shift ;;
    --list)
      printf '%-12s %s\n' "ID" "NAVN"
      for a in "${APPS[@]}"; do IFS='|' read -r id name _ <<<"$a"; printf '%-12s %s\n' "$id" "$name"; done
      exit 0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "Ukendt flag: $1" >&2; exit 1 ;;
    *)  SELECTED+=("$1") ;;
  esac
  shift
done

if [[ $SYSTEM -eq 1 ]]; then
  [[ $EUID -eq 0 ]] || { echo "--system kræver root." >&2; exit 1; }
  APP_DIR="/usr/share/applications"; ICON_DIR="/usr/share/icons/ms-pwa"
else
  if [[ $EUID -eq 0 && $CHECK_ONLY -eq 0 && $PRINT_WM -eq 0 ]]; then
    echo "Kørt som root uden --system: filerne ville lande i ${HOME}/.local og" >&2
    echo "aldrig blive set af din bruger. Kør enten uden sudo, eller med --system." >&2
    exit 1
  fi
  APP_DIR="$HOME/.local/share/applications"; ICON_DIR="$HOME/.local/share/icons/ms-pwa"
fi

# ---------------------------------------------------------------------------
# Afhaengigheder
# Installerer kun det der faktisk mangler. Slaas fra med --no-deps.
# ---------------------------------------------------------------------------
FLATPAK_ID="io.github.ungoogled_software.ungoogled_chromium"

detect_pkgmgr() {
  command -v apt-get >/dev/null 2>&1 && { printf 'apt';    return 0; }
  command -v zypper  >/dev/null 2>&1 && { printf 'zypper'; return 0; }
  return 1
}

pkg_installed() {
  case "$1" in
    apt)    dpkg-query -W -f='${Status}' "$2" 2>/dev/null | grep -q 'ok installed' ;;
    zypper) rpm -q "$2" >/dev/null 2>&1 ;;
  esac
}

ensure_deps() {
  local mgr sudo_cmd="" p
  local -a want=() missing=()

  mgr="$(detect_pkgmgr)" || {
    echo "Ukendt pakkehaandtering - springer afhaengigheder over."
    return 0
  }

  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 && sudo_cmd="sudo" || {
      echo "Mangler root og sudo - kan ikke installere pakker. Brug --no-deps."
      return 0
    }
  fi

  case "$mgr" in
    apt)    want=(curl file flatpak imagemagick papirus-icon-theme wmctrl) ;;
    zypper) want=(curl file flatpak ImageMagick papirus-icon-theme wmctrl) ;;
  esac

  for p in "${want[@]}"; do
    pkg_installed "$mgr" "$p" || missing+=("$p")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Installerer: ${missing[*]}"
    case "$mgr" in
      apt)
        $sudo_cmd apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y "${missing[@]}" ;;
      zypper)
        $sudo_cmd zypper --non-interactive install --no-recommends "${missing[@]}" ;;
    esac
  else
    echo "Alle systempakker er til stede."
  fi

  # Flathub + Ungoogled Chromium
  if command -v flatpak >/dev/null 2>&1; then
    flatpak remotes --columns=name | grep -qx flathub ||
      $sudo_cmd flatpak remote-add --if-not-exists --system \
        flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    if ! flatpak info "$FLATPAK_ID" >/dev/null 2>&1; then
      echo "Installerer Ungoogled Chromium (flatpak, system-wide)..."
      $sudo_cmd flatpak install -y --system --noninteractive flathub "$FLATPAK_ID"
    fi
  fi

  # Genindlaes vaerktoejer der lige er kommet til
  IM=""
  for p in magick convert; do command -v "$p" >/dev/null 2>&1 && { IM="$p"; break; }; done
}

# ---------------------------------------------------------------------------
# Browser
# ---------------------------------------------------------------------------
find_browser() {
  local c
  for c in ungoogled-chromium chromium chromium-browser; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s' "$(command -v "$c")"; return 0; }
  done
  if command -v flatpak >/dev/null 2>&1 &&
     flatpak info io.github.ungoogled_software.ungoogled_chromium >/dev/null 2>&1; then
    printf 'flatpak run io.github.ungoogled_software.ungoogled_chromium'; return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# WM_CLASS
# Chromium er en singleton: åbner du app nr. 2, forwardes kommandoen til den
# kørende proces, og --class fra nr. 2 bliver IGNORERET. Alle vinduer arver
# klassen fra den først åbnede app, og så stacker de i proceslinjen.
# Derfor sætter vi IKKE --class, men lader Chromium bruge sin egen
# URL-afledte klasse og matcher StartupWMClass mod den.
# ---------------------------------------------------------------------------
# Formatet er verificeret med 'wmctrl -lx' mod Flatpak-Chromium paa X11:
#   https://word.cloud.microsoft/          -> word.cloud.microsoft
#   https://outlook.office.com/mail/       -> outlook.office.com__mail
# Bemaerk at Chromium laegger dette i vinduets INSTANCE-navn; klassenavnet er
# ens for alle app-vinduer (Io.github.ungoogled_software.ungoogled_chromium),
# og det er derfor de stacker, hvis StartupWMClass ikke saettes.
derive_wmclass() {
  local url="$1" rest host path
  rest="${url#https://}"; rest="${rest#http://}"; rest="${rest%/}"
  host="${rest%%/*}"
  path="${rest#"$host"}"; path="${path#/}"; path="${path//\//_}"
  if [[ -n "$path" ]]; then printf '%s__%s' "$host" "$path"
  else printf '%s' "$host"; fi
}

if [[ $PRINT_WM -eq 1 ]]; then
  for a in "${APPS[@]}"; do
    IFS='|' read -r id name url _ <<<"$a"
    printf '%-16s %s\n' "$name" "$(derive_wmclass "$url")"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# Ikoner
# ---------------------------------------------------------------------------
IM=""
for c in magick convert; do command -v "$c" >/dev/null 2>&1 && { IM="$c"; break; }; done

gen_icon() {
  local out="$1" color="$2" letter="$3"
  cat >"$out" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">
  <rect width="256" height="256" rx="44" fill="${color}"/>
  <text x="128" y="180" text-anchor="middle" fill="#ffffff"
        font-family="sans-serif" font-size="150" font-weight="700">${letter}</text>
</svg>
EOF
}

# Leder efter et ikonnavn i installerede ikontemaer. Ekkoer stien ved fund.
find_theme_icon() {
  local names="$1" n d s ext f
  local -a arr dirs sizes
  IFS=';' read -r -a arr <<<"$names"
  dirs=("${HOME:-/root}/.local/share/icons" /usr/share/icons /usr/local/share/icons)
  sizes=(scalable 512x512 256x256 128x128 96x96 64x64 48x48)
  for n in "${arr[@]}"; do
    [[ -n "$n" ]] || continue
    for d in "${dirs[@]}"; do
      [[ -d "$d" ]] || continue
      for s in "${sizes[@]}"; do
        for ext in svg png; do
          for f in "$d"/*/"$s"/apps/"${n}.${ext}"; do
            [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
          done
        done
      done
    done
  done
  return 1
}

try_download() {
  local dest="$1" url="$2" mime
  # Kort timeout: bag en firewall der dropper pakker uden svar hænger curl ellers længe.
  curl -fsSL --connect-timeout 4 --max-time 10 -A 'Mozilla/5.0' -o "$dest" "$url" 2>/dev/null || return 1
  [[ -s "$dest" ]] || return 1
  mime="$(file -b --mime-type "$dest")"
  case "$mime" in image/*|application/octet-stream) ;; *) return 1 ;; esac
  [[ "$(stat -c%s "$dest")" -ge 100 ]]
}

# Normaliser til 256x256 PNG hvis ImageMagick findes. SVG bevares som SVG.
# Ved .ico vælges den STØRSTE frame, så vi ikke får et opskaleret 16x16-ikon.
normalize_icon() {
  local src="$1" base="$2" mime frame
  mime="$(file -b --mime-type "$src")"

  if [[ "$mime" == "image/svg+xml" ]]; then
    cp "$src" "${base}.svg"; printf '%s' "${base}.svg"; return 0
  fi
  if [[ -n "$IM" ]]; then
    frame="$($IM identify -format '%[fx:w] %p\n' "$src" 2>/dev/null | sort -rn | head -1 | awk '{print $2}')"
    frame="${frame:-0}"
    if $IM "${src}[${frame}]" -background none -resize 256x256 -gravity center \
           -extent 256x256 "PNG32:${base}.png" 2>/dev/null && [[ -s "${base}.png" ]]; then
      printf '%s' "${base}.png"; return 0
    fi
  fi
  case "$mime" in
    image/png)  cp "$src" "${base}.png"; printf '%s' "${base}.png" ;;
    image/jpeg) cp "$src" "${base}.jpg"; printf '%s' "${base}.jpg" ;;
    *)          cp "$src" "${base}.ico"; printf '%s' "${base}.ico" ;;
  esac
}

# Sætter ICON_PATH og ICON_SOURCE. Returnerer 1 hvis der blev brugt fallback.
resolve_icon() {
  local id="$1" app_url="$2" theme_names="$3" urls="$4" color="$5" letter="$6"
  local base="${ICON_DIR}/${id}" origin tmp u hit
  local -a candidates=()

  rm -f "${base}."{png,svg,ico,jpg}

  if [[ -n "$LOCAL_ICONS" ]]; then
    for ext in png svg; do
      if [[ -f "${LOCAL_ICONS}/${id}.${ext}" ]]; then
        cp "${LOCAL_ICONS}/${id}.${ext}" "${base}.${ext}"
        ICON_PATH="${base}.${ext}"; ICON_SOURCE="lokal: ${LOCAL_ICONS}/${id}.${ext}"; return 0
      fi
    done
  fi

  if [[ $USE_THEME -eq 1 ]] && hit="$(find_theme_icon "$theme_names")"; then
    ICON_PATH="$(normalize_icon "$hit" "$base")"
    ICON_SOURCE="tema: ${hit}"; return 0
  fi

  origin="$(printf '%s' "$app_url" | sed -E 's#^(https://[^/]+).*#\1#')"
  [[ -n "$urls" ]] && IFS=';' read -r -a candidates <<<"$urls"
  candidates+=("${origin}/favicon.ico" "${origin}/apple-touch-icon.png" "${origin}/favicon.png")

  tmp="$(mktemp)"
  for u in "${candidates[@]}"; do
    [[ -n "$u" ]] || continue
    printf '  ... henter %s\r' "${u:0:70}" >&2
    if try_download "$tmp" "$u"; then
      printf '%*s\r' 80 '' >&2
      ICON_PATH="$(normalize_icon "$tmp" "$base")"; ICON_SOURCE="$u"; rm -f "$tmp"; return 0
    fi
  done
  printf '%*s\r' 80 '' >&2
  rm -f "$tmp"

  gen_icon "${base}.svg" "$color" "$letter"
  ICON_PATH="${base}.svg"; ICON_SOURCE="genereret"; return 1
}

# ---------------------------------------------------------------------------
# Forberedelse
# ---------------------------------------------------------------------------
if [[ $REMOVE -eq 0 && $CHECK_ONLY -eq 0 ]]; then
  [[ $DEPS -eq 1 ]] && ensure_deps
  BROWSER="$(find_browser)" || {
    echo "Ungoogled Chromium blev ikke fundet." >&2
    echo "Installér: flatpak install flathub io.github.ungoogled_software.ungoogled_chromium" >&2
    exit 1
  }
  echo "Browser: $BROWSER"
  [[ -n "$IM" ]] || echo "Bemærk: ImageMagick mangler — ikoner konverteres ikke til 256x256 PNG."
  if [[ $USE_THEME -eq 1 ]] && ! find_theme_icon "ms-word" >/dev/null; then
    echo "Advarsel: intet ikontema med Office-ikoner fundet - ikoner hentes fra nettet."
  fi
fi
[[ $REMOVE -eq 1 ]] || mkdir -p "$ICON_DIR"
[[ $REMOVE -eq 1 || $CHECK_ONLY -eq 1 ]] || mkdir -p "$APP_DIR"
[[ $CHECK_ONLY -eq 1 ]] && { ORIG_ICON_DIR="$ICON_DIR"; ICON_DIR="$(mktemp -d)"; }

# ---------------------------------------------------------------------------
# Hovedløkke
# ---------------------------------------------------------------------------
count=0; real=0; fake=0
for entry in "${APPS[@]}"; do
  IFS='|' read -r id name url theme_names icon_urls color letter <<<"$entry"

  if [[ ${#SELECTED[@]} -gt 0 ]]; then
    match=0
    for s in "${SELECTED[@]}"; do [[ "$s" == "$id" ]] && match=1; done
    [[ $match -eq 1 ]] || continue
  fi

  desktop="${APP_DIR}/ms-${id}.desktop"

  if [[ $REMOVE -eq 1 ]]; then
    rm -f "$desktop" "${ICON_DIR}/${id}."{png,svg,ico,jpg}
    echo "Fjernet: $name"; count=$((count + 1)); continue
  fi

  if resolve_icon "$id" "$url" "$theme_names" "$icon_urls" "$color" "$letter"; then
    real=$((real + 1)); status="ikon OK"
  else
    fake=$((fake + 1)); status="FALLBACK"
  fi

  if [[ $CHECK_ONLY -eq 1 ]]; then
    printf '%-16s %-9s %s\n' "$name" "$status" "$ICON_SOURCE"
    count=$((count + 1)); continue
  fi

  wmclass="$(derive_wmclass "$url")"
  cat >"$desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=${name}
GenericName=Microsoft 365
Comment=${name} som web-app i Ungoogled Chromium
Exec=${BROWSER} --app=${url}
Icon=${ICON_PATH}
Terminal=false
StartupNotify=true
StartupWMClass=${wmclass}
Categories=Network;Office;X-MS365;
Keywords=microsoft;365;pwa;${id};
EOF
  chmod 644 "$desktop" "$ICON_PATH"
  printf 'Installeret: %-16s [%s: %s]\n' "$name" "$status" "$ICON_SOURCE"
  count=$((count + 1))
done

[[ $count -gt 0 ]] || { echo "Ingen apps matchede. Kør --list for at se ID'er." >&2; exit 1; }

if [[ $CHECK_ONLY -eq 1 ]]; then
  rm -rf "$ICON_DIR"; echo "---"; echo "Fundet: $real   Fallback: $fake"; exit 0
fi
if [[ $REMOVE -eq 0 ]]; then
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" 2>/dev/null || true
  echo "Færdig ($count stk.) — $real rigtige ikoner, $fake genererede."
else
  echo "Færdig ($count stk.)."
fi
