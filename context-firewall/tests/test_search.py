from __future__ import annotations

import unittest

from support import fixture, render

from firewall.adapters import search
from firewall.adapters.common import lines_of
from firewall.classify import classify


class Search(unittest.TestCase):
    def test_counts_match_the_raw_lines(self):
        raw = fixture("rg").stdout
        total = len([line for line in raw.split("\n") if line.strip()])
        files = len({line.split(":", 1)[0] for line in raw.split("\n") if line.strip()})
        text, _ = render("rg")
        self.assertIn(f"Matches: {total}  Files: {files}", text)
        self.assertIn("Query: gate", text)

    def test_groups_by_file_with_line_numbers(self):
        text, _ = render("rg")
        self.assertIn("scripts/gate.sh (6): 5, 12, 17, 63, 66, 78", text)
        self.assertIn("... 3 more in this file (--file scripts/gate.sh)", text)

    def test_heading_style(self):
        text, _ = render("rg_heading")
        self.assertIn("search:heading", text)
        self.assertIn("agents/auditor.md (9): 3, 13, 14, 15, 18, 39, 50, 53, 60", text)

    def test_grep_recursive_style(self):
        text, _ = render("grep")
        self.assertIn("SEARCH", text)
        self.assertIn("CLAUDE.md (", text)

    def test_file_retrieval_returns_only_that_files_raw_lines(self):
        raw = fixture("rg").stdout
        got = search.retrieve_file(raw, "scripts/gate.sh")
        self.assertEqual(len(got), 6)
        self.assertTrue(all(line.startswith("scripts/gate.sh:") for line in got))

    def test_files_only_output(self):
        files, order, style = search.parse(lines_of("src/a.ts\nsrc/b.ts\nlib/c.py\n"))
        self.assertEqual(style, "files")
        self.assertEqual(order, ["src/a.ts", "src/b.ts", "lib/c.py"])

    def test_windows_paths(self):
        files, order, style = search.parse(lines_of("C:\\work\\src\\a.ts:12:const x = AuthService\nC:\\work\\src\\a.ts:40:new AuthService()\n"))
        self.assertEqual(order, ["C:\\work\\src\\a.ts"])
        self.assertEqual([h[1] for h in files["C:\\work\\src\\a.ts"]], [12, 40])

    def test_query_extraction_skips_option_values(self):
        self.assertEqual(search.query_of(["rg", "-n", "-g", "*.ts", "-C", "2", "AuthService", "src"]), "AuthService")
        self.assertEqual(search.query_of(["grep", "-rn", "-e", "foo bar", "."]), "foo bar")
        self.assertEqual(search.query_of(["git", "grep", "-n", "Session"]), "Session")

    def test_classification(self):
        for command in ("rg -n foo", "grep -rn foo .", "git grep foo", "Select-String -Pattern foo *.ps1"):
            from firewall.models import CommandResult
            self.assertEqual(classify(CommandResult(command=command, cwd=".")).type, "search", command)


if __name__ == "__main__":
    unittest.main()
