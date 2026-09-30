"""Static and behavioural checks on the shell scripts.

Every test here exists because the bug it describes actually shipped. Shell
has no type checker and these scripts run as root on other people's
machines, so the checks are deliberately mechanical: they look at what the
scripts say, not at what the comments claim.
"""

from __future__ import annotations

import os
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
        """And it names it exactly as the menu shows it. Read from the
        .desktop file rather than hardcoded, so renaming the menu entry
        cannot leave the notification pointing at a name nobody can find."""
        entry = read(SCRIPTS / "dtu-drives-refresh.desktop")
        name = re.search(r"^Name=(.+)$", entry, re.MULTILINE)
        self.assertIsNotNone(name, "the .desktop entry has no Name=")
        self.assertIn(name.group(1).strip(), self.notify)

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


FIRST_LOGIN = SCRIPTS / "dtu-first-login.sh"
ADMIN_BLOCK_START = "# ── Den lokale administratorkonto"
ADMIN_BLOCK_END = "# ── Department labels"


def admin_password_block() -> str:
    """The password-change section of dtu-first-login.sh, on its own.

    The script cannot be run end to end from a test: it exits immediately
    unless the invoking user is a domain user, which no test runner is. So
    the section is sliced out and sourced instead. If the markers move, the
    slice fails loudly rather than testing nothing.
    """
    body = read(FIRST_LOGIN)
    start = body.find(ADMIN_BLOCK_START)
    end = body.find(ADMIN_BLOCK_END)
    if start < 0 or end < 0 or end <= start:
        raise AssertionError(
            "cannot find the admin-password section in dtu-first-login.sh; "
            "the section markers were renamed or reordered")
    return body[start:end]


KEYBOARD_BLOCK_START = "# ── Keyboard layout"
KEYBOARD_BLOCK_END = "# ── Den lokale administratorkonto"


def keyboard_block() -> str:
    body = read(FIRST_LOGIN)
    start = body.find(KEYBOARD_BLOCK_START)
    end = body.find(KEYBOARD_BLOCK_END)
    if start < 0 or end < 0 or end <= start:
        raise AssertionError(
            "cannot find the keyboard-layout section in dtu-first-login.sh")
    return body[start:end]


class TestKeyboardLayout(unittest.TestCase):
    """The layout has to reach the login screen, not just the session.

    If it only reaches the session, the user types the password they cannot
    see on the old layout, and nothing on screen explains the rejection.
    """

    HARNESS = r"""
set -euo pipefail
DIALOG=kdialog
DEPT_LABEL="DTU Sustain"
show_message() { printf 'MSG %s\n' "${2//$'\n'/ }" >> "$WORK/dialogs"; }
show_error()   { printf 'ERR %s\n' "${2//$'\n'/ }" >> "$WORK/dialogs"; }
kdialog() {
    printf 'ASKED\n' >> "$WORK/dialogs"
    if [[ "${SVAR:-}" == "<CANCEL>" ]]; then return 1; fi
    printf '%s\n' "${SVAR:-Danish}"
}
source "$WORK/block.sh"
"$@"
"""

    def run_kb(self, *argv, answer="Danish", localectl_works=False,
               current="dk"):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            (work / "block.sh").write_text(keyboard_block(), encoding="utf-8")
            (work / "harness.sh").write_text(self.HARNESS, encoding="utf-8")
            (work / "dialogs").write_text("", encoding="utf-8")
            (work / "etc" / "default").mkdir(parents=True)

            bin_dir = work / "bin"
            bin_dir.mkdir()
            (bin_dir / "localectl").write_text(
                '#!/usr/bin/env bash\n'
                'if [[ "${1:-}" == "status" ]]; then\n'
                '    printf "   X11 Layout: %s\\n" "${FAKE_LAYOUT:-dk}"; exit 0\n'
                'fi\n'
                'if [[ "${LOCALECTL_WORKS:-0}" == "1" ]]; then\n'
                '    printf "%s\\n" "$*" >> "$WORK/localectl"; exit 0\n'
                'fi\n'
                'exit 1\n')
            # The privileged fallback writes to /etc. Under test those paths
            # are redirected so the file *content* stays under test rather
            # than being replaced by a no-op stub.
            (bin_dir / "pkexec").write_text(
                '#!/usr/bin/env bash\nsed "s#/etc/#$WORK/etc/#g" | bash -s\n')
            (bin_dir / "setxkbmap").write_text(
                '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$WORK/setxkbmap"\n')
            for f in bin_dir.iterdir():
                f.chmod(0o755)

            env = {
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "WORK": str(work),
                "SVAR": answer,
                "FAKE_LAYOUT": current,
                "LOCALECTL_WORKS": "1" if localectl_works else "0",
            }
            proc = subprocess.run(["bash", str(work / "harness.sh"), *argv],
                                  capture_output=True, text=True, env=env)

            def maybe(*parts):
                f = work.joinpath(*parts)
                return f.read_text(encoding="utf-8") if f.exists() else None

            return {
                "rc": proc.returncode,
                "stdout": proc.stdout.strip(),
                "stderr": proc.stderr,
                "dialogs": (work / "dialogs").read_text(encoding="utf-8"),
                "localectl": maybe("localectl"),
                "setxkbmap": maybe("setxkbmap"),
                "default_keyboard": maybe("etc", "default", "keyboard"),
                "xorg": maybe("etc", "X11", "xorg.conf.d", "00-keyboard.conf"),
            }

    def test_names_and_codes_cannot_drift_apart(self):
        self.assertEqual(self.run_kb("keyboard_name_for_code", "gb")["stdout"],
                         "English (UK)")
        self.assertEqual(self.run_kb("keyboard_code_for_name", "English (US)")["stdout"],
                         "us")

    def test_only_the_first_of_several_layouts_is_read(self):
        """A machine can carry "dk,us". The dialog preselects the active one."""
        r = self.run_kb("current_keyboard_layout", current="dk,us")
        self.assertEqual(r["stdout"], "dk")

    def test_it_goes_through_localectl_when_that_is_allowed(self):
        """The PolicyKit module grants domain users locale1.set-keyboard, so
        on a set-up machine this must not raise a second prompt."""
        r = self.run_kb("choose_keyboard_layout", answer="German",
                        localectl_works=True)
        self.assertIn("set-x11-keymap de", r["localectl"] or "")
        self.assertIsNone(r["default_keyboard"],
                          "took the privileged path when it did not have to")

    def test_the_privileged_fallback_writes_what_localed_would(self):
        """On a machine where the polkit rules are not in yet, which is the
        machine a first login happens on."""
        r = self.run_kb("choose_keyboard_layout", answer="English (UK)")
        self.assertIn('XKBLAYOUT="gb"', r["default_keyboard"] or "")
        self.assertIn('Option "XkbLayout" "gb"', r["xorg"] or "",
                      "the login screen reads the xorg file, so it must be written")

    def test_the_running_session_is_switched_too(self):
        """The next thing the user types is their domain password."""
        r = self.run_kb("choose_keyboard_layout", answer="German",
                        localectl_works=True)
        self.assertEqual((r["setxkbmap"] or "").strip(), "de")

    def test_cancelling_keeps_the_current_layout_and_continues(self):
        r = self.run_kb("choose_keyboard_layout", answer="<CANCEL>")
        self.assertEqual(r["rc"], 0, "cancel must not stop the whole setup")
        self.assertIsNone(r["setxkbmap"])
        self.assertIsNone(r["default_keyboard"])

    def test_picking_the_current_layout_changes_nothing(self):
        r = self.run_kb("choose_keyboard_layout", answer="Danish", current="dk")
        self.assertEqual(r["rc"], 0)
        self.assertIsNone(r["setxkbmap"])
        self.assertNotIn("MSG", r["dialogs"], "said something happened when nothing did")

    def test_it_is_asked_before_the_password(self):
        """Typing a domain password on the wrong layout fails with no
        explanation, so the order in the script matters."""
        body = strip_comments(read(FIRST_LOGIN))
        self.assertLess(body.index("choose_keyboard_layout\n"),
                        body.index("DTU_PASSWORD=$(get_password"))


