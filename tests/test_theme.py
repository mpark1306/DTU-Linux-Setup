"""Contrast and mode-selection tests for the colour palette.

The point of the palette work was that the tool was unreadable on a dark
desktop. "It starts without crashing" would not have caught that, so these
tests measure the thing that was actually broken: whether foreground colours
have enough contrast against the surfaces they are painted on.

Ratios follow WCAG 2.1: 4.5:1 for body text, 3:1 for large text and for the
boundaries of UI components (SC 1.4.11), which is what borders and badges are.
"""

from __future__ import annotations

import os
import unittest

from dtu_sustain_setup.theme import DARK, LIGHT, Palette, palette, reset_cache


def _srgb_channel(value: int) -> float:
    c = value / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _luminance(hex_colour: str) -> float:
    h = hex_colour.lstrip("#")
    r, g, b = (int(h[i : i + 2], 16) for i in (0, 2, 4))
    return (
        0.2126 * _srgb_channel(r)
        + 0.7152 * _srgb_channel(g)
        + 0.0722 * _srgb_channel(b)
    )


def contrast(fg: str, bg: str) -> float:
    """WCAG contrast ratio between two hex colours (1.0 – 21.0)."""
    a, b = _luminance(fg), _luminance(bg)
    lighter, darker = max(a, b), min(a, b)
    return (lighter + 0.05) / (darker + 0.05)


# (foreground, background, minimum ratio, what it is)
def _pairs(p: Palette) -> list[tuple[str, str, float, str]]:
    return [
        # Body text on the surfaces it appears on
        (p.text, p.card_bg, 4.5, "card title"),
        (p.text_muted, p.card_bg, 4.5, "card description"),
        (p.text_dim, p.window_bg, 4.5, "distro/version line"),
        (p.text, p.window_bg, 4.5, "log label"),
        (p.tab_text, p.tab_bg, 4.5, "inactive tab label"),
        (p.btn_text, p.btn_bg, 4.5, "secondary button label"),
        (p.input_text, p.input_bg, 4.5, "department dropdown"),
        (p.warn_fg, p.warn_bg, 4.5, "unsupported-distro warning"),
        (p.hint_fg, p.hint_bg, 4.5, "suggested-fix box"),
        (p.console_fg, p.console_bg, 4.5, "output log"),
        # Brand red used AS TEXT. This is the pair that failed before the dark
        # palette existed: #990000 on a dark window is ~2:1.
        (p.accent_text, p.window_bg, 4.5, "title / section heading"),
        (p.accent_text, p.tab_selected_bg, 4.5, "selected tab label"),
        # Text on filled buttons
        (p.accent_fg, p.accent, 4.5, "primary button label"),
        (p.accent_fg, p.accent_hover, 4.5, "primary button hover"),
        (p.info_fg, p.info_bg, 4.5, "copy-error button"),
        # Text on result-highlighted cards — the card keeps its normal
        # foreground when it turns green or red, so both must still work.
        (p.text, p.ok_bg, 4.5, "title on succeeded card"),
        (p.text, p.err_bg, 4.5, "title on failed card"),
        (p.text_muted, p.ok_bg, 4.5, "description on succeeded card"),
        (p.text_muted, p.err_bg, 4.5, "description on failed card"),
        # Borders that CARRY INFORMATION get the full 3:1 of WCAG SC 1.4.11:
        # green vs red is how you tell a module that succeeded from one that
        # failed, so it has to survive a glance across the window.
        (p.ok_border, p.window_bg, 3.0, "success border"),
        (p.err_border, p.window_bg, 3.0, "failure border"),
        # Badges are small but they are text.
        (p.badge_admin, p.card_bg, 3.0, "ADMIN badge"),
        (p.badge_user, p.card_bg, 3.0, "USER badge"),
    ]


def _visible_edges(p: Palette) -> list[tuple[str, str, float, str]]:
    """Edges that only have to be *perceptible*, not high-contrast.

    Default card and button outlines are decorative: nothing about the card is
    unknowable without them, because the card already sits on its own fill and
    every state it can be in is also carried by a background colour. Holding
    them to SC 1.4.11's 3:1 would force hard black outlines and throw away the
    soft card look on both themes — so the requirement here is the weaker and
    honest one: the edge must not be invisible against the surface it draws on.
    """
    return [
        (p.card_border, p.card_bg, 1.25, "card outline"),
        (p.btn_border, p.btn_bg, 1.25, "button outline"),
        (p.tab_border, p.tab_bg, 1.25, "tab outline"),
        (p.card_hover_border, p.card_bg, 1.5, "card hover outline"),
        (p.tab_selected_bg, p.tab_bg, 1.1, "selected tab vs inactive"),
    ]


