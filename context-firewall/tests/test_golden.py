from __future__ import annotations

import os
import re
import unittest

from support import FIXTURES, GOLDEN, fixture, names, render

from firewall import adapters
from firewall.adapters.common import clean, strip_markers
from firewall.classify import classify
from firewall.store import combined_text
from firewall.tokens import estimate

UPDATE = os.environ.get("UPDATE_GOLDEN") == "1"
LOCATION = re.compile(r"((?:[A-Za-z]:)?[\w./\\-]+\.[A-Za-z]{1,6}):(\d+)")
NOTE = re.compile(r"^\s*\.\.\. |^\s*same at: |^\s*same error again: |^\s*\(raw L|^ \.\.\. \(\d+ unchanged lines\)$")


class GoldenOutput(unittest.TestCase):
    def test_every_fixture_matches_its_golden_file(self):
        GOLDEN.mkdir(exist_ok=True)
        for name in names():
            with self.subTest(fixture=name):
                text, _ = render(name)
                path = GOLDEN / f"{name}.txt"
                if UPDATE or not path.exists():
                    path.write_text(text + "\n", encoding="utf-8", newline="\n")
                self.assertEqual(path.read_text(encoding="utf-8"), text + "\n")

    def test_compression_is_deterministic(self):
        for name in names():
            with self.subTest(fixture=name):
                self.assertEqual(render(name)[0], render(name)[0])

    def test_every_golden_file_has_a_fixture(self):
        for path in GOLDEN.glob("*.txt"):
            self.assertTrue((FIXTURES / f"{path.stem}.cmd").exists(), path.name)


class NeverFabricates(unittest.TestCase):
    def _compressed(self, name, mode="balanced"):
        result = fixture(name)
        raw = combined_text(result.stdout, result.stderr)
        cls = classify(result)
        ctx = {"mode": mode, "maxLineChars": 300, "budget": 5000, "exit_code": result.exit_code, "argv": cls.argv, "tool": "Bash", "active_files": []}
        return raw, adapters.compress(cls.type, raw, ctx)

    def test_verbatim_sections_only_contain_lines_from_the_raw_output(self):
        for name in names():
            raw, comp = self._compressed(name)
            haystack = clean(raw).replace("\r", "")
            for section in comp.sections:
                if not section.verbatim:
                    continue
                for line in section.lines:
                    if NOTE.search(line):
                        continue
                    with self.subTest(fixture=name, section=section.name, line=line):
                        self.assertIn(strip_markers(line).strip(), haystack)

    def test_every_file_location_shown_appears_in_the_raw_output(self):
        for name in names():
            raw, comp = self._compressed(name)
            haystack = clean(raw).replace("\\", "/")
            shown = "\n".join(comp.headline + [line for s in comp.sections for line in s.lines])
            for path, line_no in LOCATION.findall(shown):
                if path.startswith("raw"):
                    continue
                with self.subTest(fixture=name, location=f"{path}:{line_no}"):
                    norm = path.replace("\\", "/")
                    self.assertIn(norm, haystack)
                    self.assertIn(line_no, haystack)

    def test_reported_counts_come_from_the_runner_summary(self):
        expected = {
            "pytest_fail": "Passed: 60  Failed: 3  Skipped: 1",
            "jest": "Passed: 1244  Failed: 2  Skipped: 12  Total: 1258",
            "vitest": "Passed: 45  Failed: 1",
            "go_test": "Passed: 31  Failed: 2  Skipped: 0",
            "cargo_test": "Passed: 1  Failed: 2  Skipped: 0",
            "mocha": "Passed: 31  Failed: 2  Skipped: 1",
            "node_tap": "Passed: 25  Failed: 2",
            "node_spec": "Passed: 25  Failed: 2",
            "dotnet_test": "Passed: 211  Failed: 1  Skipped: 3  Total: 215",
            "pester": "Passed: 32  Failed: 1  Skipped: 1",
            "maven_test": "Passed: 15  Failed: 1  Errors: 0  Skipped: 1  Total: 17",
        }
        for name, counts in expected.items():
            with self.subTest(fixture=name):
                self.assertIn(counts, render(name)[0])


class Modes(unittest.TestCase):
    def test_strict_keeps_at_least_as_much_as_balanced_and_balanced_as_aggressive(self):
        for name in names():
            sizes = {}
            for mode in ("strict", "balanced", "aggressive"):
                text, outcome = render(name, mode)
                sizes[mode] = estimate(outcome.text) if outcome.text else estimate(combined_text(fixture(name).stdout, fixture(name).stderr))
            with self.subTest(fixture=name, sizes=sizes):
                self.assertGreaterEqual(sizes["strict"] + 5, sizes["balanced"])
                self.assertGreaterEqual(sizes["balanced"] + 5, sizes["aggressive"])

    def test_non_default_modes_are_announced_in_the_header(self):
        for mode in ("strict", "aggressive"):
            text, _ = render("pytest_fail", mode)
            self.assertIn(f"mode {mode}", text.split("\n")[0])
        self.assertNotIn("mode ", render("pytest_fail", "balanced")[0].split("\n")[0])

    def test_every_mode_keeps_every_failing_test_name(self):
        for mode in ("strict", "balanced", "aggressive"):
            text, _ = render("pytest_fail", mode)
            for test in ("test_session_refresh", "test_token_provider", "test_crash"):
                self.assertIn(test, text, mode)

    def test_strict_keeps_full_diff_context(self):
        strict, _ = render("git_diff", "strict")
        balanced, _ = render("git_diff", "balanced")
        self.assertNotIn("unchanged lines", strict)
        self.assertIn("unchanged lines", balanced)


if __name__ == "__main__":
    unittest.main()