class TestLocalAdminPassword(unittest.TestCase):
    """The image ships one local admin password to the whole fleet. This
    step is what replaces it, so every way out of it is a machine that
    keeps the shared password. They are all tested here.

    These run the shell, not a regex over it. Three `set -e` bugs in a
    sibling script reached a user's machine after passing `bash -n`.
    """

    HARNESS = r"""
set -euo pipefail
DEPARTMENT="${DEPARTMENT:-sustain}"
DEPT_LABEL="DTU Sustain"
ADMIN_PW_MARKER="$WORK/marker"
DTU_USERNAME="mpark"
DTU_PASSWORD="Domaenekode-42!"
USER="mpark"

show_message() { printf 'MSG\n' >> "$WORK/dialogs"; }
show_error()   { printf 'ERR %s\n' "${2//$'\n'/ }" >> "$WORK/dialogs"; }
get_password() {
    local svar
    if [[ ! -s "$WORK/answers" ]]; then printf 'ASK\n' >> "$WORK/dialogs"; return 1; fi
    svar="$(head -n1 "$WORK/answers")"
    sed -i '1d' "$WORK/answers"
    printf 'ASK\n' >> "$WORK/dialogs"
    case "$svar" in
        "<CANCEL>") return 1 ;;
        "<EMPTY>")  : ;;
        *) printf '%s\n' "$svar" ;;
    esac
}

source "$WORK/block.sh"

# The account name differs across the fleet, so the real lookup is tested
# separately against the real /etc/passwd. Here it is fixed, so the rest of
# the flow is what is under test.
if [[ "${REAL_LOOKUP:-0}" == "1" ]]; then
    # Only the lookup, against the real /etc/passwd.
    fundet=""
    find_local_admin > "$WORK/found" || : > "$WORK/found"
    exit 0
fi
find_local_admin() { printf 'admin-test\n'; }

change_local_admin_password
echo "RC=$?"
"""

    def run_step(self, answers, department="sustain", marker=False, env=None):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            (work / "block.sh").write_text(admin_password_block(), encoding="utf-8")
            (work / "answers").write_text(
                "".join(a + "\n" for a in answers), encoding="utf-8")
            (work / "dialogs").write_text("", encoding="utf-8")
            if marker:
                (work / "marker").write_text("allerede skiftet\n", encoding="utf-8")

            bin_dir = work / "bin"
            bin_dir.mkdir()
            # pkexec is the privilege step. Under test it must run the same
            # `bash -s` with the same stdin, minus the privilege.
            (bin_dir / "pkexec").write_text("#!/usr/bin/env bash\nexec \"$@\"\n")
            # chpasswd records exactly what it was handed. That byte string
            # is the whole point: it is the new password.
            (bin_dir / "chpasswd").write_text(
                '#!/usr/bin/env bash\ncat > "$WORK/chpasswd"\n')
            # /var/lib/dtu-setup cannot be created without root, so the path
            # is redirected rather than the command neutered: the ordering
            # of "make the directory, then change the password" stays under
            # test.
            (bin_dir / "install").write_text(
                '#!/usr/bin/env bash\n'
                'args=(); for a in "$@"; do args+=("${a//\\/var\\/lib\\/dtu-setup/$WORK/varlib}"); done\n'
                'exec /usr/bin/install "${args[@]}"\n')
            for f in bin_dir.iterdir():
                f.chmod(0o755)

            harness = work / "harness.sh"
            harness.write_text(self.HARNESS, encoding="utf-8")

            environ = {
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "WORK": str(work),
                "HOME": str(work),
                "DEPARTMENT": department,
            }
            environ.update(env or {})
            proc = subprocess.run(["bash", str(harness)], capture_output=True,
                                  text=True, env=environ)
            # Everything is read here, inside the context manager. Returning
            # the path instead would hand back a directory that no longer
            # exists, and every assertion about a file in it would pass by
            # finding nothing.
            def maybe(name):
                f = work / name
                return f.read_text(encoding="utf-8") if f.exists() else None

            return {
                "rc": proc.returncode,
                "stdout": proc.stdout,
                "stderr": proc.stderr,
                "dialogs": (work / "dialogs").read_text(encoding="utf-8"),
                "sent": maybe("chpasswd"),
                "found": (maybe("found") or "").strip(),
                "marker": (work / "marker").exists(),
                "files": sorted(p.name for p in work.iterdir()),
            }

    # ── the happy path ──────────────────────────────────────────────────────
    def test_a_good_password_is_set_and_recorded(self):
        r = self.run_step(["Fjeldgeden7!", "Fjeldgeden7!"])
        self.assertEqual(r["rc"], 0, r["stderr"])
        self.assertEqual(r["sent"], "admin-test:Fjeldgeden7!\n")
        self.assertTrue(r["marker"], "nothing recorded that the password was changed")

    def test_the_password_reaches_chpasswd_byte_for_byte(self):
        """It travels through a heredoc into a root shell. Anything that
        quotes it wrong either mangles the password, which locks the account
        out quietly, or executes part of it as root."""
        nasty = 'A9!$(touch $WORK/pwned)`touch $WORK/pwned2`;\\ "x"'
        r = self.run_step([nasty, nasty])
        self.assertEqual(r["sent"], "admin-test:" + nasty + "\n")
        self.assertNotIn("pwned", r["files"], "command substitution ran as root")
        self.assertNotIn("pwned2", r["files"], "backticks ran as root")

    def test_non_ascii_survives(self):
        r = self.run_step(["Rødgrød~med~Fløde7", "Rødgrød~med~Fløde7"])
        self.assertEqual(r["sent"], "admin-test:Rødgrød~med~Fløde7\n")

    # ── every way of refusing ───────────────────────────────────────────────
    def test_too_short_is_refused(self):
        r = self.run_step(["Kort1!"] * 6)
        self.assertIsNone(r["sent"])
        self.assertIn("at least 12 characters", r["dialogs"])

    def test_too_few_character_classes_is_refused(self):
        r = self.run_step(["kunsmaabogstaverher"] * 6)
        self.assertIsNone(r["sent"])
        self.assertIn("at least 3", r["dialogs"])

    def test_the_account_name_cannot_be_the_password(self):
        r = self.run_step(["Xadmin-testY99!"] * 6)
        self.assertIsNone(r["sent"])
        self.assertIn("account name", r["dialogs"])

    def test_the_domain_password_cannot_be_reused(self):
        """Two accounts with one password is one account."""
        r = self.run_step(["Domaenekode-42!"] * 6)
        self.assertIsNone(r["sent"])
        self.assertIn("WIN domain password", r["dialogs"])

    def test_a_trailing_space_is_refused(self):
        r = self.run_step(["Fjeldgeden7! "] * 6)
        self.assertIsNone(r["sent"])

    def test_the_two_entries_must_match(self):
        r = self.run_step(["Fjeldgeden7!", "Fjeldgeden8!",
                           "Fjeldgeden7!", "Fjeldgeden7!"])
        self.assertEqual(r["sent"], "admin-test:Fjeldgeden7!\n",
                         "a mismatch must cost a retry, not the whole step")
        self.assertIn("not the same", r["dialogs"])

    def test_three_bad_attempts_give_up_without_changing_anything(self):
        r = self.run_step(["kort"] * 8)
        self.assertEqual(r["rc"], 0, "giving up must not kill the setup script")
        self.assertIsNone(r["sent"])
        self.assertFalse(r["marker"])

    def test_cancelling_leaves_the_password_alone_and_returns_cleanly(self):
        """Cancel must not take the rest of the first-login setup down with
        it, and must not record the password as changed."""
        r = self.run_step(["<CANCEL>"])
        self.assertEqual(r["rc"], 0, r["stderr"])
        self.assertIsNone(r["sent"])
        self.assertFalse(r["marker"])

    def test_an_empty_entry_is_treated_as_a_cancel(self):
        r = self.run_step(["<EMPTY>"])
        self.assertEqual(r["rc"], 0, r["stderr"])
        self.assertIsNone(r["sent"])

    # ── when it must not run at all ─────────────────────────────────────────
    def test_it_is_skipped_outside_the_sustain_profile(self):
        r = self.run_step(["Fjeldgeden7!", "Fjeldgeden7!"], department="ait")
        self.assertEqual(r["dialogs"], "", "AIT machines were asked anyway")
        self.assertIsNone(r["sent"])

    def test_an_already_changed_password_is_not_asked_about_again(self):
        r = self.run_step(["Fjeldgeden7!", "Fjeldgeden7!"], marker=True)
        self.assertEqual(r["dialogs"], "")
        self.assertIsNone(r["sent"])

    # ── finding the account ─────────────────────────────────────────────────
    def test_the_lookup_never_returns_a_system_account(self):
        """Run the real lookup against this machine's real /etc/passwd.
        It may legitimately find nothing. What it must never do is hand back
        a daemon account, because the next thing that happens is that its
        password is changed."""
        r = self.run_step([], env={"REAL_LOOKUP": "1"})
        self.assertEqual(r["rc"], 0, r["stderr"])
        name = r["found"]
        if not name:
            self.skipTest("no local admin account on this machine")

        entry = None
        for line in Path("/etc/passwd").read_text(encoding="utf-8").splitlines():
            parts = line.split(":")
            if len(parts) >= 7 and parts[0] == name:
                entry = parts
        self.assertIsNotNone(entry, f"{name!r} is not in /etc/passwd")
        self.assertGreaterEqual(int(entry[2]), 1000, f"{name} is a system account")
        self.assertLess(int(entry[2]), 60000, f"{name} is not a local account")
        self.assertNotRegex(entry[6], r"(nologin|/false|/sync)$",
                            f"{name} has no usable shell")

    def test_the_marker_is_system_wide_not_per_user(self):
        """One local account, one password. A marker in $HOME would let the
        second user on a machine silently overwrite the first user's."""
        body = strip_comments(read(FIRST_LOGIN))
        self.assertRegex(body, r'ADMIN_PW_MARKER="/var/lib/')
        self.assertNotRegex(body, r'ADMIN_PW_MARKER="\$HOME')

    def test_the_step_runs_before_the_done_marker(self):
        """After the marker is written the dialog never returns, so a step
        placed below it would never run."""
        body = strip_comments(read(FIRST_LOGIN))
        call = body.rindex("change_local_admin_password")
        marker = body.index('> "$MARKER"')
        self.assertLess(call, marker)