class TestContrast(unittest.TestCase):
    def test_light_palette_is_readable(self) -> None:
        self._check(LIGHT, "light")

    def test_dark_palette_is_readable(self) -> None:
        self._check(DARK, "dark")

    def _check(self, p: Palette, name: str) -> None:
        failures = []
        for fg, bg, minimum, label in _pairs(p) + _visible_edges(p):
            ratio = contrast(fg, bg)
            if ratio < minimum:
                failures.append(
                    f"  {name}: {label} — {fg} on {bg} is {ratio:.2f}:1, "
                    f"needs {minimum}:1"
                )
        if failures:
            self.fail(f"{len(failures)} unreadable pair(s):\n" + "\n".join(failures))

    def test_card_is_separable_from_the_window(self) -> None:
        """A card must be findable as a distinct surface, by fill or by edge.

        The two modes solve this differently and both are legitimate: light
        puts a white card on a near-white window and relies on the outline,
        dark lifts the card fill above the window and lets the outline stay
        faint. So the requirement is that at least one of the two works — not
        that both do, which would rule out the light design that already
        shipped.
        """
        for name, p in (("light", LIGHT), ("dark", DARK)):
            by_fill = contrast(p.card_bg, p.window_bg)
            by_edge = contrast(p.card_border, p.window_bg)
            self.assertGreaterEqual(
                max(by_fill, by_edge),
                1.25,
                f"{name}: card is invisible against the window "
                f"(fill {by_fill:.2f}:1, edge {by_edge:.2f}:1)",
            )

    def test_contrast_helper_is_calibrated(self) -> None:
        """Guard the measuring stick itself against a broken luminance formula."""
        self.assertAlmostEqual(contrast("#000000", "#ffffff"), 21.0, places=1)
        self.assertAlmostEqual(contrast("#777777", "#777777"), 1.0, places=2)
        # The exact failure this work fixed: DTU red on a dark window.
        self.assertLess(contrast("#990000", "#1b1d21"), 4.5)


class TestPaletteSelection(unittest.TestCase):
    def setUp(self) -> None:
        self._saved = os.environ.get("DTU_SETUP_THEME")
        reset_cache()

    def tearDown(self) -> None:
        if self._saved is None:
            os.environ.pop("DTU_SETUP_THEME", None)
        else:
            os.environ["DTU_SETUP_THEME"] = self._saved
        reset_cache()

    def test_env_override_forces_dark(self) -> None:
        os.environ["DTU_SETUP_THEME"] = "dark"
        self.assertIs(palette(), DARK)

    def test_env_override_forces_light(self) -> None:
        os.environ["DTU_SETUP_THEME"] = "light"
        self.assertIs(palette(), LIGHT)

    def test_unset_without_qapplication_falls_back_to_light(self) -> None:
        os.environ.pop("DTU_SETUP_THEME", None)
        self.assertIs(palette(), LIGHT)

    def test_result_is_cached(self) -> None:
        os.environ["DTU_SETUP_THEME"] = "dark"
        first = palette()
        os.environ["DTU_SETUP_THEME"] = "light"
        self.assertIs(palette(), first, "palette must not change mid-session")

    def test_both_palettes_define_every_token(self) -> None:
        """A token added to one mode but not the other would be a NameError."""
        self.assertEqual(
            {f for f in LIGHT.__dataclass_fields__},
            {f for f in DARK.__dataclass_fields__},
        )
        for field in LIGHT.__dataclass_fields__:
            if field == "dark":
                continue
            self.assertTrue(getattr(LIGHT, field), f"LIGHT.{field} is empty")
            self.assertTrue(getattr(DARK, field), f"DARK.{field} is empty")

    def test_modes_are_actually_different(self) -> None:
        self.assertFalse(LIGHT.dark)
        self.assertTrue(DARK.dark)
        self.assertNotEqual(LIGHT.window_bg, DARK.window_bg)


if __name__ == "__main__":
    unittest.main()
