from __future__ import annotations

import unittest

from support import fixture, render

from firewall.adapters import build, listing
from firewall.adapters.common import lines_of
from firewall.store import combined_text


def diags(name):
    result = fixture(name)
    return build.parse(lines_of(combined_text(result.stdout, result.stderr)))


class Diagnostics(unittest.TestCase):
    def test_compilers_and_linters(self):
        cases = {
            "tsc_plain": [("a.ts", 2, "TS2322", "error")],
            "gcc": [("c.c", 2, "", "error")],
            "javac": [("jv/A.java", 1, "", "error")],
            "cargo_build": [("src/lib.rs", 1, "E0308", "error"), ("src/lib.rs", 2, "", "warning")],
            "ruff_full": [("m.py", 1, "F401", "issue")],
            "ruff": [("m.py", 1, "F401", "issue")],
            "mypy": [("t.py", 2, "return-value", "error"), ("t.py", 4, "assignment", "error")],
            "eslint": [("/work/es/eslint.config.js", 1, "no-undef", "error")],
        }
        for name, wanted in cases.items():
            found = diags(name)
            for file, line, code, sev in wanted:
                with self.subTest(fixture=name, want=(file, line, code, sev)):
                    self.assertTrue(any(d.file == file and d.line == line and d.code == code and d.sev == sev for d in found),
                                    [(d.file, d.line, d.code, d.sev) for d in found])

    def test_repeated_diagnostics_collapse_with_their_locations(self):
        text, _ = render("eslint")
        self.assertIn("/work/es/f1.js:2:5 no-undef 'a' is not defined\n  same at: /work/es/f2.js:2:5, /work/es/f3.js:2:5  [x3]", text)
        text, _ = render("ruff_dupes")
        self.assertIn("[x119 similar]", text)

    def test_successful_build_keeps_warnings_and_drops_progress(self):
        text, _ = render("build_ok")
        self.assertIn("BUILD PASSED (exit 0)", text)
        self.assertIn("./src/legacy.ts:12:4 export 'old' (imported as 'old') was not found in './util'", text)
        self.assertNotIn("compiling module", text)


class StackTraces(unittest.TestCase):
    def test_java_keeps_application_frames_and_cause(self):
        text, _ = render("java_trace")
        self.assertIn("java.lang.IllegalStateException: Session expired for user 42", text)
        self.assertIn("at com.acme.auth.Session.refresh(Session.java:88)", text)
        self.assertIn("Caused by: java.io.IOException: store unavailable", text)
        self.assertIn("... 26 framework/library frames", text)
        self.assertNotIn("FrameworkServlet", text)

    def test_python_traceback_collapses_stdlib_frames(self):
        from firewall.adapters import stacktrace
        raw = fixture("py_crash").stderr or fixture("py_crash").stdout
        comp = stacktrace.compress(raw, {"mode": "balanced", "maxLineChars": 300})
        body = "\n".join(comp.sections[0].lines)
        self.assertIn('File "/work/crash.py", line 5, in main', body)
        self.assertIn("load(\"{bad\")", body)
        self.assertIn("framework/library frames", body)
        self.assertIn("json.decoder.JSONDecodeError", "\n".join(comp.headline))

    def test_node_trace(self):
        from firewall.adapters import stacktrace
        comp = stacktrace.compress(fixture("node_crash").stdout, {"mode": "balanced", "maxLineChars": 300})
        body = "\n".join(comp.sections[0].lines)
        self.assertIn("TypeError", body)
        self.assertIn("crash.js:2", body)
        self.assertNotIn("node:internal/modules", body)


class PackageManagers(unittest.TestCase):
    def test_npm_keeps_summary_and_vulnerabilities(self):
        text, _ = render("npm_install")
        self.assertIn("added 1342 packages, and audited 1343 packages in 41s", text)
        self.assertIn("Deprecated packages (25):", text)
        self.assertNotIn("idealTree", text)

    def test_pip_keeps_errors(self):
        text, _ = render("pip_install")
        self.assertIn("PACKAGE MANAGER FAILED (exit 1)", text)
        self.assertIn("ERROR: No matching distribution found for nonexistent-pkg==9.9", text)
        self.assertIn("Collapsed: 60 downloads lines, 30 already satisfied lines", text)


class Listings(unittest.TestCase):
    def test_tree_output(self):
        text, _ = render("tree")
        self.assertIn("node_modules/ (360 files)", text)
        self.assertIn("  auth/ (6 files)", text)

    def test_find_output_and_expansion(self):
        raw = fixture("find").stdout
        under = listing.retrieve_file(raw, "scripts")
        self.assertIn("scripts/gate.sh", under)
        self.assertTrue(all(p.startswith("scripts") for p in under))

    def test_powershell_get_childitem_with_crlf(self):
        text, _ = render("gci")
        self.assertIn("listing:get-childitem", text)
        self.assertIn("auth/", text)
        self.assertNotIn("\r", text)

    def test_ls_recursive(self):
        entries, style = listing.paths_from(lines_of(fixture("ls_r").stdout))
        self.assertEqual(style, "ls -R")
        self.assertTrue(any(p.endswith("SKILL.md") for p, _ in entries))


class Other(unittest.TestCase):
    def test_powershell_error_records_group(self):
        text, _ = render("powershell_error")
        self.assertIn("error records: 6  distinct: 1", text)
        self.assertIn("FullyQualifiedErrorId : PathNotFound", text)
        self.assertNotIn("~~~~", text)

    def test_json_outline(self):
        text, _ = render("json")
        self.assertIn('"items": [200 items: dict]', text)
        self.assertIn('"scripts": {80 keys}', text)

    def test_unicode_survives_and_the_odd_line_out_is_surfaced(self):
        text, outcome = render("unicode")
        self.assertIn("L121: \u2716 \u5931\u8d25: \u671f\u5f85 'a' \u5b9f\u969b 'b' \u2014 Fehler in Stra\u00dfe.py:12", text.split("MOST REPEATED")[0])
        self.assertIn("\u30c6\u30b9\u30c8 0 \u00e9t\u00e9 \u4f60\u597d \U0001f680", text)

    def test_rare_lines_in_repetitive_output_are_never_hidden(self):
        from firewall.models import CommandResult
        from support import TempStore, run
        lines = [f"[{i:04d}] tick ok" for i in range(500)]
        lines[250] = "Verbindung abgelehnt: Datenbank nicht erreichbar"
        with TempStore() as store:
            out = run(CommandResult(command="./worker", cwd="/w", stdout="\n".join(lines) + "\n", exit_code=0), store)
        self.assertIn("L251: Verbindung abgelehnt: Datenbank nicht erreichbar", out.text)

    def test_malformed_output_does_not_crash_and_says_what_it_is(self):
        text, _ = render("malformed")
        self.assertIn("no git-diff structure recognised", text)
        self.assertIn("@@ not a diff @@  [x30]", text)


if __name__ == "__main__":
    unittest.main()