class TestHelpersAreActuallyDefined(unittest.TestCase):
    """The generalisation of a bug that shipped: tpm2-rebind.sh called `die`
    at four places, including its Secure-Boot-off safety refusal, and nothing
    defined it. Under `set -euo pipefail` every one of those paths became
    "die: command not found", exit 127, message never printed. shellcheck does
    not detect undefined functions, so lint and CI were green.
    """

    def _defined_in(self, path: Path) -> set[str]:
        return set(re.findall(r"^([a-z_][a-z0-9_]*)\(\)", read(path), re.MULTILINE))

    def test_die_is_defined_in_common(self):
        self.assertIn("die", self._defined_in(SCRIPTS / "common.sh"))

    def test_tpm2_rebind_can_print_its_secure_boot_refusal(self):
        """The one message that must never be swallowed: it explains why the
        machine refuses to re-bind, and silence there looks like a crash."""
        rebind = SCRIPTS / "ubuntu" / "tpm2-rebind.sh"
        body = strip_comments(read(rebind))
        self.assertIn("die ", body, "tpm2-rebind.sh no longer calls die")
        self.assertRegex(read(rebind), r"source .*common\.sh",
                         "it must source the file that defines die")
        self.assertIn("die", self._defined_in(SCRIPTS / "common.sh"))

    def test_every_helper_a_script_calls_is_reachable(self):
        """Closed vocabulary: only the helper names we define ourselves, so
        there are no false positives from external binaries."""
        common = self._defined_in(SCRIPTS / "common.sh")
        for path in ALL_SH:
            if path.name == "common.sh":
                continue
            body = strip_comments(read(path))
            if not re.search(r"source .*common\.sh", body):
                continue
            available = common | self._defined_in(path)
            for name in sorted(common):
                # Called in command position, i.e. at the start of a statement.
                if re.search(rf"(?:^|\||&&|;|\{{)\s*{name}\s", body, re.MULTILINE):
                    with self.subTest(script=path.name, helper=name):
                        self.assertIn(name, available)


