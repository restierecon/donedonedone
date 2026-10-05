from __future__ import annotations

import unittest

from support import TempStore, fixture, render, run

from firewall import retrieval
from firewall.adapters import git
from firewall.adapters.common import lines_of


class GitStatus(unittest.TestCase):
    def test_long_format_keeps_branch_paths_states_and_renames(self):
        text, _ = render("git_status")
        for expected in ("Branch: On branch main", "Staged (6):", "- renamed: src/helpers_old.ts -> src/helpers.ts",
                         "- new file: src/auth/token.ts", "Modified (not staged) (1):", "Untracked (46):", "- notes.txt"):
            self.assertIn(expected, text)

    def test_many_untracked_files_in_one_folder_collapse_to_a_count(self):
        text, _ = render("git_status")
        self.assertIn("- src/api/ (45 entries: gen_1.ts, gen_10.ts, gen_11.ts, ...; --section untracked)", text)

    def test_conflicts_are_listed_first_and_never_dropped(self):
        text, _ = render("git_status_conflict")
        self.assertIn("Conflicts (1):\n- both modified: src/auth/token.ts", text)
        self.assertLess(text.index("Conflicts"), text.index("Untracked"))
        self.assertIn("You have unmerged paths.", text)

    def test_porcelain_format(self):
        comp = git.status(fixture("git_status_porcelain").stdout, {"mode": "balanced", "maxLineChars": 300})
        rows = [line for s in comp.sections for line in s.lines]
        self.assertTrue(any("main" in h for h in comp.headline))
        self.assertIn("- renamed: src/helpers_old.ts -> src/helpers.ts", rows)
        self.assertIn("- modified: src/auth/token.ts", rows)

    def test_clean_tree(self):
        comp = git.status("On branch main\nnothing to commit, working tree clean\n", {"mode": "balanced", "maxLineChars": 300})
        self.assertEqual(comp.status, "clean")
        self.assertIn("nothing to commit, working tree clean", comp.headline)


class GitDiff(unittest.TestCase):
    def test_summary_counts_files_insertions_and_deletions(self):
        text, _ = render("git_diff")
        self.assertIn("Files changed: 6  Insertions: +766  Deletions: -4", text)
        self.assertIn("R src/helpers_old.ts -> src/helpers.ts  +0 -0  (similarity 100%)", text)
        self.assertIn("B logo.png  (binary)", text)
        self.assertIn("A src/auth/token.ts  +1 -0", text)

    def test_changed_code_is_kept_and_symbols_detected(self):
        text, _ = render("git_diff")
        self.assertIn("+        return TokenProvider.refresh(data)", text)
        self.assertIn("-        return data", text)
        self.assertIn("+def rotate(session, provider):", text)
        self.assertIn("M src/auth/session.py  +7 -1  [Session, rotate]", text)

    def test_lockfile_hunks_are_hidden_but_listed(self):
        text, _ = render("git_diff")
        self.assertIn("Hunks hidden for 1 lock/generated file(s): package-lock.json", text)
        self.assertNotIn("registry.npmjs.org", text)

    def test_file_retrieval_returns_the_exact_raw_block(self):
        raw = fixture("git_diff").stdout
        block = git.retrieve_file(raw, "src/auth/session.py")
        self.assertEqual(block[0], "diff --git a/src/auth/session.py b/src/auth/session.py")
        self.assertIn("+            raise KeyError(token)", block)
        self.assertTrue("\n".join(block) in raw)
        self.assertFalse(any(line.startswith("diff --git a/src/auth/token.ts") for line in block))

    def test_file_blocks_cover_the_whole_diff_without_overlap(self):
        lines = lines_of(fixture("git_diff").stdout)
        files = git.parse_diff(lines)
        for before, after in zip(files, files[1:]):
            self.assertLessEqual(before.end, after.start - 1)
        self.assertEqual(sum(f.added for f in files), 766)

    def test_active_file_hunks_are_ranked_first_under_a_tight_budget(self):
        with TempStore() as store:
            from support import settings
            from firewall import dedup, pipeline
            state = dedup.load(store, "t")
            dedup.touch_file(state, "/work/src/auth/token.ts")
            dedup.save(store, "t", state)
            s = settings()
            s.data["budgets"]["toolOutputTokens"] = 260
            out = pipeline.process(fixture("git_diff"), s, store, session="t")
            self.assertIn("--- src/auth/token.ts", out.text)

    def test_retrieval_of_a_section_name_that_is_a_file(self):
        with TempStore() as store:
            out = run(fixture("git_diff"), store)
            from support import settings
            lines = retrieval.get_section(store, out.artifact.id, "src/api/routes.ts", settings())
            self.assertIn("+line 6 changed", lines)


class GitLog(unittest.TestCase):
    def test_long_log_becomes_one_line_per_commit(self):
        text, _ = render("git_log")
        self.assertIn("GIT LOG  commits: 72", text)
        self.assertIn("T | chore: step 70 of the long history", text)
        self.assertNotIn("step 9 of", text)
        self.assertIn("... 12 more commits (--section commits)", text)

    def test_oneline_log(self):
        comp = git.log("a1b2c3d feat: one\nb2c3d4e fix: two\n", {"mode": "balanced", "maxLineChars": 300})
        self.assertEqual(comp.parser, "git-log:oneline")


if __name__ == "__main__":
    unittest.main()
