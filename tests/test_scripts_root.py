"""Where the app looks for scripts/, in both layouts it runs from.

Denne fil findes fordi rettelsen den beskriver nåede en udgivelse. Da
distributionsvalget blev skåret ned til Debian/Ubuntu, forsvandt den
hardkodede /opt-fallback i get_scripts_dir, og tilbage stod kun den
repo-relative sti. Installeret pegede den på /opt/scripts/ubuntu, som ikke
findes — så hvert eneste modul blev "ikke fundet", ikke kun update-latest.

Testene kører den rigtige funktion mod et træ på disken frem for at
efterligne stilogikken, for det var netop stilogikken der var forkert.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PKG = REPO / "src" / "dtu_sustain_setup"
SCRIPTS = REPO / "scripts"

PROBE = (
    "from dtu_sustain_setup.distro import get_scripts_dir, detect_distro\n"
    "d = get_scripts_dir(detect_distro())\n"
    "print(d)\n"
    "print('MODULES_OK' if (d / 'domain-join.sh').exists() else 'MODULES_MISSING')\n"
    "print('UPDATE_OK' if (d.parent / 'update-latest.sh').exists() else 'UPDATE_MISSING')\n"
)


def probe(pythonpath: Path) -> list[str]:
    proc = subprocess.run(
        [sys.executable, "-c", PROBE],
        capture_output=True, text=True, timeout=60,
        env={"PYTHONPATH": str(pythonpath), "PATH": "/usr/bin:/bin"},
    )
    if proc.returncode != 0:
        raise AssertionError(proc.stderr)
    return proc.stdout.splitlines()


class TestScriptsRootResolution(unittest.TestCase):
    def test_installed_layout(self):
        """<prefix>/dtu_sustain_setup/ ved siden af <prefix>/scripts/ —
        sådan lægger både make install, deb'en og rpm'en det."""
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / "opt" / "dtu-sustain-setup"
            prefix.mkdir(parents=True)
            shutil.copytree(PKG, prefix / "dtu_sustain_setup")
            shutil.copytree(SCRIPTS, prefix / "scripts")
            out = probe(prefix)
        self.assertIn("MODULES_OK", out, f"modulerne blev ikke fundet: {out}")
        self.assertIn("UPDATE_OK", out, f"update-latest.sh blev ikke fundet: {out}")

    def test_repo_layout(self):
        """<repo>/src/dtu_sustain_setup/ med scripts/ ét niveau højere."""
        out = probe(REPO / "src")
        self.assertIn("MODULES_OK", out, f"modulerne blev ikke fundet: {out}")
        self.assertIn("UPDATE_OK", out, f"update-latest.sh blev ikke fundet: {out}")

    def test_prefix_other_than_opt(self):
        """Den gamle fallback var hardkodet til /opt/dtu-sustain-setup og
        dækkede derfor ikke en installation under et andet prefix."""
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / "usr" / "local" / "share" / "dtu-sustain-setup"
            prefix.mkdir(parents=True)
            shutil.copytree(PKG, prefix / "dtu_sustain_setup")
            shutil.copytree(SCRIPTS, prefix / "scripts")
            out = probe(prefix)
        self.assertIn("MODULES_OK", out, f"modulerne blev ikke fundet: {out}")


if __name__ == "__main__":
    unittest.main()