class TestNoAdHocOsRelease(unittest.TestCase):
    """/etc/os-release used to be sourced in four places. Sourcing it drops
    about twenty names into the caller's namespace, and these scripts run under
    `set -u`, so a key that a future release stops shipping is a hard error far
    from its cause. common.sh now owns the reading.
    """

    # install-software-manual.sh is deliberately standalone: it must run on its
    # own with `sudo bash install-software-manual.sh`, without the rest of the
    # repo, so it carries its own copy of the helpers by design.
    ALLOWED = {"common.sh", "install-software-manual.sh"}

    def test_nothing_else_sources_os_release(self):
        for path in ALL_SH:
            if path.name in self.ALLOWED:
                continue
            body = strip_comments(read(path))
            with self.subTest(script=path.name):
                self.assertNotRegex(body, r"^\s*\.\s+/etc/os-release",
                                    "use os_release_value / ubuntu_version instead")

    def test_defender_no_longer_uses_a_sourced_version_id(self):
        body = strip_comments(read(SCRIPTS / "ubuntu" / "defender.sh"))
        self.assertNotIn("VERSION_ID", body)
        self.assertIn("ubuntu_version", body)


class TestChrootSafety(unittest.TestCase):
    """`uname -r` inside the image chroot is the build host's kernel, so
    linux-headers-$(uname -r) fetches headers for a kernel the machine will
    never run. Both call sites must branch on in_chroot.
    """

    def test_every_uname_r_headers_call_is_guarded(self):
        for path in ALL_SH:
            body = strip_comments(read(path))
            if "linux-headers-$(uname -r)" not in body:
                continue
            with self.subTest(script=path.name):
                self.assertIn("in_chroot", body,
                              "unguarded uname -r would install the wrong headers")

    def test_the_standalone_script_carries_its_own_copy(self):
        """It does not source common.sh, so a bare in_chroot call there would
        be the same class of bug as the missing die."""
        body = read(SCRIPTS / "install-software-manual.sh")
        self.assertIn("in_chroot() {", body)
        self.assertNotRegex(body, r"source .*common\.sh",
                            "it is standalone on purpose; that is why it needs its own copy")


