"""Colour palette for DTU Linux Setup.

Every colour the UI paints comes from here. Before this module the values were
inline hex literals scattered across the widget code, all of them picked for a
light desktop — on a dark Plasma theme the tool rendered dark-grey text on the
system's dark window background and was effectively unreadable.

The palette is resolved once, from the running QApplication's own palette, so
the tool follows whatever the desktop is set to instead of forcing a look.

Two deliberate constraints:

* Qt palette *roles* are not enough on their own. Cards, badges and result
  highlights have no matching role (there is no "this module failed" role), so
  the tokens below are explicit values chosen per mode rather than derived.
  The system palette decides *which* set is used, not what is in it.
* The palette is resolved at startup and cached. A desktop theme switch while
  the window is open will not repaint it; that costs a restart, and avoiding it
  would mean re-applying every stylesheet on a palette event for a case that
  effectively never happens during a 10-minute setup run.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Palette:
    """Named colour tokens. One instance per mode."""

    dark: bool

    # DTU brand. `accent` is a fill that always carries `accent_fg` text;
    # `accent_text` is the same brand red adjusted to stay legible *as text*
    # on this mode's background. On dark backgrounds #990000 fails contrast,
    # which is why these are two tokens and not one.
    accent: str
    accent_hover: str
    accent_fg: str
    accent_text: str

    # Surfaces
    window_bg: str
    panel_bg: str
    card_bg: str
    card_border: str
    card_hover_bg: str
    card_hover_border: str
    card_disabled_bg: str
    card_disabled_border: str

    # Text
    text: str
    text_muted: str
    text_dim: str
    badge_admin: str
    badge_user: str

    # Run results
    ok_bg: str
    ok_border: str
    err_bg: str
    err_border: str

    # Tabs
    tab_bg: str
    tab_selected_bg: str
    tab_text: str
    tab_border: str
    tab_hover_bg: str

    # Secondary buttons
    btn_bg: str
    btn_hover_bg: str
    btn_border: str
    btn_text: str
    btn_disabled_bg: str
    btn_disabled_fg: str
    btn_disabled_border: str

    # Inputs
    input_bg: str
    input_text: str
    input_border: str
    selection_bg: str
    selection_text: str

    # Notices
    warn_bg: str
    warn_fg: str
    warn_border: str
    hint_bg: str
    hint_fg: str
    hint_border: str

    # Info button (error dialog "copy" action)
    info_bg: str
    info_hover_bg: str
    info_fg: str

    # Console. Deliberately dark in both modes: it renders script output that
    # already assumes a terminal, and a light console next to coloured shell
    # output looks broken.
    console_bg: str = "#1e1e2e"
    console_fg: str = "#cdd6f4"
    console_border: str = "#45475a"


LIGHT = Palette(
    dark=False,
    accent="#990000",
    accent_hover="#7a0000",
    accent_fg="#ffffff",
    accent_text="#990000",
    window_bg="#fafafa",
    panel_bg="#ffffff",
    card_bg="#ffffff",
    card_border="#d0d5dd",
    card_hover_bg="#fcfcfd",
    card_hover_border="#98a2b3",
    card_disabled_bg="#f8f9fb",
    card_disabled_border="#e4e7ec",
    text="#1f2937",
    text_muted="#667085",
    text_dim="#666666",
    badge_admin="#b42318",
    badge_user="#475467",
    ok_bg="#eaf7ef",
    ok_border="#2e8b57",
    err_bg="#fdf8f8",
    err_border="#c07070",
    tab_bg="#f3f4f6",
    tab_selected_bg="#ffffff",
    tab_text="#374151",
    tab_border="#d0d7e2",
    tab_hover_bg="#eceff3",
    btn_bg="#f9fafb",
    btn_hover_bg="#f3f4f6",
    btn_border="#d1d5db",
    btn_text="#374151",
    btn_disabled_bg="#eceff3",
    btn_disabled_fg="#98a2b3",
    btn_disabled_border="#d8dde6",
    input_bg="#ffffff",
    input_text="#000000",
    input_border="#dddddd",
    selection_bg="#e0e0e0",
    selection_text="#000000",
    warn_bg="#fff3cd",
    warn_fg="#856404",
    warn_border="#ffc107",
    hint_bg="#fff8dc",
    hint_fg="#3d3316",
    hint_border="#d4a017",
    info_bg="#0d6efd",
    info_hover_bg="#0b5ed7",
    info_fg="#ffffff",
)

DARK = Palette(
    dark=True,
    accent="#b81c1c",
    accent_hover="#d13030",
    accent_fg="#ffffff",
    # Brand red lightened until it clears WCAG AA against window_bg. The hue is
    # kept; only lightness moves, so it still reads as DTU red.
    accent_text="#f08c8c",
    window_bg="#1b1d21",
    panel_bg="#24262b",
    card_bg="#2a2d33",
    card_border="#3d4149",
    card_hover_bg="#30343b",
    card_hover_border="#5b616b",
    card_disabled_bg="#212328",
    card_disabled_border="#303339",
    text="#e6e8ec",
    text_muted="#a0a6b0",
    text_dim="#9aa0aa",
    badge_admin="#ff8a80",
    badge_user="#a0a6b0",
    ok_bg="#1e2f26",
    ok_border="#3fa06a",
    err_bg="#332325",
    err_border="#b4595e",
    # Recessed below both the pane and the window, so the selected tab reads as
    # the raised one. At the same value as panel_bg the two were 1.10:1 apart
    # and the tab bar looked flat.
    tab_bg="#202226",
    tab_selected_bg="#2a2d33",
    tab_text="#c8ccd4",
    tab_border="#3d4149",
    tab_hover_bg="#2e3138",
    btn_bg="#2a2d33",
    btn_hover_bg="#33373e",
    btn_border="#454a53",
    btn_text="#d7dbe2",
    btn_disabled_bg="#26282d",
    btn_disabled_fg="#6d727b",
    btn_disabled_border="#33363c",
    input_bg="#2a2d33",
    input_text="#e6e8ec",
    input_border="#454a53",
    selection_bg="#3f4753",
    selection_text="#ffffff",
    warn_bg="#3a2f14",
    warn_fg="#f0d086",
    warn_border="#a1791f",
    hint_bg="#2f2a18",
    hint_fg="#e8d9a8",
    hint_border="#8a6a1c",
    info_bg="#2f6ae0",
    # Darker on hover, not lighter: a lighter blue would drop the white
    # label below 4.5:1. Contrast decides the direction here, not habit.
    info_hover_bg="#2557c4",
    info_fg="#ffffff",
)


_cached: Palette | None = None


def _env_override() -> Palette | None:
    """Honour DTU_SETUP_THEME=dark|light.

    Exists so the palette can be exercised in both modes under offscreen Qt,
    where there is no desktop theme to read. Also gives support staff a way to
    force a mode when a distro reports its palette wrongly.
    """
    choice = os.environ.get("DTU_SETUP_THEME", "").strip().lower()
    if choice == "dark":
        return DARK
    if choice == "light":
        return LIGHT
    return None


def _detect() -> Palette:
    override = _env_override()
    if override is not None:
        return override

    try:
        from PyQt6.QtGui import QPalette
        from PyQt6.QtWidgets import QApplication

        app = QApplication.instance()
        if app is None:
            return LIGHT
        window = app.palette().color(QPalette.ColorRole.Window)
        # Qt's lightness is 0-255. Anything below the midpoint is a dark theme;
        # comparing Window against WindowText instead would misfire on the
        # high-contrast themes where both are extreme.
        return DARK if window.lightness() < 128 else LIGHT
    except Exception:
        # A palette read must never be what stops the tool from opening.
        return LIGHT


def palette() -> Palette:
    """Return the active palette, resolving it on first use."""
    global _cached
    if _cached is None:
        _cached = _detect()
    return _cached


def reset_cache() -> None:
    """Drop the cached palette. For tests that switch modes in one process."""
    global _cached
    _cached = None
