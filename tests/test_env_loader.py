"""Smoke tests for dtu_sustain_setup.env_loader.

The env loader parses files that may contain a domain password, so the two
properties that matter are: values survive parsing intact (quotes, spaces,
special characters), and secrets never appear in full in the human-readable
summary. Run with: python3 -m unittest discover -s tests -v
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from dtu_sustain_setup.env_loader import (  # noqa: E402
    KNOWN_VARS,
    SECRET_VARS,
    parse_env_file,
)


def parse(text: str):
    with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as fh:
        fh.write(text)
        path = Path(fh.name)
    try:
        return parse_env_file(path)
    finally:
        path.unlink()


class TestParsing(unittest.TestCase):
    def test_plain_and_quoted_values(self):
        r = parse(
            'DTU_USERNAME=mpark\n'
            'DTU_HOSTNAME="SUS-EL-01"\n'
            "DTU_ADMIN_USERNAME='adm-mpark'\n"
        )
        self.assertEqual(r.values["DTU_USERNAME"], "mpark")
        self.assertEqual(r.values["DTU_HOSTNAME"], "SUS-EL-01")
        self.assertEqual(r.values["DTU_ADMIN_USERNAME"], "adm-mpark")
        self.assertEqual(r.errors, [])

    def test_export_prefix_and_comments(self):
        r = parse(
            "# a comment\n"
            "\n"
            "export DTU_USERNAME=mpark\n"
            "   # indented comment\n"
        )
        self.assertEqual(r.values["DTU_USERNAME"], "mpark")
        self.assertEqual(r.errors, [])

    def test_password_with_spaces_and_specials_survives(self):
        # The exact class of value that breaks naive shell parsing.
        pw = "p4ss w/ spaces'n$quotes"
        r = parse(f'DTU_PASSWORD="{pw}"\n')
        self.assertEqual(r.values["DTU_PASSWORD"], pw)

    def test_unknown_dtu_keys_are_reported_not_silently_dropped(self):
        r = parse("DTU_NOT_A_REAL_VAR=x\n")
        self.assertIn("DTU_NOT_A_REAL_VAR", r.unknown)
        self.assertNotIn("DTU_NOT_A_REAL_VAR", r.values)

    def test_non_dtu_keys_are_ignored_entirely(self):
        r = parse("PATH=/usr/bin\nHOME=/root\n")
        self.assertEqual(r.values, {})
        self.assertEqual(r.unknown, [])

    def test_malformed_line_records_error_without_raising(self):
        r = parse("DTU_USERNAME=mpark\nthis line has no equals sign\n")
        self.assertEqual(r.values["DTU_USERNAME"], "mpark")
        self.assertTrue(any("missing '='" in e for e in r.errors))

    def test_unreadable_file_reports_error(self):
        r = parse_env_file(Path("/nonexistent/does-not-exist.env"))
        self.assertEqual(r.values, {})
        self.assertTrue(r.errors)


class TestSecretMasking(unittest.TestCase):
    def test_password_is_not_shown_in_summary(self):
        pw = "SuperSecret123"
        r = parse(f'DTU_USERNAME=mpark\nDTU_PASSWORD={pw}\n')
        summary = r.summary()
        self.assertNotIn(pw, summary)
        self.assertIn("DTU_PASSWORD", summary)
        self.assertIn("mpark", summary)  # non-secrets stay readable

    def test_every_secret_var_is_masked(self):
        for key in SECRET_VARS:
            with self.subTest(key=key):
                r = parse(f"{key}=VerySecretValue\n")
                self.assertNotIn("VerySecretValue", r.summary())

    def test_secret_vars_are_a_subset_of_known_vars(self):
        # A secret that is not in KNOWN_VARS would never be parsed, so the
        # masking for it would be dead code and give false confidence.
        self.assertTrue(SECRET_VARS.issubset(set(KNOWN_VARS)))


if __name__ == "__main__":
    unittest.main()
