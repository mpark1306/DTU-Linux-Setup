"""Entry point for DTU Sustain Setup."""

import sys

from PyQt6.QtWidgets import QApplication

from .main_window import MainWindow


def main() -> None:
    app = QApplication(sys.argv)
    app.setApplicationName("DTU Sustain Setup")
    app.setOrganizationName("DTU Sustain")
    app.setDesktopFileName("dtu-sustain-setup")

    window = MainWindow()
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
