#!/usr/bin/env python3
"""Genererer modultabellen i README.md ud fra modules.py.

Tabellen blev vedligeholdt i hånden og rådnede. Den manglede Login Screen,
påstod 15 moduler hvor der var 16, og havde en kolonne med en stjerne som
ingen fodnote forklarede. Den slags opdages ikke ved at læse, for en tabel
ser lige rigtig ud uanset hvad der står i den.

Kun det der faktisk står i koden bliver genereret. Afdelingsforskelle
(hvilke moduler der ikke giver mening på AIT) kender modules.py ikke noget
til, så de står som prosa under tabellen og skrives fortsat i hånden.

    python3 tools/module_table.py            # skriv tabellen til stdout
    python3 tools/module_table.py --write    # opdatér README.md
    python3 tools/module_table.py --check    # exit 1 hvis README er bagud
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
README = REPO / "README.md"
BEGIN = "<!-- BEGIN modultabel: genereret af tools/module_table.py -->"
END = "<!-- END modultabel -->"

sys.path.insert(0, str(REPO / "src"))

INPUT_LABELS = {
    "none": "—",
    "credentials": "DTU-login",
    "username": "Brugernavn",
    "domain_join": "Hostname + admin",
    "software": "Pakkevalg",
}
TAB_LABELS = {"admin": "Admin", "user": "User"}


def render() -> str:
    from dtu_sustain_setup.modules import MODULES

    active = sum(1 for m in MODULES if m.enabled)
    disabled = len(MODULES) - active
    lines = [
        f"{len(MODULES)} moduler i alt: {active} aktive"
        + (f" og {disabled} deaktiveret." if disabled else ".")
        + " Alle kræver root og kører via",
        "`pkexec`. **Fane** er den af GUI'ens to faner modulet ligger på:",
        "*Admin* kører uden brugerens egne credentials, *User* kræver dem.",
        "",
        "| # | Modul | Hvad det gør | Fane | Input |",
        "|---|---|---|:-:|---|",
    ]
    for number, module in enumerate(MODULES, 1):
        # description er knapteksten og har et linjeskift midt i.
        what = module.description.replace("\n", " ").strip()
        name = f"**{module.title}**"
        if not module.enabled:
            name += " *(deaktiveret)*"
        lines.append(
            f"| {number} | {name} | {what} | {TAB_LABELS.get(module.script_type, module.script_type)} "
            f"| {INPUT_LABELS.get(module.input_type, module.input_type)} |"
        )
    return "\n".join(lines)


def _split(text: str) -> tuple[str, str]:
    # (.*?) uden krav om linjeskift omkring, saa en tom blok ogsaa matcher —
    # ellers kan markoererne ikke saettes ind foer foerste generering.
    match = re.search(
        re.escape(BEGIN) + r"\n?(.*?)\n?" + re.escape(END), text, re.DOTALL
    )
    if not match:
        sys.exit(f"Markørerne findes ikke i {README}. Forventede:\n{BEGIN}\n…\n{END}")
    return match.group(1), match.group(0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    table = render()
    if not (args.write or args.check):
        print(table)
        return 0

    text = README.read_text(encoding="utf-8")
    current, whole = _split(text)
    if args.check:
        if current.strip() == table.strip():
            print("✅ Modultabellen i README matcher modules.py.")
            return 0
        print("❌ Modultabellen i README er bagud for modules.py.")
        print("   Kør: python3 tools/module_table.py --write")
        return 1

    README.write_text(text.replace(whole, f"{BEGIN}\n{table}\n{END}"), encoding="utf-8")
    print(f"✅ Modultabellen skrevet til {README.name}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
