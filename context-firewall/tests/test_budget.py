from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

from support import TempStore, fixture, run, settings

from firewall import assemble, budget, dedup, pipeline, rank
from firewall.models import Artifact, Compressed, ContextItem, Section
from firewall.tokens import estimate


def artifact():
    return Artifact(id="art-0123456789", command="x", cwd="/w", timestamp=0, exit_code=1, type="test", size_bytes=0,
                    stdout_sha="", stderr_sha="", stdout_bytes=0, stderr_bytes=0)


class ToolOutputBudget(unittest.TestCase):
    def test_output_stays_within_the_budget(self):
        for name in ("git_diff", "app_log", "json", "rg", "tree"):
            with TempStore() as store:
                s = settings()
                s.data["budgets"]["toolOutputTokens"] = 400
                out = pipeline.process(fixture(name), s, store)
                with self.subTest(fixture=name):
                    self.assertLessEqual(estimate(out.text), 400 + 120)

    def test_sections_over_budget_are_named_with_their_retrieval_flag(self):
        comp = Compressed("git-diff", "p", "high", headline=["H"], sections=[
            Section("files", ["f"] * 5, priority=5, essential=True),
            Section("file:src/a.ts", ["+x" * 40] * 200, priority=40),
            Section("file:src/b.ts", ["+y" * 40] * 200, priority=41),
        ])
        text, omitted, partial = assemble.render(comp, artifact(), "balanced", 300, 10000, "ddd")
        self.assertIn("--file src/b.ts", text)
        self.assertIn("ddd artifact art-0123456789", text)
        self.assertIn("file:src/b.ts", omitted)
        self.assertEqual(partial, ["file:src/a.ts"])
        self.assertIn("more lines (--file src/a.ts)", text)

    def test_essential_sections_are_kept_even_when_over_budget(self):
        comp = Compressed("test", "p", "high", sections=[Section("failures", [f"failure {i}" for i in range(500)], priority=5, essential=True)])
        text, omitted, partial = assemble.render(comp, artifact(), "balanced", 50, 10000, "ddd")
        self.assertIn("failure 0", text)
        self.assertEqual(omitted, [])
        self.assertIn("--section failures", text)

    def test_priority_decides_what_survives_and_order_is_preserved(self):
        comp = Compressed("x", "p", "high", sections=[
            Section("low", ["low " * 50] * 5, priority=90),
            Section("high", ["high"] * 3, priority=1),
        ])
        text, omitted, partial = assemble.render(comp, artifact(), "balanced", 150, 10000, "ddd")
        self.assertIn("high\nhigh\nhigh", text)
        self.assertEqual(partial, ["low"])
        self.assertLess(text.index("\nlow "), text.index("\nhigh"))
        text, omitted, partial = assemble.render(comp, artifact(), "balanced", 10, 10000, "ddd")
        self.assertIn("high", text)

    def test_nothing_is_lost_when_the_budget_cuts(self):
        with TempStore() as store:
            s = settings()
            s.data["budgets"]["toolOutputTokens"] = 200
            out = pipeline.process(fixture("git_diff"), s, store)
            self.assertEqual(store.stdout(out.artifact), fixture("git_diff").stdout)
            self.assertTrue(out.omitted)

    def test_aggressive_is_smaller_than_balanced(self):
        with TempStore() as store:
            balanced = run(fixture("app_log"), store)
            aggressive = run(fixture("app_log"), store, mode="aggressive")
            self.assertLess(estimate(aggressive.text), estimate(balanced.text))


class Selection(unittest.TestCase):
    def test_highest_score_first_and_duplicates_skipped(self):
        items = [
            ContextItem("a", "t", ["x"], "high", "a" * 400, score=10, key="k1"),
            ContextItem("b", "t", ["x"], "high", "b" * 40, score=50, key="k2"),
            ContextItem("c", "t", ["x"], "high", "c" * 40, score=40, key="k2"),
        ]
        chosen, left = budget.select(items, 50)
        self.assertEqual([i.source for i in chosen], ["b"])
        self.assertEqual({i.source for i in left}, {"a", "c"})
        self.assertIn("duplicate of an included item", next(i for i in left if i.source == "c").reason)


class Ranking(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        git = ["git", "-C", str(self.root)]
        subprocess.run(git + ["init", "-q"], check=True)
        (self.root / "src").mkdir()
        (self.root / "src" / "session.py").write_text(
            "class Session:\n    def refresh(self, token):\n        data = SessionStore.get(token)\n        return TokenProvider.refresh(data)\n", encoding="utf-8")
        (self.root / "src" / "token.py").write_text(
            "class TokenProvider:\n    @staticmethod\n    def refresh(data):\n        return data\n", encoding="utf-8")
        (self.root / "src" / "store.py").write_text("class SessionStore:\n    pass\n", encoding="utf-8")
        (self.root / "src" / "unrelated.py").write_text("def other():\n    return 1\n", encoding="utf-8")
        subprocess.run(git + ["add", "-A"], check=True)
        subprocess.run(git + ["-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "init"], check=True)
        (self.root / "src" / "unrelated.py").write_text("def other():\n    return 2\n", encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_failing_test_outranks_everything_and_reasons_are_given(self):
        with TempStore() as store:
            run(fixture("pytest_fail"), store)
            chosen, left = rank.build(str(self.root), store, settings(), task="fix Session.refresh()")
            self.assertEqual(chosen[0].type, "test-failure")
            self.assertIn("currently failing test", chosen[0].reason)
            text = rank.render(chosen, left, "ddd")
            self.assertIn("because: currently failing test", text)

    def test_requested_symbol_is_exact_source_and_dependencies_are_neighbours_only(self):
        with TempStore() as store:
            chosen, left = rank.build(str(self.root), store, settings(), wanted_symbols=["Session.refresh"])
            by_type = {}
            for item in chosen:
                by_type.setdefault(item.type, []).append(item)
            symbol = by_type["source-symbol"][0]
            self.assertIn("4:         return TokenProvider.refresh(data)", symbol.text)
            deps = {i.source for i in by_type.get("dependency", [])}
            self.assertIn("src/token.py#TokenProvider", deps)
            self.assertIn("src/store.py#SessionStore", deps)
            self.assertFalse(any("unrelated" in d for d in deps))
            self.assertTrue(all("\n" not in i.text for i in by_type["dependency"]))

    def test_changed_and_edited_files_are_candidates_with_reasons(self):
        with TempStore() as store:
            state = dedup.load(store, "s1")
            dedup.touch_file(state, str(self.root / "src" / "session.py"))
            dedup.save(store, "s1", state)
            chosen, _ = rank.build(str(self.root), store, settings(), session="s1")
            reasons = {i.source: i.reason for i in chosen}
            self.assertIn("modified in the working tree", reasons["src/unrelated.py"])
            self.assertIn("edited in this session", reasons["src/session.py"])

    def test_budget_limits_the_pack(self):
        with TempStore() as store:
            run(fixture("pytest_fail"), store)
            chosen, left = rank.build(str(self.root), store, settings(), wanted_symbols=["Session.refresh"], budget_tokens=60)
            self.assertLessEqual(sum(i.tokens for i in chosen), 60)
            self.assertTrue(left)

    def test_scores_are_the_documented_weights(self):
        self.assertEqual(rank.score(["currently failing test", "edited in this session"]), 80)
        self.assertEqual(rank.score(["recent command result", "stale (older than 30 min)"]), -5)


if __name__ == "__main__":
    unittest.main()
