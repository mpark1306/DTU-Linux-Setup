"""Tests for the Run All queue rules.

These cover the two behaviours that are easy to get wrong and expensive when
wrong: which modules a bulk run is allowed to touch, and whether the reboot
prompt appears after it.
"""

from __future__ import annotations

import unittest

from dtu_sustain_setup.batch import (
    DEFERRED_MODULE_IDS,
    BatchQueue,
    admin_batch_modules,
    batch_input_type,
    user_batch_modules,
)
from dtu_sustain_setup.modules import MODULES, ModuleDef


def _mod(mod_id: str, **kw) -> ModuleDef:
    base = dict(
        id=mod_id,
        title=mod_id,
        description="",
        script_name=f"{mod_id}.sh",
        needs_root=True,
        input_type="none",
        icon_name="",
    )
    base.update(kw)
    return ModuleDef(**base)


class TestBatchSelection(unittest.TestCase):
    def test_admin_batch_excludes_deferred_modules(self) -> None:
        picked = {m.id for m in admin_batch_modules(MODULES)}
        self.assertFalse(picked & DEFERRED_MODULE_IDS)

    def test_tpm2_never_runs_in_a_bulk_run(self) -> None:
        """Enrolling TPM2 changes how the disk unlocks — never as a side effect."""
        self.assertNotIn("tpm2-enroll", {m.id for m in admin_batch_modules(MODULES)})
        self.assertNotIn("tpm2-enroll", {m.id for m in user_batch_modules(MODULES)})

    def test_admin_batch_includes_first_login_deploy(self) -> None:
        """The deferred modules only ever run if this one was installed."""
        self.assertIn(
            "first-login-deploy", {m.id for m in admin_batch_modules(MODULES)}
        )

    def test_disabled_modules_are_never_queued(self) -> None:
        mods = [_mod("on"), _mod("off", enabled=False)]
        self.assertEqual([m.id for m in admin_batch_modules(mods)], ["on"])

    def test_reset_test_user_stays_out_of_bulk_runs(self) -> None:
        """It deletes a home directory; it is disabled and must remain so."""
        target = next(m for m in MODULES if m.id == "reset-test-user")
        self.assertFalse(target.enabled)
        self.assertNotIn("reset-test-user", {m.id for m in user_batch_modules(MODULES)})

    def test_admin_and_user_batches_do_not_overlap(self) -> None:
        admin = {m.id for m in admin_batch_modules(MODULES)}
        user = {m.id for m in user_batch_modules(MODULES)}
        self.assertFalse(admin & user)

    def test_every_module_lands_in_exactly_one_tab(self) -> None:
        for m in MODULES:
            self.assertIn(m.script_type, ("admin", "user"), m.id)

    def test_module_ids_are_unique(self) -> None:
        ids = [m.id for m in MODULES]
        self.assertEqual(len(ids), len(set(ids)))


class TestBatchInputType(unittest.TestCase):
    def test_credentials_win_over_username(self) -> None:
        """A password implies the username, so asking for both prompts twice."""
        mods = [_mod("a", input_type="username"), _mod("b", input_type="credentials")]
        self.assertEqual(batch_input_type(mods), "credentials")

    def test_username_only(self) -> None:
        self.assertEqual(batch_input_type([_mod("a", input_type="username")]), "username")

    def test_nothing_needed(self) -> None:
        self.assertEqual(batch_input_type([_mod("a")]), "none")

    def test_empty_batch(self) -> None:
        self.assertEqual(batch_input_type([]), "none")


class TestBatchQueue(unittest.TestCase):
    def test_fresh_queue_is_usable_without_start(self) -> None:
        """The old code kept this state in lazily created attributes, so a
        reader that forgot its hasattr() guard raised AttributeError."""
        q = BatchQueue()
        self.assertFalse(q.has_pending())
        self.assertIsNone(q.pop_next())
        self.assertFalse(q.should_prompt_reboot())
        q.cancel()  # must not raise

    def test_modules_run_in_order(self) -> None:
        q = BatchQueue()
        q.start([_mod("a"), _mod("b"), _mod("c")], {}, is_admin_run=True)
        self.assertEqual(
            [q.pop_next().id, q.pop_next().id, q.pop_next().id], ["a", "b", "c"]
        )
        self.assertIsNone(q.pop_next())

    def test_completed_admin_run_prompts_reboot(self) -> None:
        q = BatchQueue()
        q.start([_mod("a")], {}, is_admin_run=True)
        q.pop_next()
        self.assertTrue(q.should_prompt_reboot())

    def test_cancelled_admin_run_does_not_prompt_reboot(self) -> None:
        q = BatchQueue()
        q.start([_mod("a"), _mod("b")], {}, is_admin_run=True)
        q.cancel()
        self.assertFalse(q.has_pending())
        self.assertFalse(q.should_prompt_reboot())

    def test_user_run_never_prompts_reboot(self) -> None:
        q = BatchQueue()
        q.start([_mod("a")], {}, is_admin_run=False)
        q.pop_next()
        self.assertFalse(q.should_prompt_reboot())

    def test_reset_clears_the_cancelled_flag(self) -> None:
        """Otherwise a cancelled run would suppress the next run's prompt."""
        q = BatchQueue()
        q.start([_mod("a")], {}, is_admin_run=True)
        q.cancel()
        q.reset()
        q.start([_mod("b")], {}, is_admin_run=True)
        q.pop_next()
        self.assertTrue(q.should_prompt_reboot())

    def test_shared_env_is_copied_not_aliased(self) -> None:
        """A password in the caller's dict must not be mutated from under it."""
        source = {"DTU_PASSWORD": "secret"}
        q = BatchQueue()
        q.start([_mod("a")], source, is_admin_run=False)
        q.shared_env["DTU_PASSWORD"] = "changed"
        self.assertEqual(source["DTU_PASSWORD"], "secret")

    def test_module_list_is_copied_not_aliased(self) -> None:
        mods = [_mod("a"), _mod("b")]
        q = BatchQueue()
        q.start(mods, {}, is_admin_run=False)
        q.pop_next()
        self.assertEqual(len(mods), 2, "start() must not drain the caller's list")

    def test_reset_drops_the_shared_environment(self) -> None:
        """It holds a domain password; it should not outlive the run."""
        q = BatchQueue()
        q.start([_mod("a")], {"DTU_PASSWORD": "secret"}, is_admin_run=True)
        q.reset()
        self.assertEqual(q.shared_env, {})


if __name__ == "__main__":
    unittest.main()
