from __future__ import annotations

import unittest

from support import TempStore, fixture, render, run, settings

from firewall import retrieval
from firewall.adapters import tests
from firewall.adapters.common import clean, lines_of
from firewall.store import combined_text

EXPECTED = {
    "pytest_fail": ("pytest", ["test_session_refresh", "test_token_provider", "test_crash"], "test_auth.py:15"),
    "jest": ("jest", ["Session \u203a refresh returns a new token", "TokenProvider \u203a refresh rejects expired tokens"], "src/auth/session.test.ts:142"),
    "vitest": ("vitest", ["src/auth/session.test.ts > Session > refresh returns a new token"], "src/auth/session.test.ts:142"),
    "go_test": ("go test", ["TestRefresh", "TestToken"], "auth_test.go:9"),
    "cargo_test": ("cargo test", ["tests::refresh_works", "tests::token_panics"], "src/lib.rs:6"),
    "mocha": ("mocha", ["Session refresh returns a new token", "TokenProvider rejects expired tokens"], "test/session.test.js:142"),
    "node_tap": ("tap", ["refresh works", "token provider"], "/work/nt/auth.test.mjs:3"),
    "node_spec": ("node:test spec", ["refresh works", "token provider"], "nt/auth.test.mjs:3"),
    "dotnet_test": ("dotnet test", ["Auth.Tests.SessionTests.RefreshReturnsNewToken"], "/work/Auth.Tests/SessionTests.cs:42"),
    "pester": ("pester", ["Update-Token refreshes the token"], "C:\\work\\tests\\Token.Tests.ps1:14"),
    "maven_test": ("maven surefire", ["com.acme.auth.SessionTest.refreshReturnsNewToken"], ""),
}


class TestRunners(unittest.TestCase):
    def test_each_runner_is_recognised_with_its_failures_and_locations(self):
        for name, (framework, failing, location) in EXPECTED.items():
            with self.subTest(fixture=name):
                result = fixture(name)
                report = tests.parse(lines_of(combined_text(result.stdout, result.stderr)))
                self.assertEqual(report.framework, framework)
                self.assertEqual([f.name for f in report.failures], failing)
                if location:
                    self.assertEqual(report.failures[0].location, location)
                text, _ = render(name)
                self.assertIn("Status: FAILED", text)

    def test_failure_details_are_lines_from_the_raw_output(self):
        for name in EXPECTED:
            result = fixture(name)
            raw = combined_text(result.stdout, result.stderr)
            haystack = clean(raw)
            for failure in tests.failures(raw):
                for detail in failure.details:
                    with self.subTest(fixture=name, detail=detail):
                        self.assertIn(detail, haystack)

    def test_passing_noise_is_removed(self):
        text, _ = render("pytest_fail")
        self.assertNotIn("test_many[", text)
        text, _ = render("go_test")
        self.assertNotIn("TestMany/case", text)

    def test_exit_code_disagreeing_with_the_parse_is_reported_not_hidden(self):
        raw = "==== 3 passed in 0.10s ====\n"
        comp = tests.compress(raw, {"mode": "balanced", "maxLineChars": 300, "exit_code": 2})
        self.assertEqual(comp.status, "FAILED (exit 2, no failing test parsed)")
        comp = tests.compress(raw, {"mode": "balanced", "maxLineChars": 300, "exit_code": 0})
        self.assertEqual(comp.status, "PASSED")

    def test_unknown_runner_falls_back_to_error_lines(self):
        with TempStore() as store:
            from firewall.models import CommandResult
            noise = "".join(f"step {i} fine\n" for i in range(300)) + "FATAL: database refused connection\n"
            out = run(CommandResult(command="npm test", cwd="/w", stdout=noise, exit_code=1), store)
            self.assertIn("FATAL: database refused connection", out.text)
            self.assertIn("signals/low", out.text.split("\n")[0])

    def test_retrieve_failure_by_number_and_by_name(self):
        with TempStore() as store:
            out = run(fixture("pytest_fail"), store)
            by_number = retrieval.get_test(store, out.artifact.id, "2")
            by_name = retrieval.get_test(store, out.artifact.id, "token_provider")
            self.assertEqual(by_number, by_name)
            self.assertIn("    def test_token_provider():", by_number)
            self.assertTrue("\n".join(by_number) in fixture("pytest_fail").stdout)

    def test_retrieve_failure_reports_choices_when_missing(self):
        with TempStore() as store:
            out = run(fixture("jest"), store)
            with self.assertRaises(retrieval.RetrievalError) as err:
                retrieval.get_test(store, out.artifact.id, "nope")
            self.assertIn("1. Session", str(err.exception))

    def test_failures_section_retrieval_is_unbounded(self):
        with TempStore() as store:
            out = run(fixture("pytest_fail"), store, mode="aggressive")
            lines = retrieval.get_section(store, out.artifact.id, "failures", settings())
            self.assertIn("3. test_crash", lines)


if __name__ == "__main__":
    unittest.main()
