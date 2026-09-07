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

    def test_the_hook_checks_reachability_before_acting(self):
        """The old hook slept 3s and ran the full reselect on every event.
        The common case is that nothing changed."""
        self.assertIn("/dev/tcp/", self.deploy)

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


class TestStandaloneAitDrives(unittest.TestCase):
    """Det frittstående AIT-drevscript er en kopi af modulets logik.

    Kopien er prisen for at kunne køre uden DTU Linux Setup, men en kopi der
    driver fra originalen er værre end ingen kopi: den ser vedligeholdt ud.
    Monteringsvalgene er det farlige sted — det var en manglende
    mount-timeout der frøs maskinerne.
    """

    SCRIPT = SCRIPTS / "standalone" / "ait-drives.sh"

    def setUp(self):
        self.text = read(self.SCRIPT)
        self.code = strip_comments(self.text)
        self.common = strip_comments(read(SCRIPTS / "common.sh"))

    def _const(self, text: str, name: str) -> str:
        m = re.search(rf'{name}="([^"]+)"', text)
        self.assertIsNotNone(m, f"{name} mangler")
        return m.group(1)

    def test_mount_options_match_common(self):
        for name in ("CIFS_MOUNT_OPTS", "CIFS_SYSTEMD_OPTS"):
            with self.subTest(constant=name):
                self.assertEqual(
                    self._const(self.code, name),
                    self._const(self.common, name),
                    f"{name} er drevet fra common.sh — ret begge steder",
                )

    def test_the_fstab_line_uses_both_constants(self):
        """Ikke test-monteringen — den linje der havner i /etc/fstab."""
        line = [ln for ln in self.code.splitlines() if "dir_mode=0770" in ln]
        self.assertTrue(line, "ingen fstab-linje fundet")
        self.assertIn("CIFS_MOUNT_OPTS", line[0])
        self.assertIn("CIFS_SYSTEMD_OPTS", line[0])

    def test_it_refuses_a_password_flag(self):
        """Alt på kommandolinjen kan læses med ps, og det er et
        domænekodeord. Flaget findes kun for at afvise det."""
        self.assertIn("--password", self.code)
        self.assertRegex(self.code, r"--password\|--password=\*")

    def test_the_server_is_never_a_literal(self):
        """Værtsnavnet er intern infrastruktur og hører i konfiguration."""
        self.assertNotRegex(self.code, r"SERVER=[\"']?[a-z0-9-]+\.")
        self.assertIn("find_var", self.code)

    def test_username_loses_the_domain(self):
        """WIN\\mpark og mpark@dtu.dk er begge rimelige at taste, men
        credentials-filen skal have kortnavnet — ellers fejler godkendelsen
        uden at sige hvorfor."""
        block = re.search(r'U_RAW="\$U"\n(.*?)\nif \[\[ "\$U" != "\$U_RAW"',
                          self.code, re.DOTALL)
        self.assertIsNotNone(block, "afkortningen af brugernavnet er væk")
        for raw, want in (("WIN\\mpark", "mpark"),
                          ("mpark@dtu.dk", "mpark"),
                          ("mpark", "mpark")):
            with self.subTest(raw=raw):
                proc = subprocess.run(
                    ["bash", "-c", f'U={raw!r}\n{block.group(1)}\nprintf "%s" "$U"'],
                    capture_output=True, text=True, timeout=30)
                self.assertEqual(proc.stdout, want, proc.stderr)


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
