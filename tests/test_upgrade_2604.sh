#!/usr/bin/env bash
###############################################################################
# Tests for bin/dtu-upgrade-2604.sh, without root and without upgrading.
#
# The script's functions are loaded with DTU_UPGRADE_LIB=1 and run against
# synthetic root trees (DTU_UPGRADE_ROOT). What is tested here is the logic
# that decides things: which login screen theme wins and whether it can load,
# which DTU modules a machine has, which RepairBooth package is used, and the
# rules the upgrade itself runs under. The upgrade is tested in a VM.
#
# Run with: bash tests/test_upgrade_2604.sh
###############################################################################
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/dtu-upgrade-2604.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_()  { printf '  \033[0;32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad_() { printf '  \033[0;31m✗\033[0m %s\n' "$1"; printf '      %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad_ "$1" "expected [$2], got [$3]"; fi; }
has()   { if [[ "$3" == *"$2"* ]]; then ok_ "$1"; else bad_ "$1" "missing [$2] in: $3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok_ "$1"; else bad_ "$1" "found [$2] in: $3"; fi; }

# lib ROOT CODE: run CODE with the script's functions, against ROOT
lib() {
    DTU_UPGRADE_LIB=1 DTU_UPGRADE_ROOT="$1" bash -c "source '$SCRIPT'; $2" 2>&1
}

# A theme folder: mktheme ROOT NAME [QTVERSION]
mktheme() {
    local d="$1/usr/share/sddm/themes/$2"
    mkdir -p "$d"; : > "$d/Main.qml"
    printf '[SddmGreeterTheme]\nName=%s\n' "$2" > "$d/metadata.desktop"
    if [[ -n "${3:-}" ]]; then printf 'QtVersion=%s\n' "$3" >> "$d/metadata.desktop"; fi
}
# A greeter binary: mkgreeter ROOT qt5|qt6
mkgreeter() {
    mkdir -p "$1/usr/bin"
    local g="$1/usr/bin/sddm-greeter"; [[ "$2" == qt6 ]] && g+="-qt6"
    printf '#!/bin/sh\n' > "$g"; chmod +x "$g"
}
conf() { mkdir -p "$(dirname "$1/$2")"; printf '%b' "$3" > "$1/$2"; }

echo "── login screen theme: which one wins ───────────────────────────"
T="$TMP/t1"
conf "$T" usr/lib/sddm/sddm.conf.d/20-kubuntu.conf '[Theme]\nCurrent=kubuntu\n'
conf "$T" etc/sddm.conf.d/kde_settings.conf '[Autologin]\nRelogin=false\n\n[Theme]\nCurrent=pixel-dusk-city-qt5\n'
check "/etc/sddm.conf.d beats the distribution's /usr/lib" "pixel-dusk-city-qt5" "$(lib "$T" sddm_theme)"
check "and the file it came from is reported" "$T/etc/sddm.conf.d/kde_settings.conf" \
    "$(lib "$T" 'sddm_conf_value Theme Current --file')"
conf "$T" etc/sddm.conf '[Theme]\nCurrent=elarun\n'
check "/etc/sddm.conf is read last and wins" "elarun" "$(lib "$T" sddm_theme)"
rm "$T/etc/sddm.conf"
conf "$T" etc/sddm.conf.d/zz-other.conf '[Users]\nCurrent=not-a-theme\n'
check "a Current key in another section does not count" "pixel-dusk-city-qt5" "$(lib "$T" sddm_theme)"
check "no Current anywhere means breeze" "breeze" "$(lib "$TMP/empty" sddm_theme)"

# login-screen.sh has its own copy of the lookup, with the paths written out.
# Used as an awk pattern, "[Theme]" was a character class and matched any
# header with a T, h, e or m in it, such as [Users].
ls_lookup="$(sed -n '/^sddm_conf_value() {/,/^}/p' "$REPO_ROOT/scripts/ubuntu/login-screen.sh" |
    sed -e "s#/usr/lib/sddm#$T/usr/lib/sddm#g" -e "s#/etc/sddm#$T/etc/sddm#g")"
check "login-screen.sh's copy ignores other sections too" "pixel-dusk-city-qt5" \
    "$(bash -c "$ls_lookup; sddm_conf_value Theme Current" 2>&1)"

echo
echo "── login screen theme: can the greeter load it ──────────────────"
# 26.04: only the Qt 6 greeter. Finding 3i on SUS-EL-MPARK1.
mkgreeter "$T" qt6
mktheme "$T" kubuntu 6
mktheme "$T" breeze 6
mktheme "$T" pixel-dusk-city-qt5
has "a theme without QtVersion is Qt 5 and cannot load on 26.04" \
    "Qt 5 theme, and its greeter /usr/bin/sddm-greeter is not installed" \
    "$(lib "$T" 'theme_problem pixel-dusk-city-qt5')"
check "a QtVersion=6 theme loads on 26.04" "loads" \
    "$(lib "$T" 'theme_problem kubuntu >/dev/null && echo broken || echo loads')"
has "a theme folder that is gone cannot load" "does not exist" "$(lib "$T" 'theme_problem ubuntu-theme')"
# 24.04: the Qt 5 greeter, themes without QtVersion.
T24="$TMP/t24"; mkgreeter "$T24" qt5; mktheme "$T24" breeze
check "on 24.04 a theme without QtVersion loads" "loads" \
    "$(lib "$T24" 'theme_problem breeze >/dev/null && echo broken || echo loads')"

echo
echo "── login screen theme: the repair before the reboot ─────────────"
mkdir -p "$T/var/lib/dtu-upgrade-2604" "$T/backup"
printf 'BACKUP_DIR=%s\n' "$T/backup" > "$T/var/lib/dtu-upgrade-2604/state"
out="$(lib "$T" fix_sddm_theme)"; rc=$?
check "the repair succeeds" "0" "$rc"
has "it says which theme was switched off and why" "Disabled Current=pixel-dusk-city-qt5" "$out"
check "afterwards the distribution's theme wins" "kubuntu" "$(lib "$T" sddm_theme)"
has "the line is commented out, not deleted" "#Current=pixel-dusk-city-qt5" "$(cat "$T/etc/sddm.conf.d/kde_settings.conf")"
has "the other sections of the file are kept" "Relogin=false" "$(cat "$T/etc/sddm.conf.d/kde_settings.conf")"
has "the original file is in the backup" "Current=pixel-dusk-city-qt5" "$(cat "$T/backup/sddm/kde_settings.conf" 2>/dev/null)"
out="$(lib "$T" fix_sddm_theme)"
has "running it again changes nothing" "'kubuntu' can be loaded" "$out"

# Two bad themes in /etc, and the distribution's own one gone as well
T2="$TMP/t2"; mkgreeter "$T2" qt6; mktheme "$T2" breeze 6; mktheme "$T2" old-a; mktheme "$T2" old-b
conf "$T2" etc/sddm.conf.d/kde_settings.conf '[Theme]\nCurrent=old-a\n'
conf "$T2" etc/sddm.conf '[Theme]\nCurrent=old-b\n'
conf "$T2" usr/lib/sddm/sddm.conf.d/20-kubuntu.conf '[Theme]\nCurrent=ubuntu-theme\n'
out="$(lib "$T2" fix_sddm_theme)"; rc=$?
check "with no loadable theme left in /etc, the repair still succeeds" "0" "$rc"
check "by pinning breeze in a file that sorts last" "breeze" "$(lib "$T2" sddm_theme)"
has "and says so" "pinned to breeze" "$out"

T3="$TMP/t3"; mkgreeter "$T3" qt6; mktheme "$T3" old-a
conf "$T3" etc/sddm.conf.d/kde_settings.conf '[Theme]\nCurrent=old-a\n'
out="$(lib "$T3" fix_sddm_theme)"; rc=$?
check "with nothing loadable at all, it stops" "1" "$rc"
has "and says not to reboot" "Do NOT reboot" "$out"

echo
echo "── which DTU modules the machine has ────────────────────────────"
M="$TMP/m"
check "a bare machine has none" "" "$(lib "$M" 'pkg_installed() { return 1; }; detect_modules')"
conf "$M" etc/polkit-1/rules.d/45-xrdp.rules ''
conf "$M" etc/sddm.conf.d/zz-dtu-domain-login.conf ''
conf "$M" etc/sudoers.d/dtu-it-admins ''
conf "$M" etc/xdg/autostart/dtu-first-login.desktop ''
conf "$M" usr/local/sbin/pdrev-session.sh ''
check "each module is found by what it leaves behind" \
    "rdp login-screen polkit defender first-login-deploy automount" \
    "$(lib "$M" 'pkg_installed() { [[ $1 == mdatp ]]; }; detect_modules')"
check "Defender only when mdatp is installed" "rdp login-screen polkit first-login-deploy automount" \
    "$(lib "$M" 'pkg_installed() { return 1; }; detect_modules')"
for m in rdp login-screen polkit defender first-login-deploy automount; do
    if [[ -f "$REPO_ROOT/scripts/ubuntu/$m.sh" ]]; then ok_ "module $m exists as scripts/ubuntu/$m.sh"
    else bad_ "module $m exists as scripts/ubuntu/$m.sh"; fi
done

echo
echo "── state survives a reboot ──────────────────────────────────────"
S="$TMP/s"
lib "$S" 'state_set PHASE confirmed; state_set MODULES "rdp polkit"; state_set PHASE upgrading' >/dev/null
check "the last value wins" "upgrading" "$(lib "$S" 'state_get PHASE')"
check "values with spaces are kept" "rdp polkit" "$(lib "$S" 'state_get MODULES')"
check "one line per key" "1" "$(grep -c '^PHASE=' "$S/var/lib/dtu-upgrade-2604/state")"
check "a missing key is empty, not an error" "|0" "$(lib "$S" 'v=$(state_get NOPE); echo "$v|$?"')"
check "the state folder is root-only" "700" "$(stat -c %a "$S/var/lib/dtu-upgrade-2604")"

echo
echo "── RepairBooth: the right package, and only a verified one ──────"
RB="$TMP/rb"; mkdir -p "$RB"
mkdeb() { # mkdeb VERSION → $RB/repairbooth_VERSION_all.deb
    local d="$TMP/debsrc/$1"; mkdir -p "$d/DEBIAN"
    printf 'Package: repairbooth\nVersion: %s\nArchitecture: all\nMaintainer: t <t@t>\nDescription: t\n' "$1" > "$d/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$d" "$RB/repairbooth_$1_all.deb" >/dev/null
}
mkdeb 0.5.0+qt6; mkdeb 0.10.0+qt6; mkdeb 0.11.0+qt5
(cd "$RB" && sha256sum -- *.deb > sha256sums.txt)
check "the highest +qt6 version, compared as versions" "repairbooth_0.10.0+qt6_all.deb" \
    "$(basename "$(lib / "find_repairbooth_deb '$RB'")")"
printf 'x' >> "$RB/repairbooth_0.10.0+qt6_all.deb"
check "a package that does not match its checksum is skipped" "repairbooth_0.5.0+qt6_all.deb" \
    "$(basename "$(lib / "find_repairbooth_deb '$RB'")")"
grep -v '0.5.0' "$RB/sha256sums.txt" > "$RB/s" && mv "$RB/s" "$RB/sha256sums.txt"
check "a package missing from sha256sums.txt is skipped" "" "$(lib / "find_repairbooth_deb '$RB'")"
rm "$RB/sha256sums.txt"
check "no sha256sums.txt, no package" "" "$(lib / "find_repairbooth_deb '$RB'")"

echo
echo "── the rules the upgrade runs under ─────────────────────────────"
P="$TMP/p"
lib "$P" write_upgrade_policy >/dev/null
apt="$(cat "$P/etc/apt/apt.conf.d/99dtu-upgrade-2604" 2>/dev/null)"
cfg="$(cat "$P/etc/update-manager/release-upgrades.d/dtu-upgrade-2604.cfg" 2>/dev/null)"
has "dpkg takes the package's configuration files" '"--force-confnew"' "$apt"
lacks "and NOT --force-confdef, which would silently keep the old ones" 'confdef' \
    "$(grep -v '^//' "$P/etc/apt/apt.conf.d/99dtu-upgrade-2604")"
has "obsolete packages are not removed" "RemoveObsoletes=False" "$cfg"
has "the upgrader does not reboot by itself" "RealReboot=False" "$cfg"
lib "$P" remove_upgrade_policy >/dev/null
check "both are removed again afterwards" "" "$(find "$P" -type f)"
body="$(grep -v '^\s*#' "$SCRIPT")"
has "the upgrade itself runs non-interactively" "do-release-upgrade -f DistUpgradeViewNonInteractive" "$body"
lacks "and never with -d (that would aim at the development release)" "do-release-upgrade -d" "$body"
lacks "no UCF_FORCE_CONFFOLD: ucf follows dpkg's --force-confnew and ignores it" "UCF_FORCE_CONFFOLD" "$body"
has "the policy is removed even if the run fails" "trap 'rc=\$?; remove_upgrade_policy" "$body"

echo
echo "── ucf files changed by hand get their local version back ───────"
# Seen in the VM test on 2 Oct 2026: ucf replaced a locally changed
# /etc/default/grub "since you asked for it", because it reads dpkg's
# --force-confnew from DPKG_FORCE.
U="$TMP/u"; mkdir -p "$U/etc/default" "$U/etc/ssh" "$U/var/lib/ucf" "$U/bk"
printf 'GRUB_DISTRIBUTOR=Kubuntu\n' > "$U/etc/default/grub"
printf 'PasswordAuthentication no\n' > "$U/etc/ssh/sshd_config"
printf 'untouched\n' > "$U/etc/untouched.conf"
{
    printf '%s  /etc/default/grub\n' "$(printf 'GRUB_DISTRIBUTOR=Ubuntu\n' | md5sum | cut -d' ' -f1)"
    printf '%s  /etc/ssh/sshd_config\n' "$(printf 'PasswordAuthentication yes\n' | md5sum | cut -d' ' -f1)"
    printf '%s  /etc/untouched.conf\n' "$(md5sum < "$U/etc/untouched.conf" | cut -d' ' -f1)"
    printf '%s  /usr/share/not-etc.conf\n' 0123
} > "$U/var/lib/ucf/hashfile"
check "the locally changed ucf files are found, and only those in /etc" \
    "/etc/default/grub /etc/ssh/sshd_config" "$(lib "$U" changed_ucf_files | xargs)"
lib "$U" changed_ucf_files > "$U/bk/ucf-changed.txt"
tar -C "$U" -czf "$U/bk/etc.tar.gz" etc
mkdir -p "$U/var/lib/dtu-upgrade-2604"; printf 'BACKUP_DIR=%s\n' "$U/bk" > "$U/var/lib/dtu-upgrade-2604/state"
# The upgrade replaces both with the package's version
printf 'GRUB_DISTRIBUTOR=Ubuntu\n' > "$U/etc/default/grub"
printf 'PasswordAuthentication yes\n' > "$U/etc/ssh/sshd_config"
out="$(lib "$U" 'after_ucf_restore() { echo "AFTER $1"; }; restore_local_ucf_files')"
check "the local /etc/default/grub is back" "GRUB_DISTRIBUTOR=Kubuntu" "$(cat "$U/etc/default/grub")"
check "the new one is kept beside it as .ucf-dist" "GRUB_DISTRIBUTOR=Ubuntu" "$(cat "$U/etc/default/grub.ucf-dist" 2>/dev/null)"
check "a hardened sshd_config is back too" "PasswordAuthentication no" "$(cat "$U/etc/ssh/sshd_config")"
has "and each file gets its follow-up (update-grub, sshd -t)" "AFTER /etc/default/grub" "$out"
out="$(lib "$U" 'after_ucf_restore() { echo "AFTER $1"; }; restore_local_ucf_files')"
lacks "running it again changes nothing" "AFTER" "$out"
# A local sshd_config the new OpenSSH rejects is not forced on it
printf 'PasswordAuthentication yes\n' > "$U/etc/ssh/sshd_config"; rm -f "$U/etc/ssh/sshd_config.ucf-dist"
lib "$U" 'sshd() { return 1; }; systemctl() { :; }; restore_local_ucf_files' >/dev/null
check "a local sshd_config that sshd -t rejects gives way to the new one" "PasswordAuthentication yes" \
    "$(cat "$U/etc/ssh/sshd_config")"

echo
echo "── package sources the upgrade switched off ─────────────────────"
D="$TMP/d"; mkdir -p "$D/etc/apt/sources.list.d" "$D/var/lib/dtu-upgrade-2604"
touch "$D/etc/apt/sources.list.d/"{vscode.list.disabled,microsoft-prod.list.disabled,microsoft-prod.list,ubuntu.sources}
printf 'Types: deb\nEnabled: no\n' > "$D/etc/apt/sources.list.d/chrome.sources"
check "renamed .disabled files and Enabled: no are listed, not ones put back since" \
    "chrome.sources vscode.list.disabled" "$(lib "$D" list_disabled_sources | sort | xargs)"

echo
echo "── order of the repair step ─────────────────────────────────────"
rec="$(sed -n '/^phase_reconcile() {/,/^}/p' "$SCRIPT" | grep -v '^\s*#')"
first="$(grep -n -m1 -E 'fix_sddm_theme|dpkg |apt-get|run_module' <<<"$rec" | cut -d: -f2- | xargs)"
check "the login screen is repaired before anything that can fail" "fix_sddm_theme" "$first"
pos() { grep -n -m1 -e "$1" <<<"$rec" | cut -d: -f1; }
if (( $(pos 'apt-get -y autoremove') < $(pos 'kdepim akonadi-backend-mysql') )); then
    ok_ "autoremove runs before KDE PIM (ktnef held /usr/bin/ktnef, which the new kmail ships)"
else bad_ "autoremove runs before KDE PIM"; fi
if (( $(pos 'run_module') < $(pos 'kdepim akonadi-backend-mysql') && $(pos '"$rb"$') < $(pos 'kdepim akonadi-backend-mysql') )); then
    ok_ "RepairBooth and the modules come before KDE PIM, so a failure there cannot block them"
else bad_ "RepairBooth and the modules come before KDE PIM"; fi

echo
echo "─────────────────────────────────────────────────────────────────"
printf "%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
