"""Entry point for DTU Linux Setup."""

import sys
import traceback

from PyQt6.QtWidgets import QApplication, QMessageBox

from .main_window import MainWindow


def _install_excepthook() -> None:
    """Vis ufangede undtagelser frem for at lade processen dø.

    PyQt6 kalder abort() når en slot rejser en undtagelse den ikke selv
    fanger. Appen forsvinder da uden vindue, uden besked og uden at nogen
    kan se hvad der skete — traceback'en går til stderr, som ingen ser når
    programmet er startet fra menuen. Det er sådan "Run All Admin Modules"
    kunne se ud som et crash.

    En hook her ændrer ikke at fejlen findes, men den gør den synlig og
    lader vinduet blive stående, så en igangværende kørsel kan fortsættes
    eller rapporteres i stedet for at være væk.
    """

    def hook(exc_type, exc_value, exc_tb):
        text = "".join(traceback.format_exception(exc_type, exc_value, exc_tb))
        print(text, file=sys.stderr, flush=True)
        if QApplication.instance() is None:
            return
        box = QMessageBox()
        box.setIcon(QMessageBox.Icon.Critical)
        box.setWindowTitle("Uventet fejl")
        box.setText(
            "Der opstod en uventet fejl i programmet.\n\n"
            "Vinduet er stadig åbent. Kopiér detaljerne nedenfor med, hvis "
            "du melder fejlen."
        )
        box.setInformativeText(f"{exc_type.__name__}: {exc_value}")
        box.setDetailedText(text)
        box.exec()

    sys.excepthook = hook


def main() -> None:
    app = QApplication(sys.argv)
    app.setApplicationName("DTU Linux Setup")
    app.setOrganizationName("DTU Sustain")
    app.setDesktopFileName("dtu-sustain-setup")

    _install_excepthook()

    window = MainWindow()
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
