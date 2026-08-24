"""Offscreen smoke test: the window must build in both themes.

The palette work touched almost every stylesheet in the app. A malformed
f-string in a Qt stylesheet does not raise — Qt silently drops the rule and the
widget renders unstyled — so this walks the built window and checks that every
stylesheet it applied actually parsed and resolved.

Skipped when PyQt6 or an offscreen platform plugin is unavailable, so a
developer without Qt can still run the rest of the suite.
"""

from __future__ import annotations

import os
import re
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

try:
    from PyQt6.QtWidgets import QApplication, QWidget

    _QT_ERROR = None
except Exception as exc:  # pragma: no cover - depends on the build environment
    _QT_ERROR = str(exc)


# The QApplication has to outlive every test in this module. Letting it fall
# out of scope destroys the C++ objects underneath the widgets, and the next
# attribute access raises "wrapped C/C++ object has been deleted".
_APP = None

_HEX = re.compile(r"#[0-9a-fA-F]{3,8}\b")
# A brace that survived into the applied stylesheet means an f-string escaped
# its literal braces wrongly ("{{" left as-is, or a placeholder never filled).
_UNRESOLVED = re.compile(r"[{][{]|[}][}]")


@unittest.skipIf(_QT_ERROR, f"PyQt6 unavailable: {_QT_ERROR}")
class TestWindowBuilds(unittest.TestCase):
    def _build(self, theme: str):
        os.environ["DTU_SETUP_THEME"] = theme

        from dtu_sustain_setup import theme as theme_mod

        theme_mod.reset_cache()

        global _APP
        if _APP is None:
            _APP = QApplication.instance() or QApplication([])

        from dtu_sustain_setup.main_window import MainWindow

        window = MainWindow()
        _APP.processEvents()
        return window, theme_mod.palette()

    def _stylesheets(self, root: QWidget) -> list[tuple[str, str]]:
        found = []
        for widget in [root] + root.findChildren(QWidget):
            sheet = widget.styleSheet()
            if sheet:
                found.append((type(widget).__name__, sheet))
        return found

    def _check(self, theme: str) -> None:
        window, pal = self._build(theme)
        try:
            sheets = self._stylesheets(window)
            self.assertGreater(len(sheets), 5, "no styling was applied at all")

            allowed = {
                getattr(pal, f).lower()
                for f in pal.__dataclass_fields__
                if isinstance(getattr(pal, f), str)
            }

            for widget_name, sheet in sheets:
                self.assertIsNone(
                    _UNRESOLVED.search(sheet),
                    f"{theme}/{widget_name}: unresolved f-string braces in:\n{sheet}",
                )
                for colour in _HEX.findall(sheet):
                    self.assertIn(
                        colour.lower(),
                        allowed,
                        f"{theme}/{widget_name}: {colour} is not a palette token "
                        f"— a hardcoded colour crept back in:\n{sheet}",
                    )
        finally:
            window.close()
            os.environ.pop("DTU_SETUP_THEME", None)

    def test_light_theme_builds_with_only_palette_colours(self) -> None:
        self._check("light")

    def test_dark_theme_builds_with_only_palette_colours(self) -> None:
        self._check("dark")


if __name__ == "__main__":
    unittest.main()