class TestRdpSession(unittest.TestCase):
    """`exec xterm` was the fallback when no Plasma session was found, but
    xterm is not in the image: the branch died with exit 127 and no message,
    and the user saw a black screen that closed itself.
    """

    def setUp(self):
        self.text = read(SCRIPTS / "ubuntu" / "rdp.sh")
        self.body = strip_comments(self.text)

    def test_no_xterm_fallback(self):
        self.assertNotIn("exec xterm", self.body)

    def test_the_startwm_heredoc_stays_quoted(self):
        """It is written verbatim to the target machine. Unquoting the heredoc
        would expand our build-time variables into the target's startwm.sh,
        which is the subtle way to break this."""
        self.assertIn("<<'STARTWM'", self.body)

    def test_a_missing_session_starter_fails_provisioning(self):
        """Otherwise it surfaces weeks later as a black RDP screen."""
        self.assertIn("startplasma-x11", self.body)
        idx = self.body.index("[7/7]")
        self.assertIn("command -v startplasma-x11", self.body[idx:])


class TestLoginScreenRefusesBeforeWriting(unittest.TestCase):
    """The one module that can lock every user out of a machine's greeter. It
    empties SDDM's user list and relies on the theme switching to a username
    field on its own. If a release changes that, the machine shows an empty
    list and no name field. So every refusal has to happen before the config
    is written: then the failure mode is "nothing changed", not "no login".
    """

    def setUp(self):
        self.body = strip_comments(read(SCRIPTS / "ubuntu" / "login-screen.sh"))

    def test_the_theme_check_runs_before_the_config_is_written(self):
        check = self.body.index("userListModel")
        write = self.body.index('cat > "$CONF"')
        self.assertLess(check, write,
                        "the QML assertion must gate the write, not follow it")

    def test_the_theme_is_resolved_not_assumed(self):
        """default.conf says kubuntu and kde_settings.conf says ubuntu-theme;
        the later one wins. A hardcoded 'breeze' would check QML the machine
        does not use."""
        self.assertIn("sddm_conf_value Theme Current", self.body)

    def test_the_user_list_outcome_is_verified(self):
        """Emulates SDDM's UserModel against the config just written. One
        account left in range means a user list and no name field."""
        self.assertIn("getent passwd", self.body)
        self.assertIn("HIDE_SHELLS", self.body)

    def test_a_failed_outcome_check_rolls_the_config_back(self):
        idx = self.body.index("getent passwd")
        self.assertIn('rm -f "$CONF"', self.body[idx:])

    def test_hide_shells_is_written_once(self):
        """The config file and the verification must read the same list, or
        they drift and the check stops matching what SDDM does."""
        self.assertIn("HideShells=${HIDE_SHELLS}", self.body)


class TestPackagingDependenciesAgree(unittest.TestCase):
    """The .deb dependency list is written twice, in packaging/debian/control
    and in the Makefile's deb target. check-version exists because this repo
    has exactly that duplication problem elsewhere.
    """

    def setUp(self):
        self.control = read(REPO / "packaging" / "debian" / "control")
        self.makefile = read(REPO / "Makefile")

    def test_policykit_1_is_gone(self):
        """It does not exist on 26.04. polkitd and pkexec exist on both."""
        for name, text in (("control", self.control), ("Makefile", self.makefile)):
            with self.subTest(file=name):
                self.assertNotIn("policykit-1", text)

    def test_both_ask_for_polkitd_and_pkexec(self):
        for name, text in (("control", self.control), ("Makefile", self.makefile)):
            with self.subTest(file=name):
                self.assertIn("polkitd", text)
                self.assertIn("pkexec", text)


