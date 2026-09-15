"""Modultabellen i README skal matche modules.py.

Tabellen blev vedligeholdt i hånden og rådnede uden at nogen opdagede det:
den manglede Login Screen, påstod 15 moduler hvor der var 16, og havde en
kolonne med en stjerne som ingen fodnote forklarede. En tabel ser lige
rigtig ud uanset hvad der står i den, så det skal en test sige.

Testen er derfor ikke "er tabellen pæn", men "siger README og koden det
samme". Den fejler, så snart nogen tilføjer eller fjerner et modul uden at
køre generatoren.
"""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOL = REPO / "tools" / "module_table.py"


class TestModuleTable(unittest.TestCase):
    def test_readme_matches_the_code(self):
        proc = subprocess.run(
            [sys.executable, str(TOOL), "--check"],
            capture_output=True, text=True, cwd=REPO,
        )
        self.assertEqual(
            proc.returncode, 0,
            proc.stdout + proc.stderr
            + "\nKør: python3 tools/module_table.py --write",
        )

    def test_every_module_appears(self):
        """--check sammenligner hele blokken. Denne siger hvad der mangler,
        når den fejler, i stedet for at vise en diff af 16 linjer."""
        sys.path.insert(0, str(REPO / "src"))
        from dtu_sustain_setup.modules import MODULES

        readme = (REPO / "README.md").read_text(encoding="utf-8")
        missing = [m.title for m in MODULES if f"**{m.title}**" not in readme]
        self.assertEqual(missing, [], f"ikke nævnt i README: {missing}")


if __name__ == "__main__":
    unittest.main()
