#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – In-place upgrade from Kubuntu 24.04 to 26.04
#
# For IT support. Sit at the machine, log in with a LOCAL admin account (not
# a domain account), open Konsole and run:
#
#     sudo dtu-upgrade-2604
#
# The first run checks the machine, shows what will happen and asks for ONE
# confirmation. Everything after that runs unattended as a system service,
# so a crashing desktop or a closed window does not stop it. Run the same
# command again at any time to follow it.
#
# When it says so, reboot, log in with the local account again and run the
# same command once more. That run checks the result and writes a report.
#
# Options:
#   (none)                 Start, resume or follow, depending on where it is
#   --status               Show where the upgrade is. Changes nothing.
#   --verify               Check the result again (after the reboot)
#   --repairbooth-dir DIR  Folder with repairbooth_<version>+qt6_all.deb and
#                          its sha256sums.txt. Default: the current folder.
#
# THERE IS NO WAY BACK. do-release-upgrade cannot be rolled back. Where a
# failed upgrade is not acceptable, reinstall from the 26.04 image instead.
#
# ── What it does about the problems found in the test upgrade ──────────────
#
# Found on a test laptop on 2 Oct 2026 (Opgradering-2604-fund.txt). Each
# point says what the script does about it.
#
#  - SSSD is stopped while it is upgraded, so no domain user can be looked up
#    in that window. Refuses to start from a domain account, and requires a
#    local admin account with a password.
#  - do-release-upgrade stops and asks about every changed configuration
#    file, foreign package and obsolete package. Runs it non-interactively
#    with fixed rules instead:
#      * configuration files: the package's new version (dpkg
#        --force-confnew). The old file is kept beside it as .dpkg-old, and
#        all of /etc is in the backup. Our own modules write their settings
#        again afterwards. This also gets /etc/lsb-release right, which the
#        image had branded and whose default answer was wrong.
#      * files kept through ucf, such as /etc/default/grub and
#        /etc/ssh/sshd_config: the LOCAL version. ucf follows dpkg's
#        --force-confnew, so a locally changed one is put back from the
#        backup afterwards, with the new one beside it as .ucf-dist. GRUB's
#        can carry kernel parameters the machine needs to boot.
#      * foreign packages (installed by hand, rclone etc.): kept.
#      * obsolete packages: NOT removed. The upgrader's own default would
#        remove hundreds, including some of ours.
#  - KDE PIM (KMail, Kontact) is removed by the upgrade, and Akonadi falls
#    back to SQLite while the user's data is in MySQL. Reinstalls kdepim and
#    akonadi-backend-mysql if they were there, after "apt-get autoremove":
#    leftover KF5 packages such as ktnef hold files the new KMail ships.
#  - A Qt 5 login screen theme (e.g. from the KDE Store) cannot load on
#    26.04's Qt 6 greeter. SDDM then shows a fallback with no username
#    field, and NO DOMAIN USER CAN LOG IN. Disables such a theme before the
#    reboot, so the distribution's theme applies.
#  - Re-runs the DTU modules the machine has (RDP, login screen, PolicyKit,
#    Defender, first login, automount), because the upgrade replaces their
#    files or disables Microsoft's package source.
#  - RepairBooth's Qt 5 build cannot run on 26.04. Installs the +qt6 build
#    from --repairbooth-dir after checking it against sha256sums.txt.
#
# Logs: /var/log/dtu-upgrade-2604.log, and the upgrader's own in
# /var/log/dist-upgrade/. Backup: /var/backups/dtu-upgrade-2604-<time>/.
###############################################################################
set -euo pipefail

TARGET_VERSION="26.04"
TARGET_CODENAME="resolute"
FROM_VERSION="24.04"
# Ældre udgaver af modulerne fejler efter opgraderingen (Defender: v1.8.1).
MIN_DTU_SETUP="1.8.1"
MIN_FREE_GB=15

# Kun til testene: et falsk rodtræ for filkontrollerne.
R="${DTU_UPGRADE_ROOT:-}"
STATE_DIR="${R}/var/lib/dtu-upgrade-2604"
STATE_FILE="${STATE_DIR}/state"
SELF="${STATE_DIR}/dtu-upgrade-2604.sh"
LOG="${R}/var/log/dtu-upgrade-2604.log"
UNIT="dtu-upgrade-2604"
DTU_PREFIX="${DTU_PREFIX:-/opt/dtu-sustain-setup}"
APT_CONF="${R}/etc/apt/apt.conf.d/99dtu-upgrade-2604"
RU_CFG="${R}/etc/update-manager/release-upgrades.d/dtu-upgrade-2604.cfg"

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; NC=""
fi
step() { echo; echo "${BOLD}== $*${NC}"; }
ok()   { echo "  ${GREEN}[OK]${NC} $*"; }
info() { echo "  [i] $*"; }
warn() { echo "  ${YELLOW}[WARN]${NC} $*"; }
fail() { echo "  ${RED}[FAIL]${NC} $*" >&2; }
die()  { fail "$*"; exit 1; }

###############################################################################
# Tilstand
###############################################################################
# Maskinen genstarter undervejs, og et vindue kan lukkes, så hvor langt
# opgraderingen er nået, står på disken. Én linje NØGLE=værdi pr. nøgle.