class TestPolkitPrivilegeScope(unittest.TestCase):
    """The two critical findings from the 22 Sep 2026 security review.

    49-domain-admins.rules used to return YES for every polkit action with no
    local/active condition. Because the tool's own action is annotated on
    /usr/bin/bash, that was prompt-free root via `pkexec <anything>`, over RDP
    and SSH included. And the visudo check could not stop the script, so a
    syntax error deleted the password-protected sudoers file while the
    prompt-free polkit rule was written anyway: the group lost the safe route
    to root and kept the unsafe one.
    """

    def setUp(self):
        self.body = strip_comments(read(SCRIPTS / "ubuntu" / "polkit.sh"))

    def _rule(self, number: str) -> str:
        start = self.body.index(f"/etc/polkit-1/rules.d/{number}")
        return self.body[start:self.body.index("\nEOF", start)]

    def test_a_visudo_failure_stops_the_script(self):
        """Otherwise the password-protected file is gone and the prompt-free
        rule is written regardless."""
        idx = self.body.index("visudo -cf")
        after = self.body[idx:idx + 400]
        self.assertTrue("die " in after or "exit 1" in after,
                        "the visudo failure path must stop the script")
        self.assertNotRegex(
            self.body,
            r"visudo -cf [^\n]*\|\| \{[^}]*rm -f[^}]*\}\s*\n",
            "the || { ...; rm -f; } form returns 0 and set -e never fires")

    def test_the_admin_rule_is_not_an_unconditional_yes(self):
        rule = self._rule("49-domain-admins")
        self.assertIn("subject.local", rule)
        self.assertIn("subject.active", rule)
        self.assertIn("NOT_HANDLED", rule)

    def test_the_admin_rule_only_covers_this_tools_actions(self):
        """Everything else must fall through to polkit's auth_admin, whose
        route is sudo, which asks for a password."""
        rule = self._rule("49-domain-admins")
        self.assertIn('action.id.indexOf("dk.dtu.sustain.setup.")', rule)
        # Exactly one YES, and it is the one guarded by that prefix.
        self.assertEqual(rule.count("polkit.Result.YES"), 1)

    def test_admins_keep_their_daily_use_rights(self):
        """Narrowing rule 49 must not cost admins USB, WiFi or packages, so
        rule 48 now covers the admin group too and the action list stays in
        one place."""
        rule = self._rule("48-domain-users")
        self.assertIn("${ADMIN_GROUP}", rule)
        self.assertIn("Domain Users", rule)
        self.assertIn("subject.local", rule)

    def test_both_rules_refuse_remote_sessions(self):
        for number in ("48-domain-users", "49-domain-admins"):
            with self.subTest(rule=number):
                rule = self._rule(number)
                self.assertRegex(rule, r"!subject\.local \|\| !subject\.active")


class TestNoDeadDmrcWrite(unittest.TestCase):
    """first-login-deploy.sh wrote /etc/skel/.dmrc to default new users to
    X11. It never worked: ~/.dmrc is read by GDM and LightDM, and the image
    runs SDDM, which keeps its own state and is steered by
    login-screen.sh's RememberLastSession=true. Patching the 26.04 spelling
    into it would have made dead code look maintained.
    """

    def setUp(self):
        self.body = strip_comments(read(SCRIPTS / "ubuntu" / "first-login-deploy.sh"))

    def test_nothing_writes_dmrc(self):
        self.assertNotIn("/etc/skel/.dmrc <<", self.body)
        self.assertNotIn("plasmaX11.desktop", self.body)

    def test_our_own_leftover_is_cleaned_up(self):
        """Machines provisioned earlier still carry the file."""
        self.assertIn("rm -f /etc/skel/.dmrc", self.body)

    def test_a_foreign_dmrc_is_left_alone(self):
        """Only the exact two lines we wrote are ours to delete."""
        idx = self.body.index("/etc/skel/.dmrc")
        self.assertIn("Desktop", self.body[idx:idx + 600])
        self.assertIn("not ours", read(SCRIPTS / "ubuntu" / "first-login-deploy.sh"))


