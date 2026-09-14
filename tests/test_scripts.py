"""Static and behavioural checks on the shell scripts.

Every test here exists because the bug it describes actually shipped. Shell
has no type checker and these scripts run as root on other people's
machines, so the checks are deliberately mechanical: they look at what the
scripts say, not at what the comments claim.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"

ALL_SH = sorted(p for p in SCRIPTS.rglob("*.sh") if p.is_file())


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def strip_comments(text: str) -> str:
    """Blank out comment bodies, keeping line structure.

    Tests that hunt for a pattern must look at the code, not at the comment
    explaining why the pattern is wrong. One test already passed on its own
    docstring before this existed.
    """
    out = []
    for line in text.splitlines():
        stripped = line.lstrip()
        out.append("" if stripped.startswith("#") else line)
    return "\n".join(out)


class TestSyntax(unittest.TestCase):
    def test_every_script_parses(self):
        for path in ALL_SH:
            with self.subTest(script=path.relative_to(REPO)):
                proc = subprocess.run(["bash", "-n", str(path)],
                                      capture_output=True, text=True)
                self.assertEqual(proc.returncode, 0, proc.stderr)


class TestSetETraps(unittest.TestCase):
    """`set -e` plus an && list as the last statement of a function.

    The function returns 1 when the condition is false, and the whole script
    dies without printing anything, because nothing went wrong -- something
    merely returned 1. The standalone printer script did exactly this: you
    pressed Enter to skip the plotter and it silently stopped before asking
    for the credentials it existed to collect.
    """

    def _functions(self, text: str):
        """Yield (name, body_lines) for `name() { ... }` at column 0."""
        lines = text.splitlines()
        i = 0
        while i < len(lines):
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{\s*$", lines[i])
            if not m:
                i += 1
                continue
            body, j = [], i + 1
            while j < len(lines) and lines[j] != "}":
                body.append(lines[j])
                j += 1
            yield m.group(1), body
            i = j + 1

    def test_no_function_ends_on_a_conditional_and_list(self):
        offenders = []
        for path in ALL_SH:
            text = strip_comments(read(path))
            if "set -e" not in text and "set -euo" not in text:
                continue
            for name, body in self._functions(text):
                tail = [l for l in body if l.strip()]
                if not tail:
                    continue
                last = tail[-1].strip()
                if not re.match(r"^\[\[.*\]\]\s*&&\s*", last):
                    continue
                # A trailing return/exit/true makes the status explicit.
                if re.search(r"\b(return|exit)\b|\|\|\s*true", last):
                    continue
                offenders.append(
                    f"{path.relative_to(REPO)}: {name}(): {last}")
        self.assertEqual(offenders, [], "\n".join(
            ["a false condition here returns 1 and set -e kills the script:"]
            + offenders))


class TestCifsMountOptions(unittest.TestCase):
    """Automounts without a timeout are what froze the AIT machines.

    A systemd automount intercepts every access to the path and the caller
    sleeps uninterruptibly until the mount succeeds or times out. With no
    x-systemd.mount-timeout the default is 90 seconds; it had been set to 30
    in one place and left out entirely in another. Either reads as a frozen
    desktop.
    """

    FSTAB_LINE = re.compile(r'^\s*(?:local\s+)?\w*(?:LINE|line)\s*=\s*"//.*cifs.*"',
                            re.MULTILINE)

    def _cifs_lines(self):
        for path in ALL_SH:
            text = strip_comments(read(path))
            for match in self.FSTAB_LINE.finditer(text):
                yield path, match.group(0)

    def test_every_fstab_line_has_a_mount_timeout(self):
        bad = []
        for path, line in self._cifs_lines():
            if "x-systemd.automount" not in line and "CIFS_SYSTEMD_OPTS" not in line:
                continue
            if "CIFS_SYSTEMD_OPTS" in line:
                continue          # the constant carries it; checked below
            if "x-systemd.mount-timeout" not in line:
                bad.append(f"{path.relative_to(REPO)}: {line.strip()[:90]}")
        self.assertEqual(bad, [], "\n".join(
            ["CIFS automount without a mount timeout — every access to the "
             "path blocks for systemd's 90s default:"] + bad))

    def test_the_shared_options_carry_a_short_timeout(self):
        common = read(SCRIPTS / "common.sh")
        m = re.search(r'CIFS_SYSTEMD_OPTS="([^"]+)"', common)
        self.assertIsNotNone(m, "CIFS_SYSTEMD_OPTS is gone")
        opts = m.group(1)
        self.assertIn("nofail", opts,
                      "without nofail a dead share blocks boot")
        t = re.search(r"x-systemd\.mount-timeout=(\d+)", opts)
        self.assertIsNotNone(t, "no mount timeout in CIFS_SYSTEMD_OPTS")
        self.assertLessEqual(
            int(t.group(1)), 15,
            "a desktop stalled this long reads as a crash, not a slow folder")

    def test_the_shared_options_are_actually_used(self):
        """qdrive.sh used to hardcode its own option string without a
        timeout while the constant next to it had one."""
        qdrive = strip_comments(read(SCRIPTS / "ubuntu" / "qdrive.sh"))
        for line in re.findall(r'^\s*\w*(?:LINE|line)\s*=\s*"//.*cifs.*"',
                               qdrive, re.MULTILINE):
            with self.subTest(line=line.strip()[:60]):
                self.assertIn("CIFS_SYSTEMD_OPTS", line)


class TestBothDepartmentsGetTheSameTreatment(unittest.TestCase):
    """The AIT branch ends in `exit 0`, so anything added after it silently
    applies to Sustain only. That is how AIT ended up with no
    network-change handling at all."""

    def setUp(self):
        self.text = read(SCRIPTS / "ubuntu" / "qdrive.sh")
        self.lines = self.text.splitlines()
        self.ait_exit = next(
            i for i, l in enumerate(self.lines) if l.strip() == "exit 0")

    def test_the_ait_branch_deploys_the_autoswitch_hook(self):
        before = "\n".join(self.lines[:self.ait_exit])
        self.assertIn("deploy-drives-autoswitch.sh", before,
                      "AIT exits before the hook is deployed")

    def test_the_ait_branch_writes_drives_conf(self):
        before = "\n".join(self.lines[:self.ait_exit])
        self.assertIn("drives.conf", before,
                      "sync-homedir and RepairBooth both read drives.conf")

    def test_both_branches_write_a_department(self):
        for dept in ("ait", "sustain"):
            with self.subTest(department=dept):
                self.assertRegex(self.text, rf"DEPARTMENT={dept}\b")


class TestDriveAutoswitchHook(unittest.TestCase):
    """Hook'en holdt op med at kalde reselect, og ingen test sagde fra.

    Den blev skrevet om for at fjerne en stille 3-sekunders forsinkelse ved
    hvert netværksskift, og endte med kun at måle og notificere. Dermed
    skiftede maskinen intet af sig selv: omvalget skete kun hvis nogen
    trykkede på knappen, automounten blev aldrig armet igen når nettet kom
    tilbage, og uden en grafisk session skete der slet ingenting — så
    automounten blev ved med at være armet mod en død server, hvilket er
    præcis den frysning hook'en findes for at undgå.

    Testene her handler derfor ikke om hvordan hook'en er skrevet, men om at
    den stadig gør de tre ting den skal.
    """

    def setUp(self):
        self.deploy = read(SCRIPTS / "deploy-drives-autoswitch.sh")
        self.reselect = read(SCRIPTS / "dtu-drives-reselect.sh")

    def test_the_hook_actually_runs_the_reselect_script(self):
        """Selve regressionen: at måle og fortælle er ikke at handle."""
        self.assertRegex(
            strip_comments(self.deploy),
            r"flock[^\n]*/usr/local/bin/dtu-drives-reselect\.sh",
            "dispatcher-hook'en kalder ikke reselect-scriptet",
        )

    def test_the_hook_serialises_and_does_not_block_the_dispatcher(self):
        """NetworkManager venter på dispatcher-scripts. Kører reselect i
        forgrunden, holdes hele netværksskiftet tilbage af en CIFS-probe."""
        code = strip_comments(self.deploy)
        self.assertIn("flock -n", code, "uden flock hober kørsler sig op")
        self.assertRegex(code, r"\) >> [^\n]*\.log 2>&1 &",
                         "hook'ens arbejde køres ikke i baggrunden")

    def test_reselect_has_a_distinct_code_for_no_target(self):
        """Afsluttede den med 0 uanset hvad, kunne hverken hook'en eller
        knappen se forskel på 'monteret igen' og 'intet svarer'."""
        code = strip_comments(self.reselect)
        self.assertIn("EX_NO_TARGET=75", code)
        self.assertGreaterEqual(
            code.count('exit "$EX_NO_TARGET"'), 2,
            "både AIT- og Sustain-grenen skal melde manglende mål",
        )

    def test_the_notification_is_only_sent_when_nothing_answers(self):
        """Ellers popper der en besked op ved hvert eneste netværksskift."""
        code = strip_comments(self.deploy)
        self.assertRegex(code, r'\[ "\\?\$RC" -eq 75 \] \|\| exit 0',
                         "notifikationen er ikke betinget af exitkoden")

    def test_the_button_waits_for_a_run_already_in_progress(self):
        """Trykket kommer i samme sekund som netværksskiftet der udløste
        notifikationen, så låsen er ofte optaget netop da."""
        notify = strip_comments(read(SCRIPTS / "dtu-drives-notify.sh"))
        self.assertIn("flock -w", notify)
        self.assertNotIn("flock -n", notify)


class TestSustainMDrive(unittest.TestCase):
    """Sustains M-drev var den ene automount ingen holdt øje med.

    qdrive.sh monterer et personligt M-drev for Sustain også, og det ligger
    på en ANDEN server end Q- og P-drevet. Men drives.conf nævnte det ikke,
    og reselect'ens Sustain-gren rørte kun /mnt/Qdrev og /mnt/Personal. Kunne
    home-serveren ikke nås, blev /mnt/Mdrev ved med at være armet — altså
    præcis den frysning hele mekanismen findes for at undgå.
    """

    def setUp(self):
        self.qdrive = strip_comments(read(SCRIPTS / "ubuntu" / "qdrive.sh"))
        self.reselect_raw = read(SCRIPTS / "dtu-drives-reselect.sh")
        self.reselect = strip_comments(self.reselect_raw)

    def test_qdrive_records_the_m_drive_for_sustain(self):
        """Uden serveren i drives.conf kan hook'en ikke spørge om DEN
        svarer — målvalget for Q/P siger intet om home-serveren."""
        for key in ("M_SERVER=", "M_MOUNT_POINT="):
            with self.subTest(key=key):
                self.assertIn(key, self.qdrive)

    def test_reselect_arms_and_disarms_the_m_drive(self):
        self.assertIn("M_MOUNT_POINT", self.reselect)
        self.assertRegex(self.reselect,
                         r"cifs_stop_automount \"\$M_MOUNTPOINT\"")
        self.assertRegex(self.reselect,
                         r"cifs_start_automount \"\$M_MOUNTPOINT\"")

    def test_the_m_drive_is_handled_before_anything_needs_a_username(self):
        """En maskine opsat før USERNAME kom i drives.conf skal stadig få
        sit M-drev afvæbnet. Arm/afvæbn har ikke brug for at vide hvem
        drevet tilhører."""
        m_block = self.reselect.index("M_MOUNTPOINT=")
        username = self.reselect.index('USERNAME="$(conf_value USERNAME)"')
        self.assertLess(m_block, username,
                        "M-drevet håndteres efter USERNAME-afhængig kode")

    def test_an_unreachable_m_drive_does_not_raise_the_no_target_code(self):
        """75 betyder 'ingen af brugerens drev kan nås' og udløser en
        notifikation. Q/P kan sagtens virke mens home-serveren er nede."""
        # Kun M-drev-blokken: AIT-grenen ovenfor bruger koden med rette.
        start = self.reselect.index('[[ "$DEPARTMENT" == "sustain" ]] || exit 0')
        end = self.reselect.index('USERNAME="$(conf_value USERNAME)"')
        self.assertNotIn("EX_NO_TARGET", self.reselect[start:end])


class TestDrivesConfIsReadSafely(unittest.TestCase):
    """`grep -E '^NØGLE=' | cut` under set -euo pipefail.

    En grep uden træffere giver 1, pipefail løfter det til hele pipen, og en
    tildeling fra en fejlende kommandosubstitution tager scriptet ned. Så
    døde reselect på selve linjen der skulle læse USERNAME, længe før den
    guard der skulle fange en manglende USERNAME — på præcis de maskiner der
    var opsat før nøglen fandtes.
    """

    def test_reselect_reads_drives_conf_without_a_failing_pipe(self):
        code = strip_comments(read(SCRIPTS / "dtu-drives-reselect.sh"))
        offenders = re.findall(
            r'^\s*\w+="\$\(grep[^\n]*DRIVES_CONF[^\n]*\|[^\n]*\)"',
            code, re.MULTILINE)
        self.assertEqual(offenders, [], "\n".join(
            ["en manglende nøgle tager scriptet ned her:"] + offenders))

    def test_the_helper_cannot_fail_on_a_missing_key(self):
        code = strip_comments(read(SCRIPTS / "dtu-drives-reselect.sh"))
        self.assertIn("conf_value()", code)
        self.assertNotIn("grep", code.split("conf_value()")[1].split("}")[0])


class TestNoRawSocketsFromBash(unittest.TestCase):
    """Ingen shell må åbne en rå TCP-forbindelse selv.

    Bash kan åbne en socket gennem sin indbyggede netværks-pseudoenhed. Det
    er samtidig den primitiv en reverse shell er bygget af, og EDR-produkter
    signerer på den: en shell der åbner en rå TCP socket. Drev- og
    printerscriptene brugte den til at spørge om en server svarede — et
    portopslag og ikke andet, men signaturen er den samme, og den udløste en
    alert hos DTU's sikkerhedsteam 14/9 2026.

    Portopslag laves nu med Python, som gør præcis det samme uden at ligne
    noget andet. Guarden her findes fordi den gamle form er kortere at skrive
    og derfor nem at falde tilbage til.

    Mønstret sættes sammen af stumper, så hverken testen eller guarden selv
    indeholder den streng de leder efter.
    """

    PATTERN = re.compile("/dev/" + "tcp/")

    def test_no_script_opens_a_raw_socket_from_the_shell(self):
        offenders = []
        for path in ALL_SH:
            for number, line in enumerate(read(path).splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                if self.PATTERN.search(line):
                    offenders.append(
                        f"{path.relative_to(REPO)}:{number}: {line.strip()[:70]}")
        self.assertEqual(offenders, [], "\n".join(
            ["brug Python til portopslag — se cifs_host_up i common.sh:"]
            + offenders))

    def test_the_shared_probe_still_exists(self):
        """Findes den ikke, har hvert kaldested sin egen — og så er det et
        spørgsmål om tid, før et af dem falder tilbage til shell-formen."""
        common = strip_comments(read(SCRIPTS / "common.sh"))
        self.assertIn("cifs_host_up()", common)
        self.assertIn("python3", common)

    def test_the_probe_has_no_shell_fallback(self):
        """Et tilbagefald ville efterlade mønstret i filen, og en scanner der
        kigger på filindhold frem for på processer ville stadig reagere."""
        common = read(SCRIPTS / "common.sh")
        start = common.index("cifs_host_up() {")
        body = common[start:common.index("\n}", start)]
        self.assertNotIn("bash -c", body)


class TestFirstLogin(unittest.TestCase):
    """The dialog must reach domain users, and must not mark itself done
    until it actually finished."""

    def setUp(self):
        self.script = read(SCRIPTS / "dtu-first-login.sh")
        self.deploy = read(SCRIPTS / "ubuntu" / "first-login-deploy.sh")

    def test_autostart_is_system_wide(self):
        """/etc/skel is copied when the account is created. Anyone whose
        home already exists never gets it."""
        self.assertIn("/etc/xdg/autostart", self.deploy)

    def test_the_old_skel_entry_is_cleaned_up(self):
        """Two entries mean the dialog runs twice."""
        self.assertRegex(strip_comments(self.deploy),
                         r'rm -f "\$\{SKEL_AUTOSTART\}/dtu-first-login\.desktop"')

    def test_stale_per_user_copies_are_removed(self):
        self.assertIn("/.config/autostart/dtu-first-login.desktop",
                      strip_comments(self.deploy))

    def test_local_accounts_are_skipped(self):
        """The local admin who set the machine up must not consume the
        dialog — and must not write a marker the real user then inherits."""
        body = strip_comments(self.script)
        self.assertRegex(body, r'grep -q "\^\$\{USER\}:" /etc/passwd')

    def test_the_marker_is_written_once_and_last(self):
        body = strip_comments(self.script)
        writes = [m.start() for m in re.finditer(r'>\s*"\$MARKER"', body)]
        self.assertEqual(len(writes), 1, "the marker is written more than once")
        after = body[writes[0]:]
        self.assertNotIn("get_text", after,
                         "something still prompts after the marker is written")
        self.assertNotIn("get_password", after)

    def test_the_script_does_not_delete_a_system_file(self):
        """It used to rm its own autostart entry. A user cannot delete
        /etc/xdg/autostart, and the per-user marker is the gate now."""
        body = strip_comments(self.script)
        self.assertNotIn("rm -f \"$AUTOSTART_ENTRY\"", body)

    def test_a_dialog_tool_the_image_actually_has(self):
        """zenity is not in the DTU image; kdialog is. The script must not
        depend on zenity alone."""
        self.assertIn("kdialog", self.script)


class TestDrivesNotification(unittest.TestCase):
    def setUp(self):
        self.deploy = read(SCRIPTS / "deploy-drives-autoswitch.sh")
        self.notify = read(SCRIPTS / "dtu-drives-notify.sh")

    def test_the_hook_is_generated_as_valid_bash(self):
        m = re.search(r"cat > \"\$DISPATCHER_HOOK\" <<HOOK\n(.*?)\nHOOK\n",
                      self.deploy, re.DOTALL)
        self.assertIsNotNone(m, "could not find the generated hook")
        hook = m.group(1).replace("\\$", "$").replace("${NOTIFY_SCRIPT}", "/bin/true")
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as fh:
            fh.write(hook)
            path = fh.name
        proc = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
        Path(path).unlink()
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_the_reachability_check_lives_in_the_reselect_script(self):
        """Hook'en havde sit eget rækkevidde-tjek. Det læste kun den FØRSTE
        cifs-linje i fstab, så en maskine med drev på to forskellige servere
        fik kun den ene testet — og det kunne ikke se at en automount stod
        afvæbnet og skulle armes igen, så drevene kom aldrig tilbage af sig
        selv. Begge dele kan reselect. Hook'en spørger den nu i stedet for
        at gætte selv."""
        self.assertNotIn("/dev/tcp/", self.deploy,
                         "hook'en gætter igen selv på rækkevidde")
        reselect = read(SCRIPTS / "dtu-drives-reselect.sh")
        self.assertIn("cifs_host_up", reselect)
        self.assertIn("sustain_pick_target", reselect)

    def test_the_hook_does_not_sleep_for_seconds(self):
        m = re.search(r"cat > \"\$DISPATCHER_HOOK\" <<HOOK\n(.*?)\nHOOK\n",
                      self.deploy, re.DOTALL)
        for sleep in re.findall(r"sleep (\d+)", m.group(1)):
            with self.subTest(sleep=sleep):
                self.assertLessEqual(int(sleep), 1)

    def test_everything_the_hook_calls_is_installed_to_a_fixed_path(self):
        """NetworkManager and pkexec know nothing about the checkout."""
        installed = re.findall(r"install -m 755 [^\n]+", self.deploy)
        joined = " ".join(installed)
        for target in ("dtu-drives-reselect.sh", "dtu-drives-notify.sh"):
            with self.subTest(target=target):
                self.assertIn(target, joined)
                self.assertIn("/usr/local/bin", joined)

    def test_the_menu_entry_is_installed(self):
        """Some desktops route notifications through the XDG portal, which
        does not support buttons. The menu entry is the button that always
        exists."""
        self.assertIn("/usr/share/applications/dtu-drives-refresh.desktop",
                      self.deploy)

    def test_the_notification_offers_an_action(self):
        self.assertIn("--action=", self.notify)

    def test_the_notification_names_the_manual_route_too(self):
        self.assertIn("Genopfrisk netværksdrev", self.notify)

    def test_the_notifier_gives_up_rather_than_waiting_forever(self):
        """--action implies --wait. Without a timeout every network change
        would leave a process parked until someone clicks."""
        self.assertRegex(self.notify, r"timeout \d+ sudo -u")


class TestAutomountIsDisarmedWhenUnreachable(unittest.TestCase):
    """Sænket mount-timeout gjorde frysningerne kortere, ikke færre.

    Så længe automount'en er armet mod en server der ikke svarer, blokerer
    hver adgang til stien indtil timeouten — og idle-timeout får den til at
    gentage sig. Det er symptomet med frossen konsol og Dolphin, og en
    plasmashell der sover uafbrydeligt i kernen ligner et crash.
    """

    def setUp(self):
        self.reselect = strip_comments(read(SCRIPTS / "dtu-drives-reselect.sh"))
        self.common = strip_comments(read(SCRIPTS / "common.sh"))

    def test_common_has_a_way_to_disarm(self):
        self.assertIn("cifs_stop_automount()", self.common)
        self.assertIn("cifs_automount_active()", self.common)

    def test_disarm_uses_lazy_umount(self):
        """En CIFS-mount mod en død server kan ikke afmonteres normalt —
        umount blokerer selv, og så har vi flyttet frysningen i stedet for
        at fjerne den."""
        body = self.common.split("cifs_stop_automount()")[1].split("\n}")[0]
        self.assertIn("umount -l", body)

    def test_unreachable_disarms_instead_of_leaving_as_is(self):
        branch = self.reselect.split("if ! sustain_pick_target")[1].split("fi")[0]
        self.assertIn("cifs_stop_automount", branch)

    def test_unchanged_target_still_rearms_a_disarmed_mount(self):
        """Uden dette ville drevene aldrig komme tilbage efter en tur uden
        netværk: målet er det samme som sidst, så scriptet ville gå hjem."""
        guard = self.reselect.split("TARGET_LABEL\" == \"$PREV_TARGET")[1].split("fi")[0]
        self.assertIn("cifs_automount_active", guard)

    def test_ait_is_not_skipped(self):
        """AIT havde hook'en installeret og fik intet ud af den: scriptet
        afsluttede for alt andet end sustain, og frysningen blev meldt ind
        på netop en AIT-maskine."""
        ait = self.reselect.split('"$DEPARTMENT" == "ait"')
        self.assertGreater(len(ait), 1, "reselect har ingen AIT-gren")
        branch = ait[1]
        self.assertIn("cifs_stop_automount", branch)
        self.assertIn("cifs_start_automount", branch)

    def test_ait_records_the_server_the_hook_needs(self):
        """Hook'en spørger om filserveren svarer. Står SERVER ikke i
        drives.conf, kan den ikke afgøre noget og lader stien blokere."""
        qdrive = strip_comments(read(SCRIPTS / "ubuntu" / "qdrive.sh"))
        conf = qdrive.split('echo "ait" >')[1].split("deploy-drives-autoswitch")[0]
        self.assertIn("SERVER=", conf)

    def test_ait_drives_conf_is_written_before_the_hook_runs(self):
        """Hook'en læser filen. Skrives den bagefter, kører første kørsel
        mod en halv fil."""
        qdrive = strip_comments(read(SCRIPTS / "ubuntu" / "qdrive.sh"))
        head = qdrive.split("exit 0")[0]
        self.assertLess(head.index("drives.conf"), head.index("deploy-drives-autoswitch"))


class TestDesktopEntries(unittest.TestCase):
    def test_they_validate(self):
        # 127 is what a *shell* returns for a missing command. subprocess.run
        # execs directly, so an absent desktop-file-validate raises
        # FileNotFoundError and the test errors instead of skipping — which is
        # how CI went red on a runner that has no desktop-file-utils.
        if shutil.which("desktop-file-validate") is None:
            self.skipTest("desktop-file-validate not installed")
        entries = list(SCRIPTS.rglob("*.desktop"))
        self.assertTrue(entries, "no desktop entries found")
        for entry in entries:
            with self.subTest(entry=entry.name):
                proc = subprocess.run(["desktop-file-validate", str(entry)],
                                      capture_output=True, text=True)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


class TestRootDiscipline(unittest.TestCase):
    def test_scripts_that_write_to_etc_require_root(self):
        exempt = {"dtu-first-login.sh", "sync-homedir.sh",
                  "sync-homedir-login.sh", "dtu-drives-notify.sh"}
        offenders = []
        for path in ALL_SH:
            if path.name in exempt:
                continue
            body = strip_comments(read(path))
            writes_etc = re.search(r'>\s*"?/etc/|install -m \d+ [^\n]*/etc/'
                                   r'|sed -i [^\n]*/etc/', body)
            if writes_etc and "need_root" not in body and "EUID" not in body:
                offenders.append(str(path.relative_to(REPO)))
        self.assertEqual(offenders, [],
                         "writes to /etc without checking for root: "
                         + ", ".join(offenders))


if __name__ == "__main__":
    unittest.main()
