"""Queue logic for the two "Run All" buttons.

Split out of the window for one concrete reason: the queue used to live in
attributes created lazily by `_run_all_admin`, so every reader had to guard with
`hasattr(self, "_queued_modules")` before touching it. That guard was the bug
surface — forget it once and Run All raises AttributeError on a fresh window.
A queue object that always exists removes the question.

Everything here is free of Qt so the batch rules can be tested without a
display.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .modules import ModuleDef

# Modules kept out of "Run All Admin Modules".
#
# qdrive/followme/wifi need the end user's own domain credentials, which the
# admin doing the install does not have — they run from the first-login dialog
# instead. tpm2-enroll is excluded for a different reason: it changes how the
# disk unlocks at boot, so it must be a deliberate click, never a side effect
# of a bulk run.
DEFERRED_MODULE_IDS = frozenset({"qdrive", "followme", "wifi", "tpm2-enroll"})

DEFERRED_INFO_MESSAGE = (
    "The following modules will be skipped and run automatically\n"
    "when the domain user logs in for the first time:\n\n"
    "  • Q-Drive / O-Drive\n"
    "  • FollowMe Printers\n"
    "  • DTUSecure WiFi\n\n"
    "Optional security modules skipped in Run All:\n\n"
    "  • TPM2 Auto-Unlock (run manually if needed)\n\n"
    "Make sure 'First-Login Setup' is included in the run."
)


def admin_batch_modules(modules: list[ModuleDef]) -> list[ModuleDef]:
    """Admin modules that a bulk run should actually execute."""
    return [
        m
        for m in modules
        if m.enabled and m.script_type == "admin" and m.id not in DEFERRED_MODULE_IDS
    ]


def user_batch_modules(modules: list[ModuleDef]) -> list[ModuleDef]:
    """User scripts that a bulk run should execute."""
    return [m for m in modules if m.enabled and m.script_type == "user"]


def batch_input_type(modules: list[ModuleDef]) -> str:
    """The strongest input a batch needs: credentials > username > none.

    Credentials win because a password also yields the username, so asking for
    both separately would prompt the same person twice.
    """
    if any(m.input_type == "credentials" for m in modules):
        return "credentials"
    if any(m.input_type == "username" for m in modules):
        return "username"
    return "none"


@dataclass
class BatchQueue:
    """Pending modules plus the environment they share.

    `is_admin_run` and `cancelled` together decide whether the reboot prompt
    appears at the end: it should follow a completed admin batch, but not a
    cancelled one and not a user-script run.
    """

    pending: list[ModuleDef] = field(default_factory=list)
    shared_env: dict[str, str] = field(default_factory=dict)
    is_admin_run: bool = False
    cancelled: bool = False
    # Sandt fra kørslen starter til den er gjort færdig eller afbrudt.
    #
    # has_pending() kan ikke svare på det: den er falsk allerede mens det
    # SIDSTE modul kører. Vinduet brugte den til at afgøre om køen skulle
    # føres videre, så afslutningen af en samlet kørsel — beskeden og
    # genstart-spørgsmålet — blev aldrig nået.
    in_progress: bool = False

    def start(
        self,
        modules: list[ModuleDef],
        shared_env: dict[str, str],
        *,
        is_admin_run: bool,
    ) -> None:
        self.pending = list(modules)
        self.shared_env = dict(shared_env)
        self.is_admin_run = is_admin_run
        self.cancelled = False
        self.in_progress = True

    def has_pending(self) -> bool:
        return bool(self.pending)

    def pop_next(self) -> ModuleDef | None:
        return self.pending.pop(0) if self.pending else None

    def cancel(self) -> None:
        """Empty the queue, remembering that it ended early."""
        if self.is_admin_run:
            self.cancelled = True
        self.pending.clear()
        self.in_progress = False

    def should_prompt_reboot(self) -> bool:
        return self.is_admin_run and not self.cancelled

    def push_front(self, mod: ModuleDef) -> None:
        """Læg et modul forrest igen, så det køres om.

        Bruges når brugeren vælger "Prøv igen" på en fejl midt i en kørsel.
        """
        self.pending.insert(0, mod)

    def reset(self) -> None:
        self.pending.clear()
        self.shared_env = {}
        self.is_admin_run = False
        self.cancelled = False
        self.in_progress = False
