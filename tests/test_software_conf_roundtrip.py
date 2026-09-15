"""software.conf skal overleve en tur gennem Software-dialogen.

Dialogen laeser filen, viser sektionerne og skriver hele filen tilbage naar
brugeren trykker Gem. Da [pwa] blev tilfoejet til den leverede software.conf
i v1.7.0, blev writeren ikke opdateret: parseren laeste sektionen, writeren
skrev den ikke tilbage, og et enkelt tryk paa Gem slettede alle ni
Microsoft 365-genveje uden at sige noget.

Testen handler derfor ikke om formatet, men om at intet forsvinder.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from dtu_sustain_setup.input_dialog import (
    _parse_software_conf,
    _write_software_conf,
)

REPO = Path(__file__).resolve().parent.parent
SHIPPED = REPO / "data" / "software.conf"


class TestRoundTrip(unittest.TestCase):
    def _roundtrip(self, text: str) -> dict[str, list[str]]:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "software.conf")
            path.write_text(text, encoding="utf-8")
            before = _parse_software_conf(path)
            _write_software_conf(path, before)
            return _parse_software_conf(path)

    def test_the_shipped_file_survives_a_save(self):
        """Den fil brugerne faktisk har, gennem dialogen og tilbage."""
        text = SHIPPED.read_text(encoding="utf-8")
        before = _parse_software_conf(SHIPPED)
        after = self._roundtrip(text)
        for section, packages in before.items():
            with self.subTest(section=section):
                self.assertEqual(after.get(section), packages)

    def test_the_pwa_section_is_not_dropped(self):
        """Den konkrete regression: ni apps forsvandt ved et tryk paa Gem."""
        after = self._roundtrip(
            "[flatpak]\norg.x.Y\n\n[pwa]\noutlook\nword\n\n[cisco]\ncisco-secure-client\n"
        )
        self.assertEqual(after["pwa"], ["outlook", "word"])

    def test_an_unknown_section_is_preserved_too(self):
        """Naeste gang nogen tilfoejer en sektion til software.conf uden at
        roere dialogen, skal den ikke forsvinde paa samme maade."""
        after = self._roundtrip("[flatpak]\norg.x.Y\n\n[noget-nyt]\nabc\n")
        self.assertEqual(after.get("noget-nyt"), ["abc"])

    def test_the_shipped_file_still_has_its_nine_pwas(self):
        self.assertEqual(len(_parse_software_conf(SHIPPED)["pwa"]), 9)


if __name__ == "__main__":
    unittest.main()
