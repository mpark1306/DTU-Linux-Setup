"""Hvad der sker med køen når et modul fejler midt i "Run All".

Kørslen crashede appen i stedet for at melde fejl. To ting lå bag:

  Fejldialogen blev åbnet inde i QProcess::finished, og det næste modul blev
  startet fra samme signal — en indlejret event-loop oven på et signal der
  stadig var under udsendelse, mens runneren udskiftede sit QProcess.

  Der var ingen sys.excepthook. Rejser en slot en undtagelse, kalder PyQt6
  abort(): vinduet forsvinder uden besked, og traceback'en går til stderr
  som ingen ser, når programmet er startet fra menuen.

Her drives fejlstien uden at starte rigtige processer: ErrorDialog erstattes
af en stub der svarer med et valg, og køen kontrolleres bagefter.
"""

from __future__ import annotations

import os
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

try:
    from PyQt6.QtWidgets import QApplication

    _QT_ERROR = None
except Exception as exc:  # pragma: no cover
    _QT_ERROR = str(exc)

_APP = None


class _StubDialog:
    """Svarer som en bruger der trykkede på én bestemt knap."""

    answer = "skip"
    seen: list[dict] = []

    def __init__(self, *args, **kwargs):
        self.choice = type(self).answer
        type(self).seen.append(kwargs)

    def exec(self):
        return 1


@unittest.skipIf(_QT_ERROR, f"PyQt6 unavailable: {_QT_ERROR}")
class TestFailureFlow(unittest.TestCase):
    def setUp(self):
        global _APP
        if _APP is None:
            _APP = QApplication.instance() or QApplication([])

        from dtu_sustain_setup import main_window as mw

        self.mw = mw
        self.window = mw.MainWindow()
        self._real_dialog = mw.ErrorDialog
        mw.ErrorDialog = _StubDialog
        _StubDialog.seen = []
        # Ingen rigtige processer: kørslen af det næste modul stubbes væk.
        self.ran: list[str] = []
        self.window._runner.run = lambda script, mod_id, **kw: self.ran.append(mod_id)

    def tearDown(self):
        # Udskudte kald skal fyres af MENS stubben stadig er på plads.
        #
        # _on_module_finished lægger sit arbejde i en QTimer.singleShot. Den
        # fyrer ikke her, hvor der ikke køres en event-loop — den fyrer i en
        # senere test, der kalder processEvents(). Var stubben da skiftet
        # tilbage, ville en RIGTIG modal fejldialog åbne og blokere hele
        # suiten. Det skete, og det var derfor smoke-testen hang.
        self.window._pending_failure = None
        self.window._batch.reset()
        QApplication.processEvents()
        self.mw.ErrorDialog = self._real_dialog
        self.window.close()
        self.window.deleteLater()
        QApplication.processEvents()

    def _queue(self, count=3):
        from dtu_sustain_setup.batch import admin_batch_modules
        from dtu_sustain_setup.modules import MODULES

        mods = admin_batch_modules(MODULES)[:count]
        self.assertGreaterEqual(len(mods), 2, "for få moduler til at teste en kø")
        self.window._batch.start(mods, {}, is_admin_run=True)
        return mods

    def test_retry_puts_the_module_back_at_the_front(self):
        mods = self._queue()
        failing = mods[0]
        self.window._current_module = failing
        _StubDialog.answer = "retry"
        self.window._on_module_failed(failing.id, 1, "boom")
        self.window._after_module(False, failing.id)
        self.assertIs(self.window._batch.pending[0], failing)

    def test_skip_moves_on_and_keeps_the_run_alive(self):
        mods = self._queue()
        failing = mods[0]
        self.window._current_module = failing
        remaining = list(self.window._batch.pending)
        _StubDialog.answer = "skip"
        self.window._on_module_failed(failing.id, 1, "boom")
        self.window._after_module(False, failing.id)
        self.assertNotIn(failing, self.window._batch.pending)
        self.assertTrue(self.window._batch.in_progress or not remaining)

    def test_abort_empties_the_queue(self):
        mods = self._queue()
        failing = mods[0]
        self.window._current_module = failing
        _StubDialog.answer = "abort"
        self.window._on_module_failed(failing.id, 1, "boom")
        self.window._after_module(False, failing.id)
        self.assertFalse(self.window._batch.has_pending())
        self.assertFalse(self.window._batch.in_progress)

    def test_the_dialog_is_told_it_is_a_batch(self):
        """Uden det får brugeren kun "Luk", og kørslen fortsætter bag om dem."""
        mods = self._queue()
        self.window._current_module = mods[0]
        _StubDialog.answer = "skip"
        self.window._on_module_failed(mods[0].id, 1, "boom")
        self.window._after_module(False, mods[0].id)
        self.assertTrue(_StubDialog.seen)
        self.assertIs(_StubDialog.seen[0].get("batch_mode"), True)

    def test_failure_outside_a_batch_is_not_offered_retry(self):
        self.window._batch.reset()
        _StubDialog.answer = "close"
        self.window._on_module_failed("defender", 1, "boom")
        self.window._after_module(False, "defender")
        self.assertIs(_StubDialog.seen[0].get("batch_mode"), False)

    def test_finished_does_not_open_the_dialog_from_the_signal(self):
        """_on_module_finished må ikke selv vise noget — den lægger arbejdet
        i næste tur gennem event-loopet."""
        mods = self._queue()
        self.window._current_module = mods[0]
        self.window._on_module_failed(mods[0].id, 1, "boom")
        self.window._on_module_finished(False, mods[0].id)
        self.assertEqual(_StubDialog.seen, [], "dialogen blev åbnet inde i signalet")


@unittest.skipIf(_QT_ERROR, f"PyQt6 unavailable: {_QT_ERROR}")
class TestExceptHook(unittest.TestCase):
    def test_entrypoint_installs_one(self):
        """Uden den kalder PyQt6 abort() på en ufanget undtagelse i en slot,
        og appen forsvinder uden et vindue eller en besked."""
        import sys

        from dtu_sustain_setup.__main__ import _install_excepthook

        original = sys.excepthook
        try:
            _install_excepthook()
            self.assertIsNot(sys.excepthook, original)
            self.assertIsNot(sys.excepthook, sys.__excepthook__)
        finally:
            sys.excepthook = original


if __name__ == "__main__":
    unittest.main()
