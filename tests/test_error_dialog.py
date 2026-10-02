"""The error dialog tells IT support what went wrong. A wrong diagnosis is
worse than none: it sends them looking in the wrong place.

On 2 Oct 2026 a Software module failure was diagnosed as "killed (out of
memory)". The OOM pattern matched case-insensitively and without word
boundaries, so it found "oom" in "us.zoom.Zoom", which is in that module's
output every single time. The real cause, a package left half-installed by
another module, had no pattern at all.

These cases are the real outputs from that day, shortened.
"""
import re
import unittest

from dtu_sustain_setup.error_dialog import ERROR_PATTERNS, _classify

DPKG_PROMPT = (
    "Setting up packages-microsoft-prod (1.2-ubuntu26.04)...\n"
    "*** microsoft-prod.list (Y/I/N/O/D/Z) [default=N] ? dpkg: error processing "
    "package packages-microsoft-prod (--configure):\n"
    " end of file on stdin at conffile prompt\n"
    "E: Sub-process /usr/bin/dpkg returned an error code (1)\n"
)
UNFINISHED = "A package installation was left unfinished"
DPKG_FAILED = "A package could not be installed (dpkg failed)"
KILLED = "The process was killed (out of memory, or a signal)"


class TestRealOutputs(unittest.TestCase):

    def test_software_module_is_not_out_of_memory(self):
        out = ("Flatpak apps: com.microsoft.Edge us.zoom.Zoom "
               "io.github.ungoogled_software.ungoogled_chromium\n" + DPKG_PROMPT)
        self.assertEqual(_classify(out)[0], UNFINISHED)

    def test_defender_conffile_prompt(self):
        out = "[2/6] Installing Microsoft keyring...\n" + DPKG_PROMPT
        self.assertEqual(_classify(out)[0], UNFINISHED)

    def test_quiet_apt_leaves_only_the_dpkg_line(self):
        """rdp.sh and the auto-update script hide apt's output."""
        out = ("[1/7] Installing xrdp and xorgxrdp...\n"
               "E: Sub-process /usr/bin/dpkg returned an error code (1)\n")
        self.assertEqual(_classify(out)[0], DPKG_FAILED)

    def test_the_fix_names_the_command_that_works(self):
        fix = _classify(DPKG_PROMPT)[1]
        self.assertIn("--force-confnew --force-confmiss --configure -a", fix)


class TestNoFalseOutOfMemory(unittest.TestCase):

    def test_zoom_alone_is_not_oom(self):
        self.assertNotEqual(_classify("Installing us.zoom.Zoom\nsomething failed")[0], KILLED)

    def test_words_containing_the_short_codes(self):
        for text in ("Zoom", "bloom", "classroom", "Leiomyoma", "rodeio",
                     "zerofs", "recipepipe"):
            with self.subTest(text=text):
                self.assertEqual(_classify(f"error near {text}")[0], "Unknown error")

    def test_a_real_oom_kill_is_still_recognised(self):
        self.assertEqual(_classify("Out of memory: Killed process 1234 (python3)")[0], KILLED)
        self.assertEqual(_classify("bash: line 1: 4242 Killed  python3 x.py")[0], KILLED)


class TestPatternHygiene(unittest.TestCase):

    def test_short_codes_do_not_match_inside_a_word(self):
        """Matching is case-insensitive, so a short code like OOM without \\b
        will sooner or later be found inside an ordinary word. Covers every
        alternative that is five letters or fewer, including ones added later."""
        checked = 0
        for entry in ERROR_PATTERNS:
            for alt in entry.pattern.split("|"):
                code = alt.replace(r"\b", "").strip("()")
                if not re.fullmatch(r"[A-Za-z]{2,5}", code):
                    continue
                checked += 1
                with self.subTest(pattern=entry.pattern, code=code):
                    self.assertIsNone(
                        re.search(entry.pattern, f"x{code}x", re.IGNORECASE),
                        f"{code!r} matches inside a word; add \\b")
        self.assertGreaterEqual(checked, 4, "the test no longer finds the short codes")

    def test_every_pattern_compiles(self):
        for entry in ERROR_PATTERNS:
            with self.subTest(title=entry.title):
                re.compile(entry.pattern)


if __name__ == "__main__":
    unittest.main()