state_get() {
    [[ -r "$STATE_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$STATE_FILE" | tail -n 1
}

state_set() {
    local key="$1" val="$2" tmp
    install -d -m 700 "$STATE_DIR"
    tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
    {
        if [[ -r "$STATE_FILE" ]]; then grep -v "^${key}=" "$STATE_FILE" || true; fi
        printf '%s=%s\n' "$key" "$val"
    } > "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

###############################################################################
# Fakta om maskinen
###############################################################################

os_value() {
    local f="${R}/etc/os-release"
    [[ -r "$f" ]] || f="${R}/usr/lib/os-release"
    sed -n "s/^$1=//p" "$f" 2>/dev/null | head -n 1 | tr -d '"'
}

pkg_installed() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

pkg_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

dtu_setup_version() {
    sed -n 's/^__version__ = "\(.*\)"/\1/p' "${DTU_PREFIX}/dtu_sustain_setup/__init__.py" 2>/dev/null
}

# Hvilke DTU-moduler maskinen har fået, aflæst af det de efterlader. De køres
# igen efter opgraderingen: deres filer er enten konfigurationsfiler som
# opgraderingen udskifter (xrdp.ini, startwm.sh), eller det de sætter op
# afhænger af udgaven (SDDM, polkit, Microsofts pakkekilde).
detect_modules() {
    local mods=()
    [[ -e "${R}/etc/polkit-1/rules.d/45-xrdp.rules" ]] && mods+=(rdp)
    [[ -e "${R}/etc/sddm.conf.d/zz-dtu-domain-login.conf" ]] && mods+=(login-screen)
    if [[ -e "${R}/etc/sudoers.d/dtu-it-admins" || -e "${R}/etc/polkit-1/rules.d/49-domain-admins.rules" ]]; then
        mods+=(polkit)
    fi
    pkg_installed mdatp && mods+=(defender)
    [[ -e "${R}/etc/xdg/autostart/dtu-first-login.desktop" ]] && mods+=(first-login-deploy)
    [[ -e "${R}/usr/local/sbin/pdrev-session.sh" ]] && mods+=(automount)
    echo "${mods[*]:-}"
}

# Pakker der ikke kommer fra Ubuntus arkiv: lagt ind i hånden eller fra en
# tredjepartskilde. do-release-upgrade kalder dem "unofficial" og spørger.
foreign_packages() {
    python3 - <<'PY'
import apt
cache = apt.Cache()
for pkg in cache:
    if not pkg.is_installed:
        continue
    # Også kandidaten: en Ubuntu-pakke i en version arkivet ikke har længere,
    # har kun "now" som kilde, men er ikke fremmed.
    versions = [pkg.installed] + ([pkg.candidate] if pkg.candidate else [])
    origins = [o for v in versions for o in v.origins if o.archive not in ("now", "")]
    if not any(o.origin == "Ubuntu" for o in origins):
        where = ", ".join(sorted({o.origin or o.site for o in origins})) or "no source (installed by hand)"
        print(f"{pkg.name}\t{where}")
PY
}

# Konfigurationsfiler der afviger fra pakkens version. Det er dem opgraderingen
# ville have spurgt om; listen viser bagefter hvad der blev udskiftet.
changed_conffiles() {
    dpkg-query -W -f='${Package}\n${Conffiles}\n' 2>/dev/null |
    awk '/^[^ ]/ { pkg = $1; next }
         /^ /    { if ($3 != "obsolete" && $2 != "newconffile") print pkg, $1, $2 }' |
    while read -r pkg path sum; do
        if [[ ! -e "$path" ]]; then
            echo "$pkg $path deleted"
        elif [[ -r "$path" && "$(md5sum < "$path" | cut -d' ' -f1)" != "$sum" ]]; then
            echo "$pkg $path modified"
        fi
    done
}

# ucf-filer der er ændret lokalt. ucf følger dpkg's --force-confnew, så de
# ville blive skiftet ud i stilhed (set 2. oktober 2026 i VM-testen, både
# /etc/default/grub og /etc/ssh/sshd_config).
changed_ucf_files() {
    local hashfile="${R}/var/lib/ucf/hashfile" sum path
    [[ -r "$hashfile" ]] || return 0
    while read -r sum path; do
        [[ "$path" == /etc/* && -f "${R}${path}" ]] || continue
        if [[ "$(md5sum < "${R}${path}" | cut -d' ' -f1)" != "$sum" ]]; then
            echo "$path"
        fi
    done < "$hashfile"
}

clevis_bindings() {
    command -v clevis >/dev/null 2>&1 || return 0
    local dev
    for dev in $(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null); do
        echo "== $dev"
        clevis luks list -d "$dev" 2>&1 || true
    done
}

session_is_remote() {
    # logind bruger audit-sessionens nummer som sessions-ID. sudo ændrer det
    # ikke, så det peger på den session kommandoen blev tastet i.
    local sid remote service
    sid="$(cat /proc/self/sessionid 2>/dev/null || true)"
    [[ -n "$sid" && "$sid" != 4294967295 ]] || return 1
    remote="$(loginctl show-session "$sid" -p Remote --value 2>/dev/null || true)"
    service="$(loginctl show-session "$sid" -p Service --value 2>/dev/null || true)"
    [[ "$remote" == yes || "$service" == sshd || "$service" == xrdp* ]]
}

on_battery() {
    local bat
    for bat in /sys/class/power_supply/*; do
        [[ "$(cat "$bat/type" 2>/dev/null)" == Battery ]] || continue
        [[ "$(cat "$bat/status" 2>/dev/null)" == Discharging ]] && return 0
    done
    return 1
}

# Lokale konti i sudo-gruppen med et kodeord. Mens SSSD er nede, er de de
# eneste der kan logge ind.
local_admins() {
    local u pw
    for u in $(getent -s files group sudo admin 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
        getent -s files passwd "$u" >/dev/null 2>&1 || continue
        pw="$(getent -s files shadow "$u" 2>/dev/null | cut -d: -f2)"
        [[ -n "$pw" && "$pw" != '!'* && "$pw" != '*'* ]] && echo "$u"
    done | sort -u
}

###############################################################################
# Loginskærmens tema
###############################################################################
# Samme opslag som login-screen.sh: /usr/lib/sddm/sddm.conf.d/ (distro),
# derefter /etc/sddm.conf.d/ sorteret, til sidst /etc/sddm.conf. Den sidste
# fil der sætter nøglen, vinder.

sddm_conf_files() {
    local f
    for f in "${R}"/usr/lib/sddm/sddm.conf.d/*.conf "${R}"/etc/sddm.conf.d/*.conf "${R}/etc/sddm.conf"; do
        [[ -r "$f" ]] && echo "$f"
    done
}

# sddm_conf_value SECTION KEY [--file]: værdien, eller med --file filen den
# kom fra. Sektionsnavnet sammenlignes som tekst: brugt som mønster ville
# "[Theme]" være en tegnklasse, der også rammer [Users] og [General].
sddm_conf_value() {
    local section="$1" key="$2" want="${3:-}" f v found="" from=""
    while read -r f; do
        v="$(awk -F= -v s="[$section]" -v k="$key" '
            /^[[:space:]]*\[/ { h = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", h); insec = (h == s); next }
            insec && $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
                sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); val = $2
            }
            END { if (val != "") print val }' "$f" 2>/dev/null)"
        if [[ -n "$v" ]]; then found="$v"; from="$f"; fi
    done < <(sddm_conf_files)
    if [[ "$want" == --file ]]; then printf '%s' "$from"; else printf '%s' "$found"; fi
}

sddm_theme() {
    local t; t="$(sddm_conf_value Theme Current)"
    printf '%s' "${t:-breeze}"
}

sddm_theme_dir() {
    local d; d="$(sddm_conf_value Theme ThemeDir)"
    printf '%s' "${d:-/usr/share/sddm/themes}"
}

# SDDM 0.21 vælger greeter efter temaets QtVersion. Mangler nøglen, er temaet
# Qt 5. 26.04 har kun Qt 6-greeteren, så et Qt 5-tema kan ikke indlæses, og
# SDDM falder tilbage til et nødtema uden navnefelt.
theme_qt_version() {
    local v=""
    if [[ -r "$1/metadata.desktop" ]]; then
        v="$(sed -n 's/^[[:space:]]*QtVersion[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$1/metadata.desktop" | head -n 1)"
    fi
    printf '%s' "${v:-5}"
}

# theme_problem NAME: skriver hvorfor temaet ikke kan indlæses og returnerer 0,
# eller returnerer 1 hvis det kan.
theme_problem() {
    local dir qt greeter
    dir="$(sddm_theme_dir)/$1"
    if [[ ! -d "${R}${dir}" ]]; then echo "${dir} does not exist"; return 0; fi
    if [[ ! -r "${R}${dir}/Main.qml" ]]; then echo "${dir} has no Main.qml"; return 0; fi
    qt="$(theme_qt_version "${R}${dir}")"
    if [[ "$qt" == 6 ]]; then greeter=/usr/bin/sddm-greeter-qt6; else greeter=/usr/bin/sddm-greeter; fi
    if [[ ! -x "${R}${greeter}" ]]; then
        echo "it is a Qt ${qt} theme, and its greeter ${greeter} is not installed"
        return 0
    fi
    return 1
}

theme_is_packaged() {
    local dir; dir="$(sddm_theme_dir)/$1"
    dpkg -S "${dir}/Main.qml" >/dev/null 2>&1
}

# Slå [Theme] Current fra i én fil. Linjen kommenteres ud i stedet for at
# slettes, så det kan ses hvad der stod, og filen gemmes i sikkerhedskopien.
disable_theme_line() {
    local file="$1" reason="$2" backup tmp
    backup="$(state_get BACKUP_DIR)"
    if [[ -n "$backup" ]]; then
        install -d -m 700 "${backup}/sddm"
        cp -p "$file" "${backup}/sddm/$(basename "$file")"
    fi
    tmp="$(mktemp)"
    awk -v why="$reason" '
        /^[[:space:]]*\[/ { insec = ($0 ~ /^[[:space:]]*\[Theme\]/) }
        insec && /^[[:space:]]*Current[[:space:]]*=/ {
            print "# Disabled by dtu-upgrade-2604: " why
            print "#" $0
            next
        }
        { print }' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Gør temaet indlæseligt, inden maskinen genstarter. Ellers kan kun lokale
# konti logge ind efter opgraderingen.
fix_sddm_theme() {
    local theme why file _
    for _ in 1 2 3 4 5 6 7 8; do
        theme="$(sddm_theme)"
        if ! why="$(theme_problem "$theme")"; then
            ok "Login screen theme '${theme}' can be loaded by the installed greeter"
            return 0
        fi
        warn "Login screen theme '${theme}' cannot be loaded: ${why}"
        file="$(sddm_conf_value Theme Current --file)"
        if [[ -z "$file" || "$file" != "${R}/etc/"* ]]; then
            break
        fi
        disable_theme_line "$file" "${theme}: ${why}"
        if [[ "$(sddm_conf_value Theme Current --file)" == "$file" && "$(sddm_theme)" == "$theme" ]]; then
            warn "Could not switch off Current=${theme} in ${file#"${R}"}"
            break
        fi
        info "Disabled Current=${theme} in ${file#"${R}"} (copy in the backup)"
    done
    # Kommer det vindende tema fra distributionen selv og kan stadig ikke
    # indlæses, låses Breeze fast. Kan heller ikke det, er der intet at gøre.
    if why="$(theme_problem breeze)"; then
        die "No login screen theme can be loaded (breeze: ${why}). Domain users will not be able to log in. Do NOT reboot; contact the DTU Linux team."
    fi
    install -d "${R}/etc/sddm.conf.d"
    printf '# Written by dtu-upgrade-2604: no other theme could be loaded.\n[Theme]\nCurrent=breeze\n' \
        > "${R}/etc/sddm.conf.d/zz-dtu-upgrade-theme.conf"
    ok "Login screen theme pinned to breeze in /etc/sddm.conf.d/zz-dtu-upgrade-theme.conf"
}

###############################################################################
# RepairBooth
###############################################################################

# find_repairbooth_deb DIR: den højeste repairbooth_*+qt6_all.deb i DIR som
# passer med DIR/sha256sums.txt. Intet output hvis ingen gør.
find_repairbooth_deb() {
    local dir="$1" f best="" best_ver="" ver name line
    [[ -r "${dir}/sha256sums.txt" ]] || return 0
    for f in "$dir"/repairbooth_*+qt6_all.deb; do
        [[ -f "$f" ]] || continue
        name="$(basename "$f")"
        line="$(grep -E "[ *]${name//+/\\+}\$" "${dir}/sha256sums.txt" | head -n 1)"
        [[ -n "$line" ]] || continue
        [[ "$(sha256sum < "$f" | cut -d' ' -f1)" == "${line%% *}" ]] || continue
        ver="$(dpkg-deb -f "$f" Version 2>/dev/null)" || continue
        if [[ -z "$best" ]] || dpkg --compare-versions "$ver" gt "$best_ver"; then
            best="$f"; best_ver="$ver"
        fi
    done
    [[ -n "$best" ]] && printf '%s' "$best"
    return 0
}

###############################################################################
# Fase 0: forhåndstjek (ændrer intet)
###############################################################################

BLOCKERS=0
blocker() { fail "$*"; BLOCKERS=$((BLOCKERS + 1)); }

preflight() {
    local mode="$1" ver admins free theme v rb
    step "Checking this machine (nothing is changed yet)"
    BLOCKERS=0

    ver="$(os_value VERSION_ID)"
    if [[ "$(os_value ID)" != ubuntu ]]; then
        blocker "This is not Ubuntu ($(os_value PRETTY_NAME))."
    elif [[ "$mode" == upgrade && "$ver" != "$FROM_VERSION" ]]; then
        blocker "This is Ubuntu ${ver}. The script upgrades ${FROM_VERSION} to ${TARGET_VERSION}."
    else
        ok "Ubuntu ${ver} ($(os_value VERSION_CODENAME))"
    fi

    if [[ -n "${SUDO_USER:-}" ]] && ! getent -s files passwd "$SUDO_USER" >/dev/null 2>&1; then
        blocker "You are logged in as the domain user '${SUDO_USER}'. Log in with a LOCAL admin account: domain logins stop working while SSSD is upgraded, and if this session drops, you cannot get back in."
    else
        ok "Started from a local account (${SUDO_USER:-root})"
    fi

    admins="$(local_admins | tr '\n' ' ')"
    if [[ -z "${admins// /}" ]]; then
        blocker "No local admin account with a password. It is the only way in while SSSD is down, and if the login screen breaks."
    else
        ok "Local admin accounts with a password: ${admins}"
    fi

    if [[ "${DTU_UPGRADE_ALLOW_REMOTE:-}" != 1 ]] && session_is_remote; then
        blocker "This is a remote session (SSH or RDP). Sit at the machine: RDP is restarted during the upgrade, and the disk may ask for its passphrase at the reboot."
    else
        ok "Local session"
    fi

    if on_battery; then
        blocker "The machine is on battery. Plug in the charger."
    else
        ok "On mains power"
    fi

    free="$(df -B1G --output=avail / | tail -n 1 | tr -d ' ')"
    if (( free < MIN_FREE_GB )); then
        blocker "Only ${free} GB free on /. The upgrade needs at least ${MIN_FREE_GB} GB."
    else
        ok "${free} GB free on /"
    fi

    if [[ "$mode" == upgrade ]]; then
        if ! command -v do-release-upgrade >/dev/null 2>&1; then
            blocker "do-release-upgrade is missing: sudo apt install ubuntu-release-upgrader-core"
        fi
        if [[ -e /var/run/reboot-required ]]; then
            blocker "Ubuntu wants a reboot first (updates are waiting). Reboot, then run this again."
        fi
    fi

    v="$(dtu_setup_version)"
    if [[ -z "$v" ]]; then
        warn "DTU Linux Setup is not installed in ${DTU_PREFIX}. No DTU modules will be re-run."
    elif dpkg --compare-versions "$v" lt "$MIN_DTU_SETUP"; then
        blocker "DTU Linux Setup is ${v}. Update it first (\"Update to latest version\"): ${MIN_DTU_SETUP} or newer is needed to re-run the modules on ${TARGET_VERSION}."
    else
        ok "DTU Linux Setup ${v}"
    fi

    MODULES="$(detect_modules)"
    info "DTU modules to re-run afterwards: ${MODULES:-none}"

    theme="$(sddm_theme)"
    if [[ "$mode" == upgrade ]] && [[ -d "${R}$(sddm_theme_dir)/${theme}" ]] && ! theme_is_packaged "$theme"; then
        info "Login screen theme '${theme}' is not from a package and will not load on ${TARGET_VERSION}. It will be switched off before the reboot."
    fi

    HAD_KDEPIM=no; HAD_KNOTES=no; HAD_REPAIRBOOTH=no; RB_DEB=""
    if [[ "$mode" == upgrade ]]; then
        local p
        for p in kmail korganizer kaddressbook kontact akonadi-server; do
            if pkg_installed "$p"; then HAD_KDEPIM=yes; fi
        done
        pkg_installed knotes && HAD_KNOTES=yes
        [[ "$HAD_KDEPIM" == yes ]] && info "KDE PIM (KMail etc.) is installed. The upgrade removes it; it will be reinstalled."
    fi

    if pkg_installed repairbooth; then
        HAD_REPAIRBOOTH=yes
        rb="$(find_repairbooth_deb "$RB_DIR")"
        if [[ -n "$rb" ]]; then
            RB_DEB="$rb"
            ok "RepairBooth for ${TARGET_VERSION}: $(basename "$rb") (checksum OK)"
        elif [[ "$(pkg_version repairbooth)" == *+qt6 ]]; then
            ok "RepairBooth is already the Qt 6 build"
        else
            warn "RepairBooth is installed, but no repairbooth_*+qt6_all.deb with a matching sha256sums.txt in ${RB_DIR}. It will be removed by the upgrade; install the +qt6 build afterwards."
        fi
    fi

    if pkg_installed mdatp && [[ "$(mdatp health --field healthy 2>/dev/null | tr -d '"[:space:]')" != true ]]; then
        warn "Defender reports itself unhealthy before the upgrade. Note it, so it is not blamed on the upgrade."
    fi

    if [[ -n "$(clevis_bindings | grep -i tpm2 || true)" ]]; then
        info "The disk is unlocked by the TPM. If it asks for its passphrase after the reboot, type it; the binding is renewed automatically."
    elif blkid -t TYPE=crypto_LUKS >/dev/null 2>&1; then
        info "The disk is encrypted. You will need its passphrase after the reboot."
    fi

    local foreign_count
    foreign_count="$(foreign_packages 2>/dev/null | wc -l)"
    info "${foreign_count} packages are not from Ubuntu's archive. They are kept, and listed in the backup."

    if (( BLOCKERS > 0 )); then
        echo
        die "${BLOCKERS} problem(s) above must be fixed first. Nothing was changed."
    fi
}

confirm() {
    local mode="$1" answer
    if [[ "$mode" == reconcile ]]; then
        cat <<EOF

${BOLD}About to repair this machine after its upgrade to ${TARGET_VERSION}.${NC}

  - Fixes the login screen theme, re-runs the DTU modules and installs
    RepairBooth's Qt 6 build. All of /etc is saved in /var/backups first.

EOF
    else
        cat <<EOF

${BOLD}About to upgrade this machine from Kubuntu ${FROM_VERSION} to ${TARGET_VERSION}.${NC}

  - It CANNOT be undone. If it fails, the machine has to be reinstalled.
  - It takes about an hour and downloads 3-4 GB. Keep the machine on mains
    power and do not turn it off. Do not use it meanwhile.
  - The desktop may freeze or log out during the upgrade. That does not stop
    it: log in with the local account and run this command again.
  - Know the disk's passphrase before you start, if the disk is encrypted.
  - All of /etc and the package list are saved in /var/backups first.

EOF
    fi
    if [[ "${DTU_UPGRADE_CONFIRM:-}" == UPGRADE ]]; then
        info "Confirmed through DTU_UPGRADE_CONFIRM."
        return 0
    fi
    read -r -p "  Type UPGRADE to start: " answer < /dev/tty || die "No terminal to confirm on. Nothing was changed."
    [[ "$answer" == UPGRADE ]] || die "Not confirmed. Nothing was changed."
}

###############################################################################
# Fase 1: sikkerhedskopi
###############################################################################

do_backup() {
    local dir rc=0
    dir="${R}/var/backups/dtu-upgrade-2604-$(date +%Y%m%d-%H%M%S)"
    step "Saving a backup to ${dir}"
    install -d -m 700 "$dir"
    state_set BACKUP_DIR "$dir"

    # tar returnerer 1 hvis en fil ændrede sig undervejs; det er ikke en fejl.
    tar -C "${R}/" -czf "${dir}/etc.tar.gz" etc 2> "${dir}/etc-tar.log" || rc=$?
    (( rc <= 1 )) || die "Could not save /etc (see ${dir}/etc-tar.log)"
    dpkg --get-selections > "${dir}/dpkg-selections.txt"
    apt-mark showmanual > "${dir}/apt-manual.txt"
    changed_conffiles > "${dir}/conffiles-changed.txt" || true
    changed_ucf_files > "${dir}/ucf-changed.txt" || true
    foreign_packages > "${dir}/foreign-packages.txt" 2>/dev/null || true
    clevis_bindings > "${dir}/clevis.txt" || true
    cat "${R}/etc/os-release" > "${dir}/os-release"
    {
        echo "theme=$(sddm_theme)"
        echo "theme_from=$(sddm_conf_value Theme Current --file)"
    } > "${dir}/sddm-theme.txt"
    echo "${MODULES}" > "${dir}/modules.txt"
    if [[ -n "$RB_DEB" ]]; then
        install -m 600 "$RB_DEB" "${STATE_DIR}/$(basename "$RB_DEB")"
        RB_DEB="${STATE_DIR}/$(basename "$RB_DEB")"
    fi
    ok "Saved $(du -sh "$dir" | cut -f1). Changed configuration files: $(wc -l < "${dir}/conffiles-changed.txt")"

    state_set MODULES "$MODULES"
    state_set HAD_KDEPIM "$HAD_KDEPIM"
    state_set HAD_KNOTES "$HAD_KNOTES"
    state_set HAD_REPAIRBOOTH "$HAD_REPAIRBOOTH"
    state_set RB_DEB "$RB_DEB"
    state_set FROM "$(os_value PRETTY_NAME) (Ubuntu $(os_value VERSION_ID))"
}

###############################################################################
# Fase 2-4 kører som systemtjeneste (--run)
###############################################################################

write_upgrade_policy() {
    # dpkg: pakkens version af en ændret eller slettet konfigurationsfil, uden
    # at spørge. IKKE --force-confdef: sammen med den vinder confdef og
    # beholder den gamle fil i stilhed (efterprøvet 2. oktober 2026).
    install -d "$(dirname "$APT_CONF")"
    cat > "$APT_CONF" <<'EOF'
// Written by dtu-upgrade-2604 for the duration of the upgrade. Removed after.
Dpkg::Options { "--force-confnew"; };
EOF
    # do-release-upgrade læser *.cfg her. Forældede pakker fjernes ikke (det
    # ramte hundredvis, også vores egne), og den genstarter ikke selv.
    install -d "$(dirname "$RU_CFG")"
    cat > "$RU_CFG" <<'EOF'
# Written by dtu-upgrade-2604 for the duration of the upgrade. Removed after.
[Distro]
RemoveObsoletes=False

[NonInteractive]
RealReboot=False
EOF
}

remove_upgrade_policy() {
    rm -f "$APT_CONF" "$RU_CFG"
}

phase_prepare() {
    step "Step 1 of 3: bringing Ubuntu ${FROM_VERSION} up to date"
    dpkg --configure -a --force-confnew --force-confmiss
    apt-get -f install -y

    # Prompt=normal ville sigte mod en mellemudgave, never mod ingenting.
    local ru="${R}/etc/update-manager/release-upgrades"
    if [[ -f "$ru" ]] && ! grep -q '^Prompt=lts$' "$ru"; then
        sed -i 's/^Prompt=.*/Prompt=lts/' "$ru"
        info "Set Prompt=lts in /etc/update-manager/release-upgrades"
    fi

    apt-get update || die "apt-get update failed. Check the network."
    apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade

    # polkitd og pkexec kom ind som afhængigheder af policykit-1, som ikke
    # findes på 26.04. Markeret manuelt, så de ikke fjernes med den.
    local p
    for p in polkitd pkexec; do
        pkg_installed "$p" && apt-mark manual "$p" >/dev/null
    done

    if [[ -e /var/run/reboot-required ]]; then
        state_set PHASE prepared-reboot
        return 0
    fi
    state_set PHASE prepared
    ok "Ubuntu ${FROM_VERSION} is up to date"
}

# Det der skal ske efter at en lokal ucf-fil er lagt tilbage.
after_ucf_restore() {
    case "$1" in
        /etc/default/grub)
            if command -v update-grub >/dev/null 2>&1; then
                if update-grub >/dev/null 2>&1; then
                    ok "update-grub ran with the local /etc/default/grub"
                else
                    warn "update-grub failed with the local /etc/default/grub"
                fi
            fi ;;
        /etc/ssh/sshd_config)
            if ! sshd -t >/dev/null 2>&1; then
                mv -f "${R}$1.ucf-dist" "${R}$1"
                warn "The local sshd_config is not valid for the new OpenSSH; kept the new one. The old one is in the backup."
                return 0
            fi
            systemctl try-reload-or-restart ssh >/dev/null 2>&1 || true ;;
    esac
}

# Læg de lokale udgaver af ucf-filer tilbage, som opgraderingen skiftede ud.
# Den nye ligger ved siden af som .ucf-dist, ucf's eget navn for den.
restore_local_ucf_files() {
    local backup list tmp path
    backup="$(state_get BACKUP_DIR)"
    list="${backup}/ucf-changed.txt"
    [[ -s "$list" ]] || return 0
    tmp="$(mktemp -d)"
    while read -r path; do
        tar -xzf "${backup}/etc.tar.gz" -C "$tmp" "${path#/}" 2>/dev/null || continue
        [[ -f "${R}${path}" ]] || continue
        if cmp -s "${tmp}${path}" "${R}${path}"; then
            continue
        fi
        cp -p "${R}${path}" "${R}${path}.ucf-dist"
        cat "${tmp}${path}" > "${R}${path}"
        ok "Kept the local ${path} (the new one is ${path}.ucf-dist)"
        after_ucf_restore "$path"
    done < "$list"
    rm -rf "$tmp"
}

# Kilder opgraderingen slog fra: omdøbt til .disabled, eller "Enabled: no".
# En .disabled der er lagt tilbage siden (Defender-modulet gør det for
# Microsofts), tæller ikke.
list_disabled_sources() {
    local f
    for f in "${R}"/etc/apt/sources.list.d/*; do
        [[ -f "$f" ]] || continue
        if [[ "$f" == *.disabled ]]; then
            [[ -e "${f%.disabled}" ]] || basename "$f"
        elif [[ "$f" == *.sources ]] && grep -qi '^Enabled: *no' "$f"; then
            basename "$f"
        fi
    done
    return 0
}

sources_point_to_target() {
    grep -rqs -E "\b${TARGET_CODENAME}\b" "${R}/etc/apt/sources.list" "${R}"/etc/apt/sources.list.d/
}

phase_upgrade() {
    local rc=0
    step "Step 2 of 3: upgrading to Kubuntu ${TARGET_VERSION}. This takes about an hour."
    state_set PHASE upgrading
    write_upgrade_policy

    if [[ "$(os_value VERSION_ID)" == "$FROM_VERSION" ]] && ! sources_point_to_target; then
        do-release-upgrade -f DistUpgradeViewNonInteractive || rc=$?
    else
        # Genoptaget efter en afbrudt opgradering: kilderne peger allerede på
        # den nye udgave, så det der mangler, er at gøre pakkerne færdige.
        info "Resuming an interrupted upgrade"
        dpkg --configure -a --force-confnew || rc=$?
        apt-get -f install -y || rc=$?
        apt-get -y full-upgrade || rc=$?
    fi
    remove_upgrade_policy

    if [[ "$(os_value VERSION_ID)" != "$TARGET_VERSION" ]]; then
        die "The upgrade did not complete (exit ${rc}); this is still Ubuntu $(os_value VERSION_ID). See /var/log/dist-upgrade/main.log. Running this command again retries."
    fi
    if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
        warn "Some packages are not fully installed after the upgrade (exit ${rc}); repairing in the next step."
    fi
    state_set PHASE upgraded
    ok "Now Ubuntu $(os_value VERSION_ID)"
}

apt_install() {
    local what="$1"; shift
    if apt-get install -y "$@"; then
        ok "Installed: ${what}"
    else
        warn "Could not install: ${what}"
        # En halv installation blokerer al senere brug af apt.
        apt-get -f install -y >/dev/null 2>&1 || true
    fi
}

run_module() {
    local id="$1" script="${DTU_PREFIX}/scripts/ubuntu/${1}.sh"
    if [[ ! -r "$script" ]]; then
        fail "Module ${id}: ${script} is missing"
        return 1
    fi
    echo "  ---- module ${id} ----"
    if bash "$script" < /dev/null 2>&1 | sed 's/^/  | /'; then
        ok "Module ${id}"
    else
        fail "Module ${id} failed"
        return 1
    fi
}

phase_reconcile() {
    local failed="" m
    step "Step 3 of 3: repairing what the upgrade changed"
    state_set PHASE reconciling
    remove_upgrade_policy

    # Først temaet: det er rene filændringer og det eneste der kan holde
    # domænebrugere ude efter genstarten. Intet efterfølgende må forhindre det.
    fix_sddm_theme

    # En halvinstalleret pakke stopper alle moduler der bruger apt.
    if ! dpkg --configure -a --force-confnew --force-confmiss || ! apt-get -f install -y; then
        warn "dpkg could not finish every package; see the output above"
    fi

    restore_local_ucf_files

    # Overflødige pakker: kun automatisk installerede som intet afhænger af.
    # Alt installeret i hånden, også fremmede pakker, bliver. Nødvendigt før
    # KDE PIM: KF5-rester som ktnef ejer filer det nye KMail har med.
    if [[ "$(state_get HAD_KDEPIM)" == yes ]] && pkg_installed akonadi-backend-mysql; then
        apt-mark manual akonadi-backend-mysql >/dev/null
    fi
    apt-get -s autoremove 2>/dev/null | sed -n 's/^Remv \([^ ]*\).*/\1/p' > "${STATE_DIR}/autoremoved.txt" || true
    if apt-get -y autoremove; then
        ok "Removed $(wc -l < "${STATE_DIR}/autoremoved.txt") packages nothing needs any more (list: ${STATE_DIR#"${R}"}/autoremoved.txt)"
    else
        warn "apt-get autoremove failed"
    fi

    # Det kritiske før det valgfrie: en fejl i KDE PIM må ikke stoppe RDP.
    if apt-cache show plasma-session-x11 >/dev/null 2>&1; then
        apt_install "Plasma (X11) session, needed for RDP" plasma-session-x11
    fi
    local rb; rb="$(state_get RB_DEB)"
    if [[ -n "$rb" && -r "$rb" ]]; then
        apt_install "RepairBooth $(dpkg-deb -f "$rb" Version)" "$rb"
    elif [[ "$(state_get HAD_REPAIRBOOTH)" == yes ]] && [[ "$(pkg_version repairbooth)" != *+qt6 ]]; then
        warn "RepairBooth must be installed again: the +qt6 build"
    fi

    for m in $(state_get MODULES); do
        run_module "$m" || failed+="$m "
    done
    state_set FAILED_MODULES "${failed% }"

    if [[ "$(state_get HAD_KDEPIM)" == yes ]]; then
        # MySQL-motoren skal med: brugernes Akonadi-data ligger i den.
        apt_install "KDE PIM, with Akonadi's MySQL backend" kdepim akonadi-backend-mysql
    fi
    if [[ "$(state_get HAD_KNOTES)" == yes ]] && apt-cache show marknote >/dev/null 2>&1; then
        apt_install "Marknote (KNotes does not exist on ${TARGET_VERSION})" marknote
    fi

    # Tredjepartskilder slår opgraderingen fra. Microsofts lægger
    # Defender-modulet tilbage; de øvrige vises i rapporten.
    list_disabled_sources > "${STATE_DIR}/disabled-sources.txt"

    {
        echo "DTU_UPGRADED_FROM=\"$(state_get FROM)\""
        echo "DTU_UPGRADED_ON=$(date +%Y-%m-%d)"
    } >> "${R}/etc/dtu-image-version"

    state_set BOOT_ID "$(cat /proc/sys/kernel/random/boot_id)"
    state_set PHASE reconciled
    if [[ -n "$failed" ]]; then
        warn "Modules that failed: ${failed}. The check after the reboot will list them."
    fi
}

run_service() {
    exec > >(tee -a "$LOG") 2>&1
    trap 'rc=$?; remove_upgrade_policy; echo "$rc" > "${STATE_DIR}/run.exit"' EXIT
    echo "---- $(date '+%F %T') dtu-upgrade-2604 --run, phase $(state_get PHASE) ----"
    local phase; phase="$(state_get PHASE)"
    if [[ "$phase" == confirmed || "$phase" == prepared-reboot ]]; then
        phase_prepare
        phase="$(state_get PHASE)"
        [[ "$phase" == prepared-reboot ]] && return 0
    fi
    if [[ "$phase" == prepared || "$phase" == upgrading ]]; then
        phase_upgrade
        phase="$(state_get PHASE)"
    fi
    if [[ "$phase" == upgraded || "$phase" == reconciling ]]; then
        phase_reconcile
    fi
}

###############################################################################
# Fase 5: kontrol efter genstarten
###############################################################################

VERIFY_FAILS=0
REPORT=""
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "$desc"; echo "OK    $desc" >> "$REPORT"
    else
        fail "$desc"; echo "FAIL  $desc" >> "$REPORT"
        VERIFY_FAILS=$((VERIFY_FAILS + 1))
    fi
}

is_target()          { [[ "$(os_value VERSION_ID)" == "$TARGET_VERSION" ]]; }
dpkg_clean()         { [[ -z "$(dpkg --audit 2>/dev/null)" ]]; }
no_policy_left()     { [[ ! -e "$APT_CONF" && ! -e "$RU_CFG" ]]; }
theme_loads()        { ! theme_problem "$(sddm_theme)"; }
greeter_no_fallback() { ! journalctl -b -u sddm --no-pager 2>/dev/null | grep -q 'Using fallback theme'; }
no_failed_modules()  { [[ -z "$(state_get FAILED_MODULES)" ]]; }
ms_source_present()  { compgen -G "${R}/etc/apt/sources.list.d/microsoft-prod.*" >/dev/null; }
mdatp_enrolled()     { [[ "$(mdatp health --field licensed 2>/dev/null | tr -d '"[:space:]')" == true ]]; }
mdatp_healthy()      { [[ "$(mdatp health --field healthy 2>/dev/null | tr -d '"[:space:]')" == true ]]; }
repairbooth_qt6()    { [[ "$(pkg_version repairbooth)" == *+qt6 ]]; }
kdepim_back()        { pkg_installed kmail && pkg_installed akonadi-backend-mysql; }
clevis_unchanged() {
    local before; before="$(state_get BACKUP_DIR)/clevis.txt"
    [[ ! -s "$before" ]] || diff -q <(grep -v '^$' "$before") <(clevis_bindings | grep -v '^$')
}

phase_verify() {
    local modules
    REPORT="${STATE_DIR}/report-$(date +%Y%m%d-%H%M%S).txt"
    install -d -m 700 "$STATE_DIR"
    : > "$REPORT"
    step "Checking the result"
    {
        echo "DTU upgrade to Kubuntu ${TARGET_VERSION}: $(hostname), $(date '+%F %T')"
        echo "From: $(state_get FROM)"
        echo
    } >> "$REPORT"
    VERIFY_FAILS=0
    modules=" $(state_get MODULES) "

    check "This is Ubuntu ${TARGET_VERSION}"                          is_target
    check "All packages are fully installed (dpkg --audit is empty)"  dpkg_clean
    check "The temporary upgrade settings are gone"                   no_policy_left
    check "The login screen theme can be loaded ($(sddm_theme))"      theme_loads
    check "The login screen did not fall back to SDDM's emergency theme" greeter_no_fallback
    check "SDDM is running"                                           systemctl is-active sddm
    if [[ -e /etc/sssd/sssd.conf ]]; then
        check "SSSD is running (domain logins)"                       systemctl is-active sssd
    fi
    check "Every DTU module re-ran without errors ($(state_get MODULES))" no_failed_modules
    if [[ "$modules" == *" rdp "* ]]; then
        check "xrdp is running"                                       systemctl is-active xrdp
        check "The Plasma X11 session for RDP is installed"           command -v startplasma-x11
    fi
    if [[ "$modules" == *" defender "* ]]; then
        check "Microsoft's package source is present"                 ms_source_present
        check "Defender reports itself healthy"                       mdatp_healthy
        check "Defender reports the machine as enrolled"              mdatp_enrolled
    fi
    if [[ "$(state_get HAD_REPAIRBOOTH)" == yes ]]; then
        check "RepairBooth is the Qt 6 build"                         repairbooth_qt6
    fi
    if [[ "$(state_get HAD_KDEPIM)" == yes ]]; then
        check "KMail and Akonadi's MySQL backend are installed"       kdepim_back
    fi
    check "The disk's TPM bindings are unchanged"                     clevis_unchanged

    {
        echo
        echo "Check by hand:"
        echo "  - Log in as a domain user: type the name in the login screen."
        echo "  - As a domain IT admin: 'sudo -l' lists the admin rights (sudo is now sudo-rs)."
        [[ "$modules" == *" rdp "* ]] && echo "  - Connect with RDP from another machine: the desktop appears, not a black screen."
        [[ "$(state_get HAD_KDEPIM)" == yes ]] && echo "  - KMail, as a user who had mail: the mail and local folders are there."
        if [[ -s "${STATE_DIR}/disabled-sources.txt" ]]; then
            echo "  - These package sources were switched off by the upgrade; turn on the ones still needed:"
            sed 's/^/      /' "${STATE_DIR}/disabled-sources.txt"
        fi
        echo
        echo "Backup: $(state_get BACKUP_DIR)"
        echo "Logs:   ${LOG#"${R}"} and /var/log/dist-upgrade/"
    } >> "$REPORT"
    sed -n '/^Check by hand:/,$p' "$REPORT"

    echo
    if (( VERIFY_FAILS == 0 )); then
        state_set PHASE verified
        ok "${BOLD}The upgrade is complete.${NC} Report: ${REPORT}"
    else
        state_set PHASE verified-with-errors
        die "${VERIFY_FAILS} check(s) failed. Report: ${REPORT}"
    fi
}

###############################################################################
# Styring
###############################################################################

install_self() {
    local src="${BASH_SOURCE[0]:-}"
    if [[ -z "$src" || ! -f "$src" ]]; then
        die "Download the script and run it as a file; it cannot be piped into bash, because it must run again after the reboot."
    fi
    install -d -m 700 "$STATE_DIR"
    if [[ "$(readlink -f "$src")" != "$(readlink -f "$SELF")" ]]; then
        install -m 700 "$src" "$SELF"
    fi
    if [[ ! -e /usr/bin/dtu-upgrade-2604 ]]; then
        ln -sf "$SELF" /usr/local/sbin/dtu-upgrade-2604
    fi
}

start_service() {
    rm -f "${STATE_DIR}/run.exit"
    systemd-run --unit="$UNIT" --collect --quiet \
        --description="DTU in-place upgrade to Kubuntu ${TARGET_VERSION}" \
        --property=Type=exec --property=StandardInput=null \
        --setenv=DEBIAN_FRONTEND=noninteractive \
        --setenv=DTU_PREFIX="$DTU_PREFIX" \
        /bin/bash "$SELF" --run
}

follow_service() {
    local inv jpid
    echo
    info "The upgrade runs as the system service '${UNIT}'. Closing this window does not"
    info "stop it. Run 'sudo dtu-upgrade-2604' again to follow it."
    echo
    inv="$(systemctl show -p InvocationID --value "$UNIT" 2>/dev/null || true)"
    if [[ -n "$inv" ]]; then
        journalctl -f -n 40 -o cat "_SYSTEMD_INVOCATION_ID=${inv}" &
    else
        journalctl -f -n 40 -o cat -u "$UNIT" &
    fi
    jpid=$!
    while systemctl is-active --quiet "$UNIT"; do sleep 5; done
    sleep 2
    kill "$jpid" 2>/dev/null || true
    wait "$jpid" 2>/dev/null || true
    after_run_message
}

after_run_message() {
    local phase rc
    phase="$(state_get PHASE)"
    rc="$(cat "${STATE_DIR}/run.exit" 2>/dev/null || echo '?')"
    echo
    case "$phase" in
        prepared-reboot)
            step "Ubuntu ${FROM_VERSION} needs a reboot before the upgrade"
            info "Reboot, log in with the LOCAL account, and run 'sudo dtu-upgrade-2604' again."
            ;;
        reconciled)
            step "Upgraded. Now reboot."
            info "Reboot:  sudo reboot"
            info "If the disk asks for its passphrase, type it."
            info "Then log in with the LOCAL account and run 'sudo dtu-upgrade-2604' once more."
            info "That checks the result and writes a report."
            ;;
        *)
            step "The upgrade stopped (phase '${phase}', exit ${rc})"
            info "Log: ${LOG#"${R}"}   Upgrader's log: /var/log/dist-upgrade/main.log"
            info "Do NOT reboot before it is resolved. Running 'sudo dtu-upgrade-2604' again retries from where it stopped."
            return 1
            ;;
    esac
}

show_status() {
    local phase; phase="$(state_get PHASE)"
    echo "Phase:   ${phase:-not started}"
    echo "Ubuntu:  $(os_value VERSION_ID)"
    echo "Running: $(systemctl is-active "$UNIT" 2>/dev/null || true)"
    echo "Backup:  $(state_get BACKUP_DIR)"
    echo "Log:     ${LOG#"${R}"}"
}

new_upgrade() {
    local mode=upgrade
    if [[ "$(os_value VERSION_ID)" == "$TARGET_VERSION" ]]; then
        # Opgraderet i hånden: kun reparationsdelen. Hvad der var installeret
        # før, kan ikke længere ses, så KDE PIM geninstalleres ikke.
        mode=reconcile
        step "This machine is already Ubuntu ${TARGET_VERSION}"
        info "Only the repair step will run: login screen theme, DTU modules, RepairBooth."
    fi
    preflight "$mode"
    confirm "$mode"
    do_backup
    if [[ "$mode" == reconcile ]]; then
        state_set FROM "unknown (already ${TARGET_VERSION} when the script was first run)"
        state_set PHASE upgraded
    else
        state_set PHASE confirmed
    fi
    start_service
    follow_service
}

main() {
    local action=auto
    RB_DIR="$PWD"
    while (( $# > 0 )); do
        case "$1" in
            --run)    action=run ;;
            --status) action=status ;;
            --verify) action=verify ;;
            --repairbooth-dir)
                [[ $# -ge 2 ]] || die "--repairbooth-dir needs a folder"
                RB_DIR="$2"; shift ;;
            -h|--help) sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
    [[ $EUID -eq 0 ]] || die "Run it with sudo: sudo dtu-upgrade-2604"

    case "$action" in
        run)    run_service; return ;;
        status) show_status; return ;;
    esac
    install_self
    if [[ "$action" == verify ]]; then phase_verify; return; fi

    if systemctl is-active --quiet "$UNIT"; then
        follow_service
        return
    fi
    local phase; phase="$(state_get PHASE)"
    case "$phase" in
        "")
            new_upgrade ;;
        prepared-reboot)
            if [[ -e /var/run/reboot-required ]]; then
                after_run_message
            else
                start_service; follow_service
            fi ;;
        confirmed|prepared|upgrading|upgraded|reconciling)
            info "Resuming from phase '${phase}'"
            start_service; follow_service ;;
        reconciled)
            if [[ "$(cat /proc/sys/kernel/random/boot_id)" == "$(state_get BOOT_ID)" ]]; then
                after_run_message
            else
                phase_verify
            fi ;;
        verified|verified-with-errors)
            phase_verify ;;
        *)
            die "Unknown phase '${phase}' in ${STATE_FILE}" ;;
    esac
}

if [[ "${DTU_UPGRADE_LIB:-}" != 1 ]]; then
    main "$@"
fi
