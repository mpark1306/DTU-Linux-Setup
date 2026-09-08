"""Tests for the TPM2 readiness dialog.

The dialog's job is to be believed. A parser that silently drops a line would
show a machine as ready when it is not, which is worse than showing nothing —
so the parsing tests are about what happens to malformed input, not just
well-formed input.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "ubuntu" / "tpm2-enroll.sh"

try:
    from PyQt6.QtWidgets import QApplication

    from dtu_sustain_setup import theme as theme_mod
    from dtu_sustain_setup.tpm2_dialog import CheckItem, Tpm2ReadinessDialog

    _QT_ERROR = None
except Exception as exc:  # pragma: no cover - depends on build environment
    _QT_ERROR = str(exc)

_APP = None


class TestCheckItemParsing(unittest.TestCase):
    def test_wellformed_line(self):
        item = CheckItem.parse(
            "TPM2CHECK|tpm-device|fail|Ingen TPM2|Findes ikke.|Slå TPM til i BIOS."
        )
        self.assertIsNotNone(item)
        self.assertEqual(item.id, "tpm-device")
        self.assertEqual(item.status, "fail")
        self.assertEqual(item.title, "Ingen TPM2")
        self.assertEqual(item.detail, "Findes ikke.")
        self.assertEqual(item.fix, "Slå TPM til i BIOS.")

    def test_empty_trailing_fields(self):
        """An ok item carries no fix; the trailing separators must survive."""
        item = CheckItem.parse("TPM2CHECK|distro|ok|Understøttet|apt-get fundet|")
        self.assertIsNotNone(item)
        self.assertEqual(item.fix, "")

    def test_pipe_in_the_fix_text_does_not_truncate(self):
        """The script strips | from its fields, but if one ever slipped
        through, keeping the tail is better than losing the advice."""
        item = CheckItem.parse("TPM2CHECK|x|warn|T|D|kør a | b")
        self.assertEqual(item.fix, "kør a | b")

    def test_non_marker_lines_are_ignored(self):
        """The script also emits ordinary banner output on the same stream."""
        for line in ("", "[i] Starting", "ok Something", "TPM2CHECKISH|a|b|c|d|e"):
            self.assertIsNone(CheckItem.parse(line))

    def test_truncated_line_is_rejected_not_guessed(self):
        """Too few fields means the format changed. Inventing the missing ones
        would render a check with a blank status as if it had passed."""
        self.assertIsNone(CheckItem.parse("TPM2CHECK|id|ok|title"))

    def test_only_fail_blocks(self):
        for status, blocks in (
            ("fail", True),
            ("warn", False),
            ("ok", False),
            ("info", False),
            ("unknown", False),
        ):
            with self.subTest(status=status):
                item = CheckItem.parse(f"TPM2CHECK|x|{status}|T|D|F")
                self.assertEqual(item.blocks, blocks)


class TestLuksDetection(unittest.TestCase):
    """Hvorfor detektionen ikke må hænge på lsblk alene.

    lsblk's FSTYPE-kolonne kommer fra udev. Kan udev ikke svare, prober lsblk
    selv, og det kræver læseadgang til rådisken — som parathedskontrollen ikke
    har, fordi den med vilje kører uden rettigheder. Så er kolonnen tom for
    ALLE partitioner, og en maskine der beder om LUKS-adgangskoden ved boot
    bliver meldt som ukrypteret. Testene her kører netop på en maskine hvor
    lsblk INTET crypto_LUKS ser, og kræver at de øvrige kilder finder disken
    alligevel.
    """

    @classmethod
    def setUpClass(cls):
        # En rigtig blokenhed at pege på: kandidater der ikke findes bliver
        # kasseret, og det skal de blive ved med at gøre.
        cls.device = None
        for entry in sorted(Path("/sys/class/block").iterdir()):
            if (entry / "partition").exists() and Path("/dev", entry.name).is_block_device():
                cls.device = entry.name
                break

    def setUp(self):
        if self.device is None:
            self.skipTest("ingen partition at pege testen på")
        self.tmp = tempfile.mkdtemp()
        self.sysfs = Path(self.tmp, "sys")
        self.crypttab = Path(self.tmp, "crypttab")
        self.crypttab.write_text("")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _dm(self, index: int, uuid: str, slaves: tuple[str, ...] = ()):
        node = self.sysfs / f"dm-{index}"
        (node / "dm").mkdir(parents=True)
        (node / "dm" / "uuid").write_text(uuid + "\n")
        for slave in slaves:
            (node / "slaves" / slave).mkdir(parents=True)

    def _luks_line(self):
        for line in self._run().splitlines():
            item = CheckItem.parse(line)
            if item and item.id == "luks-device":
                return item
        self.fail("luks-device blev slet ikke rapporteret")

    def _run(self) -> str:
        env = dict(os.environ)
        env["SYSFS_BLOCK"] = str(self.sysfs)
        env["CRYPTTAB_PATH"] = str(self.crypttab)
        return subprocess.run(
            ["bash", str(SCRIPT), "--check"],
            capture_output=True, text=True, timeout=60, env=env,
        ).stdout

    def test_open_mapping_is_enough_when_lsblk_is_blind(self):
        """Kører maskinen fra en LUKS-disk, ER mappingen åben lige nu."""
        self._dm(0, "CRYPT-LUKS2-9f3ab1c2-root_crypt", (self.device,))
        item = self._luks_line()
        self.assertEqual(item.status, "ok")
        self.assertIn(self.device, item.detail)

    def test_plain_dm_crypt_is_not_luks(self):
        self._dm(0, "CRYPT-PLAIN-swap", (self.device,))
        self._dm(1, "LVM-abc123")
        self.assertEqual(self._luks_line().status, "fail")

    def test_crypttab_uuid_is_resolved(self):
        uuid = None
        by_uuid = Path("/dev/disk/by-uuid")
        if by_uuid.is_dir():
            for link in by_uuid.iterdir():
                if link.resolve().name == self.device:
                    uuid = link.name
                    break
        if uuid is None:
            self.skipTest("ingen by-uuid-henvisning til testenheden")
        self.crypttab.write_text(f"root_crypt UUID={uuid} none luks,discard\n")
        item = self._luks_line()
        self.assertEqual(item.status, "ok")
        self.assertIn(self.device, item.detail)

    def test_same_disk_from_two_sources_counts_once(self):
        """Ellers beder kontrollen brugeren vælge mellem disken og sig selv."""
        self._dm(0, "CRYPT-LUKS2-9f3ab1c2-root_crypt", (self.device,))
        self.crypttab.write_text(f"root_crypt /dev/{self.device} none luks\n")
        self.assertEqual(self._luks_line().status, "ok")

    def test_random_key_swap_is_ignored(self):
        """Krypteret swap står i crypttab på helt almindelige installationer og
        er plain dm-crypt. Talte den med, kunne modulet binde sig til swap."""
        self.crypttab.write_text(
            f"cryptswap /dev/{self.device} /dev/urandom swap,cipher=aes-xts-plain64\n"
        )
        self.assertEqual(self._luks_line().status, "fail")

    def test_missing_device_is_not_a_candidate(self):
        self.crypttab.write_text("root_crypt /dev/does-not-exist none luks\n")
        self.assertEqual(self._luks_line().status, "fail")

    def test_failure_names_what_was_looked_at(self):
        """Forskellen på 'disken er ikke krypteret' og 'vi kunne ikke se det'
        er hele forskellen på hvad brugeren skal gøre bagefter."""
        item = self._luks_line()
        self.assertEqual(item.status, "fail")
        self.assertIn("lsblk", item.detail)
        self.assertIn("crypttab", item.detail)


class TestScriptContract(unittest.TestCase):
    """The dialog and the script have to agree on the format."""

    @classmethod
    def setUpClass(cls):
        cls.output = subprocess.run(
            ["bash", str(SCRIPT), "--check"],
            capture_output=True, text=True, timeout=60,
        ).stdout

    def test_check_mode_runs_without_root(self):
        """It must, or the user has to authenticate before learning that their
        machine has no TPM at all."""
        self.assertTrue(self.output.strip(), "--check produced no output")

    def test_every_emitted_line_parses(self):
        emitted = [ln for ln in self.output.splitlines() if ln.startswith("TPM2CHECK|")]
        self.assertTrue(emitted, "no TPM2CHECK lines emitted")
        for line in emitted:
            with self.subTest(line=line[:60]):
                self.assertIsNotNone(CheckItem.parse(line))

    def test_statuses_are_ones_the_dialog_can_render(self):
        known = {"ok", "warn", "fail", "info", "unknown"}
        for line in self.output.splitlines():
            item = CheckItem.parse(line)
            if item:
                with self.subTest(check=item.id):
                    self.assertIn(item.status, known)

    def test_the_checks_the_user_asked_about_are_present(self):
        ids = {i.id for i in map(CheckItem.parse, self.output.splitlines()) if i}
        for expected in ("tpm-device", "secure-boot", "luks-device"):
            self.assertIn(expected, ids)

    def test_actionable_findings_carry_a_fix(self):
        """A red line with no advice tells the user they are stuck."""
        for line in self.output.splitlines():
            item = CheckItem.parse(line)
            if item and item.status in ("warn", "fail"):
                with self.subTest(check=item.id):
                    self.assertTrue(item.fix.strip(), f"{item.id} has no fix text")

    def test_check_mode_changes_nothing(self):
        """Read-only by construction: it must not touch the packages, the
        initramfs or the LUKS header."""
        forbidden = ("apt-get install", "clevis luks bind", "update-initramfs",
                     "luksAddKey", "cryptsetup luksAddKey")
        for token in forbidden:
            self.assertNotIn(token, self.output)


@unittest.skipIf(_QT_ERROR, f"PyQt6 unavailable: {_QT_ERROR}")
class TestDialogBuilds(unittest.TestCase):
    def _build(self, theme):
        global _APP
        os.environ["DTU_SETUP_THEME"] = theme
        theme_mod.reset_cache()
        if _APP is None:
            _APP = QApplication.instance() or QApplication([])
        dlg = Tpm2ReadinessDialog(None, SCRIPT)
        _APP.processEvents()
        return dlg

    def tearDown(self):
        os.environ.pop("DTU_SETUP_THEME", None)
        theme_mod.reset_cache()

    def test_builds_in_light_theme(self):
        dlg = self._build("light")
        self.assertTrue(dlg.windowTitle())
        self.assertFalse(dlg.should_proceed(), "must not default to proceeding")
        dlg.close()

    def test_builds_in_dark_theme(self):
        dlg = self._build("dark")
        self.assertTrue(dlg.windowTitle())
        dlg.close()

    def test_no_stylesheet_has_unresolved_braces(self):
        """A malformed Qt stylesheet does not raise — Qt drops the rule and
        the widget renders unstyled. This dialog shipped with exactly that
        bug: a non-f-string fragment left a literal }} behind."""
        from PyQt6.QtWidgets import QWidget

        dlg = self._build("dark")
        for w in [dlg] + dlg.findChildren(QWidget):
            sheet = w.styleSheet()
            if sheet:
                with self.subTest(widget=type(w).__name__):
                    self.assertNotIn("{{", sheet)
                    self.assertNotIn("}}", sheet)
        dlg.close()

    def test_rows_render_for_real_output(self):
        dlg = self._build("light")
        # processEvents alone does not wait for the child; the check shells out
        # and takes a moment.
        self.assertIsNotNone(dlg._proc)
        dlg._proc.waitForFinished(30000)
        _APP.processEvents()
        self.assertTrue(dlg._items, "no checks were parsed from the script")
        dlg._render()
        self.assertGreater(dlg._list_layout.count(), 1, "no rows rendered")
        dlg.close()


if __name__ == "__main__":
    unittest.main()