class TestInstallPathsAreVerified(unittest.TestCase):
    """Security review 22 Sep 2026, finding 3.1: three install paths ran
    `curl | tar | make install` as root with no integrity check. And the
    checksum file CI already published only covered the .deb, not the source
    archive the installers downloaded, so "just fetch sha256sums.txt" was not
    possible as things stood.

    The behaviour is tested against a fake release in
    tests/test_install_verify.sh. These guard the structure.
    """

    INSTALL = REPO / "bin" / "dtu-install.sh"
    UPDATE = SCRIPTS / "update-latest.sh"

    def _func(self, path: Path, name: str) -> str:
        m = re.search(rf"^{name}\(\) {{.*?^}}\n", read(path), re.S | re.M)
        self.assertIsNotNone(m, f"{name} missing from {path.name}")
        return m.group(0)

    def test_the_two_copies_are_identical(self):
        """They cannot share a library: dtu-install.sh is piped into bash
        straight from GitHub. So they carry copies, and a fix to one that
        does not reach the other is exactly how a hole reopens."""
        for name in ("fetch_verified_release", "_dtu_download"):
            with self.subTest(function=name):
                self.assertEqual(self._func(self.INSTALL, name),
                                 self._func(self.UPDATE, name))

    def test_nothing_is_piped_from_the_network_into_tar(self):
        """`curl ... | tar -x` extracts before anything can be checked."""
        for path in (self.INSTALL, self.UPDATE):
            with self.subTest(script=path.name):
                self.assertNotRegex(strip_comments(read(path)),
                                    r"(curl|wget)[^\n|]*\|\s*tar")

    def test_extraction_happens_only_after_the_comparison(self):
        body = self._func(self.INSTALL, "fetch_verified_release")
        self.assertLess(body.index('"$actual" != "$expected"'), body.index("tar -xzf"))

    def test_update_follows_releases_not_the_main_branch(self):
        """The GUI button says "latest release"; the script fetched main."""
        body = strip_comments(read(self.UPDATE))
        self.assertIn("fetch_verified_release", body)
        self.assertNotIn('BRANCH="${BRANCH:-main}"', body)

    def test_the_dead_deploy_script_is_gone(self):
        """It defaulted to a 'deploy' branch that no longer exists on GitHub,
        cloned whatever REPO_URL the environment said, and nothing called it."""
        self.assertFalse((REPO / "bin" / "dtu-deploy-from-github.sh").exists())

    def test_ci_publishes_the_archive_the_installers_fetch(self):
        ci = read(REPO / ".github" / "workflows" / "build-deb.yml")
        self.assertIn("git archive", ci)
        self.assertIn("dtu-sustain-setup-*.tar.gz", ci)
        # Bare names: the installers look their archive up by exact name.
        self.assertIn("(cd dist && sha256sum -- *) > sha256sums.txt", ci)


class TestLocalCredentialLeaks(unittest.TestCase):
    """Security review 22 Sep 2026, finding 4.1: credentials that leaked to
    other local users. The keyfile side of wifi.sh is tested for real in
    tests/test_wifi_keyfile.py."""

    def test_followme_creds_are_private_from_the_first_byte(self):
        body = strip_comments(read(SCRIPTS / "ubuntu" / "followme.sh"))
        idx = body.index('cat > "${CREDS_FILE}"')
        self.assertIn("umask 077", body[max(0, idx - 80):idx],
                      "the file must be created under umask 077, not chmod'ed later")
        self.assertIn("root:lp 640", body[idx:])

    def test_defender_uses_no_fixed_tmp_paths(self):
        """root installed a .deb and ran a Python script from fixed names in
        /tmp, where any local user can create a file first."""
        body = strip_comments(read(SCRIPTS / "ubuntu" / "defender.sh"))
        self.assertNotRegex(body, r"/tmp/[A-Za-z]")
        self.assertIn('WORK="$(mktemp -d)"', body)


class TestFirstLoginWifiIsTheUsersOwn(unittest.TestCase):
    """The machine is prepared by an admin, and DTUSecure was stored with the
    admin's own domain credentials. At a domain user's first login it must be
    replaced by a profile in that user's name."""

    def setUp(self):
        self.body = strip_comments(read(SCRIPTS / "dtu-first-login.sh"))

    def test_wifi_is_set_up_for_the_logged_in_account(self):
        idx = self.body.index("WIFI_SCRIPT=")
        self.assertIn("DTU_WIFI_USER=$(printf '%q' \"$LOGIN_USER\")", self.body[idx:])

    def test_a_mismatched_username_leaves_the_wifi_alone(self):
        """One person's name with another's password gives a Wi-Fi that does
        not work, and the admin's working profile would be gone."""
        self.assertIn('if [[ "${DTU_USERNAME,,}" != "${LOGIN_USER,,}" ]]; then', self.body)
        self.assertIn('if [[ -z "$WIFI_SKIPPED" && -f "$WIFI_SCRIPT" ]]; then', self.body)

    def test_the_username_prompt_is_prefilled(self):
        self.assertIn('"$LOGIN_USER")', self.body)


class TestLoginctlIsQueriedNotParsed(unittest.TestCase):
    """The column layout of `loginctl list-sessions` is not a stable format.
    26.04 added LEADER and CLASS, and lists "manager" sessions (the user@
    service) next to real ones. Only the first column, the session ID, is
    read; everything else comes from `show-session -p`, the documented
    interface."""

    def test_no_script_reads_a_column_past_the_session_id(self):
        for path in ALL_SH:
            body = strip_comments(read(path))
            for line in body.splitlines():
                if "loginctl list-sessions" in line and "awk" in line:
                    with self.subTest(script=path.name, line=line.strip()):
                        self.assertRegex(line, r"print \\?\$1\b")

    def test_the_drive_notification_goes_to_graphical_sessions_only(self):
        body = strip_comments(read(SCRIPTS / "deploy-drives-autoswitch.sh"))
        self.assertIn("-p Type --value", body)
        self.assertIn("x11|wayland)", body)


