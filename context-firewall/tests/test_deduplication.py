from __future__ import annotations

import time
import unittest

from support import TempStore, fixture, run

from firewall import dedup
from firewall.adapters.common import collapse
from firewall.models import CommandResult


class InOutputDeduplication(unittest.TestCase):
    def test_consecutive_identical_lines_collapse_with_a_count(self):
        self.assertEqual(collapse(["a", "a", "a", "b"]), ["a  [x3]", "b"])

    def test_repeated_blocks_collapse(self):
        block = ["start", "  at frame", "end"]
        self.assertEqual(collapse(block * 4 + ["tail"]), ["start  [x4]", "  at frame", "end", "tail"])

    def test_two_repeats_of_a_block_are_kept(self):
        self.assertEqual(collapse(["x", "y", "x", "y"]), ["x", "y", "x", "y"])

    def test_non_repeating_input_is_unchanged(self):
        lines = [f"line {i}" for i in range(50)]
        self.assertEqual(collapse(lines), lines)


class AcrossCalls(unittest.TestCase):
    def test_identical_rerun_sends_a_pointer_instead_of_the_output(self):
        with TempStore() as store:
            first = run(fixture("pytest_fail"), store, dedup=True)
            second = run(fixture("pytest_fail"), store, dedup=True)
            self.assertIn("NO NEW INFORMATION", second.text)
            self.assertIn(f"identical to the output of {first.artifact.id}", second.text)
            self.assertEqual(second.artifact.metadata["duplicateOf"], first.artifact.id)
            self.assertLess(len(second.text), 400)
            self.assertEqual(store.text(second.artifact), store.text(first.artifact))

    def test_rerun_that_differs_only_in_timings_is_recognised(self):
        with TempStore() as store:
            result = fixture("go_test")
            run(result, store, dedup=True)
            changed = CommandResult(command=result.command, cwd=result.cwd, stdout=result.stdout.replace("0.003s", "0.021s"), exit_code=result.exit_code)
            second = run(changed, store, dedup=True)
            self.assertIn("only timings/timestamps/ids differ", second.text)

    def test_real_change_is_not_suppressed(self):
        with TempStore() as store:
            result = fixture("go_test")
            run(result, store, dedup=True)
            changed = CommandResult(command=result.command, cwd=result.cwd, stdout=result.stdout.replace('want "abc-refreshed"', 'want "abc-renewed"'), exit_code=1)
            self.assertNotIn("NO NEW INFORMATION", run(changed, store, dedup=True).text)

    def test_different_exit_code_is_new_information(self):
        with TempStore() as store:
            result = fixture("git_diff")
            run(result, store, dedup=True)
            other = CommandResult(command=result.command, cwd=result.cwd, stdout=result.stdout, exit_code=1)
            self.assertNotIn("NO NEW INFORMATION", run(other, store, dedup=True).text)

    def test_strict_mode_never_suppresses(self):
        with TempStore() as store:
            run(fixture("pytest_fail"), store, mode="strict", dedup=True)
            self.assertNotIn("NO NEW INFORMATION", run(fixture("pytest_fail"), store, mode="strict", dedup=True).text)

    def test_sessions_are_independent(self):
        with TempStore() as store:
            run(fixture("pytest_fail"), store, dedup=True, session="a")
            self.assertNotIn("NO NEW INFORMATION", run(fixture("pytest_fail"), store, dedup=True, session="b").text)

    def test_window_expiry(self):
        state = {"delivered": [], "active_files": {}}
        dedup.remember(state, "art-1", "e", "n", now=1000)
        self.assertIsNotNone(dedup.check(state, "e", "n", 60, now=1030))
        self.assertIsNone(dedup.check(state, "e", "n", 60, now=1100))

    def test_small_outputs_are_remembered_too(self):
        with TempStore() as store:
            small = CommandResult(command="git status", cwd="/w", stdout="On branch main\nnothing to commit, working tree clean\n", exit_code=0)
            first = run(small, store, passthrough=None, dedup=True)
            self.assertIsNone(first.text)
            state = dedup.load(store, "t")
            self.assertEqual(state["delivered"][-1]["id"], first.artifact.id)

    def test_state_is_bounded(self):
        state = {"delivered": [], "active_files": {}}
        for i in range(500):
            dedup.remember(state, f"art-{i}", str(i), str(i), now=time.time())
            dedup.touch_file(state, f"f{i}.py", now=i)
        with TempStore() as store:
            dedup.save(store, "s", state)
            loaded = dedup.load(store, "s")
        self.assertEqual(len(loaded["delivered"]), dedup.MAX_DELIVERED)
        self.assertEqual(len(loaded["active_files"]), dedup.MAX_ACTIVE)
        self.assertIn("f499.py", loaded["active_files"])


if __name__ == "__main__":
    unittest.main()