class TestCiStepsRunUnderGithubsShell(unittest.TestCase):
    """The release steps are shell, and GitHub runs `shell: bash` as
    `bash --noprofile --norc -eo pipefail`. The first version of the source
    archive step passed every local test and failed on GitHub: its
    `tar | grep -q` check stops reading early, tar gets a write error, and
    under pipefail that fails the step exactly when the archive is fine.

    So the steps are pulled out of the workflow and run here, with the same
    flags, against this repository.
    """

    FLAGS = ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c"]

    def _step(self, name: str) -> str:
        import yaml  # type: ignore
        wf = yaml.safe_load(read(REPO / ".github" / "workflows" / "build-deb.yml"))
        for job in wf["jobs"].values():
            for step in job.get("steps", []):
                if step.get("name") == name:
                    return step["run"]
        self.fail(f"no step named {name!r}")

    def test_build_source_archive(self):
        version = re.search(r"^VERSION\s*:=\s*(\S+)", read(REPO / "Makefile"), re.M).group(1)
        script = self._step("Build source archive").replace(
            "${{ steps.version.outputs.make_version }}", version)
        with tempfile.TemporaryDirectory() as d:
            # Run in a clone so the archive and its listing land outside the
            # working tree.
            # --no-local: /tmp is often another filesystem, and --local uses
            # hard links, which cannot cross one.
            clone = Path(d) / "clone"
            subprocess.run(["git", "clone", "-q", "--no-local", str(REPO), str(clone)], check=True)
            r = subprocess.run(self.FLAGS + [script], cwd=clone, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue((clone / f"dtu-sustain-setup-{version}.tar.gz").exists())

    def test_compute_checksums(self):
        script = self._step("Compute checksums")
        with tempfile.TemporaryDirectory() as d:
            dist = Path(d) / "dist"
            dist.mkdir()
            (dist / "dtu-sustain-setup_9.9.9_all.deb").write_bytes(b"deb")
            (dist / "dtu-sustain-setup-9.9.9.tar.gz").write_bytes(b"src")
            r = subprocess.run(self.FLAGS + [script], cwd=d, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            sums = (Path(d) / "sha256sums.txt").read_text()
            # Bare names: the installers look their archive up by exact name.
            self.assertRegex(sums, r"(?m)^[0-9a-f]{64}  dtu-sustain-setup-9\.9\.9\.tar\.gz$")
            self.assertNotIn("dist/", sums)


class TestDefenderOnboardingIsPinned(unittest.TestCase):
    """defender.sh downloads Microsoft's onboarding script from an internal
    server and runs it as root. Same class of hole as the install paths had,
    so it is pinned by SITE_DEFENDER_ONBOARDING_SHA256 from site.conf, and a
    failed onboarding no longer reports success (`|| true` is gone).

    The real block is cut out of defender.sh and run with fake curl and
    python3 on PATH that record whether they were called.
    """

    PAYLOAD = "print(1)"

    def _block(self) -> str:
        text = read(SCRIPTS / "ubuntu" / "defender.sh")
        start = text.index('ONBOARD="$WORK/')
        end = text.index("\nfi\n", text.index('if ! python3 "$ONBOARD"')) + 4
        return text[start:end]

    def _run(self, pin: str, python_rc: int = 0):
        from hashlib import sha256
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "bin").mkdir()
            (d / "bin" / "curl").write_text(
                '#!/bin/bash\nwhile [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done\n'
                f'printf %s {self.PAYLOAD!r} > "$out"\n')
            (d / "bin" / "python3").write_text(
                f'#!/bin/bash\necho ran >> "{d}/python3.calls"\nexit {python_rc}\n')
            for f in (d / "bin").iterdir():
                f.chmod(0o755)
            script = (f'source "{SCRIPTS / "common.sh"}" >/dev/null 2>&1\n'
                      f'WORK="{d}"\nSITE_DEFENDER_ONBOARDING_URL=https://x.invalid/o.py\n'
                      'SITE_DEFENDER_ONBOARDING_SHA256="$PIN"\n' + self._block() +
                      '\necho REACHED_END\n')
            # The pin goes in through a variable: tests/check-no-internal-values.sh
            # rightly refuses a literal SITE_* value in a tracked file.
            env = {**os.environ, "PATH": f"{d / 'bin'}:{os.environ['PATH']}", "PIN": pin}
            r = subprocess.run(["bash", "-euo", "pipefail", "-c", script],
                               env=env, capture_output=True, text=True)
            ran = (d / "python3.calls").exists()
        good = sha256(self.PAYLOAD.encode()).hexdigest()
        return r, ran, good

    def test_a_matching_pin_runs_the_script(self):
        _, _, good = self._run("")
        r, ran, _ = self._run(good)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(ran)

    def test_a_wrong_pin_never_runs_the_script(self):
        r, ran, _ = self._run("0" * 64)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(ran, "the unverified script ran as root")
        self.assertIn("does not match", r.stdout + r.stderr)

    def test_no_pin_runs_but_says_so_and_prints_the_checksum(self):
        r, ran, good = self._run("")
        self.assertTrue(ran)
        self.assertIn("WITHOUT a checksum", r.stdout + r.stderr)
        self.assertIn(good, r.stdout + r.stderr)

    def test_a_failed_onboarding_stops_the_module(self):
        _, _, good = self._run("")
        r, ran, _ = self._run(good, python_rc=1)
        self.assertTrue(ran)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("REACHED_END", r.stdout)

    def test_enrollment_is_checked_at_the_end(self):
        body = strip_comments(read(SCRIPTS / "ubuntu" / "defender.sh"))
        self.assertIn("mdatp health --field licensed", body)
        self.assertNotRegex(body, r'python3 "\$ONBOARD"[^\n]*\|\|\s*true')


if __name__ == "__main__":
    unittest.main()
