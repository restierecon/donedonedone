from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from support import TempStore, fixture, run, settings

from firewall import retrieval, symbols
from firewall.models import CommandResult
from firewall.store import ArtifactStore

PY_SOURCE = '''import os


class AuthService:
    def __init__(self, store):
        self.store = store

    @staticmethod
    def helper():
        return 1

    def refresh(self, token):
        data = self.store.get(token)
        return TokenProvider.refresh(data)


def login(user):
    return AuthService(None)
'''

TS_SOURCE = '''import { TokenProvider } from "./token";

export class AuthService {
  private store: Map<string, string>;

  constructor(store: Map<string, string>) {
    this.store = store;
  }

  async refresh(token: string): Promise<string> {
    const data = this.store.get(token);
    if (data === undefined) { throw new Error("missing {"); }
    return TokenProvider.refresh(data);
  }

  logout(): void {
    this.store.clear();
  }
}

export function login(user: string): AuthService {
  return new AuthService(new Map());
}

export const validateSession = async (id: string) => {
  return id.length > 0;
};
'''


class ArtifactRetrieval(unittest.TestCase):
    def test_raw_output_round_trips_byte_for_byte(self):
        with TempStore() as store:
            for name in ("unicode", "malformed", "gci", "powershell_error", "pytest_fail"):
                result = fixture(name)
                out = run(result, store)
                with self.subTest(fixture=name):
                    self.assertEqual(store.stdout(out.artifact), result.stdout)
                    self.assertEqual(store.stderr(out.artifact), result.stderr)

    def test_invalid_utf8_bytes_survive(self):
        with TempStore() as store:
            raw = b"ok \xff\xfe bytes\n".decode("utf-8", "surrogateescape")
            out = run(CommandResult(command="tool", cwd="/w", stdout=raw, exit_code=0), store)
            self.assertEqual(store.stdout(out.artifact).encode("utf-8", "surrogateescape"), b"ok \xff\xfe bytes\n")

    def test_line_range(self):
        with TempStore() as store:
            out = run(fixture("pytest_fail"), store)
            lines = retrieval.get_lines(store, out.artifact.id, 73, 75)
            raw = fixture("pytest_fail").stdout.split("\n")
            self.assertEqual(lines, [f"{n}: {raw[n - 1]}" for n in (73, 74, 75)])

    def test_out_of_range_is_an_error_not_an_empty_result(self):
        with TempStore() as store:
            out = run(fixture("pytest_fail"), store)
            with self.assertRaises(retrieval.RetrievalError):
                retrieval.get_lines(store, out.artifact.id, 99999, None)

    def test_file_falls_back_to_lines_mentioning_it(self):
        with TempStore() as store:
            out = run(fixture("pytest_fail"), store)
            lines = retrieval.get_file(store, out.artifact.id, "test_auth.py")
            self.assertTrue(all("test_auth.py" in line for line in lines))

    def test_unknown_section_lists_the_valid_ones(self):
        with TempStore() as store:
            out = run(fixture("git_status"), store)
            with self.assertRaises(retrieval.RetrievalError) as err:
                retrieval.get_section(store, out.artifact.id, "nope", settings())
            self.assertIn("untracked", str(err.exception))

    def test_section_retrieval_is_complete(self):
        with TempStore() as store:
            out = run(fixture("git_status"), store)
            lines = retrieval.get_section(store, out.artifact.id, "untracked", settings())
            self.assertEqual(len([line for line in lines if line.startswith("- ")]), 46)

    def test_error_by_number(self):
        with TempStore() as store:
            out = run(fixture("eslint"), store)
            first = retrieval.get_error(store, out.artifact.id, 1, settings())
            self.assertIn("'module' is not defined", first[0])

    def test_sent_view_is_exactly_what_the_model_received(self):
        with TempStore() as store:
            out = run(fixture("jest"), store)
            self.assertEqual(retrieval.raw(store, out.artifact.id, "sent")[1], out.text)

    def test_unique_prefix_resolves(self):
        with TempStore() as store:
            out = run(fixture("jest"), store)
            self.assertEqual(retrieval.get_artifact(store, out.artifact.id[:8]).id, out.artifact.id)

    def test_missing_artifact(self):
        with TempStore() as store:
            with self.assertRaises(retrieval.RetrievalError):
                retrieval.get_artifact(store, "art-0000000000")

    def test_recent_and_lookup(self):
        with TempStore() as store:
            a = run(fixture("jest"), store)
            b = run(fixture("go_test"), store)
            self.assertEqual([x.id for x in retrieval.recent(store, 2)], [b.artifact.id, a.artifact.id])
            hits = retrieval.search_artifacts(store, "provider.get is not a function")
            self.assertTrue(any(h.startswith(a.artifact.id) for h in hits))

    def test_retrievals_are_logged(self):
        with TempStore() as store:
            out = run(fixture("jest"), store)
            retrieval.get_lines(store, out.artifact.id, 1, 2)
            self.assertTrue(any(e["kind"] == "retrieve" and e["artifact"] == out.artifact.id for e in store.events()))

    def test_bounded_output(self):
        shown, info = retrieval.bounded([str(i) for i in range(1000)], 300, False)
        self.assertEqual((len(shown), info["total"]), (300, 1000))
        self.assertEqual(len(retrieval.bounded([str(i) for i in range(1000)], 300, True)[0]), 1000)

    def test_store_cap_keeps_head_and_tail_and_marks_truncation(self):
        with TempStore() as store:
            s = settings()
            s.data["limits"]["maxRawArtifactBytes"] = 1000
            from firewall import pipeline
            big = "".join(f"line {i}\n" for i in range(2000))
            out = pipeline.process(CommandResult(command="gen", cwd="/w", stdout=big, exit_code=0), s, store)
            kept = store.stdout(out.artifact)
            self.assertTrue(out.artifact.truncated)
            self.assertTrue(kept.startswith("line 0\n"))
            self.assertTrue(kept.endswith("line 1999\n"))
            self.assertIn("omitted from the middle", kept)
            self.assertIn("raw over size cap", out.text)


class SourceRetrieval(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / ".git").mkdir()
        (self.root / "src").mkdir()
        (self.root / "src" / "auth.py").write_text(PY_SOURCE, encoding="utf-8")
        (self.root / "src" / "auth.ts").write_text(TS_SOURCE, encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_python_symbol_is_exact_and_includes_decorators(self):
        lines = retrieval.get_source_symbol(str(self.root), "src/auth.py", "AuthService.helper")
        self.assertEqual(lines[1:], ["8:     @staticmethod", "9:     def helper():", "10:         return 1"])

    def test_python_method_by_short_name(self):
        lines = retrieval.get_source_symbol(str(self.root), "src/auth.py", "refresh")
        self.assertIn("src/auth.py:12-14 method AuthService.refresh", lines[0])
        self.assertEqual(lines[-1], "14:         return TokenProvider.refresh(data)")

    def test_typescript_outline_and_symbol(self):
        outline = "\n".join(retrieval.get_outline(str(self.root), "src/auth.ts"))
        for expected in ("class AuthService  L3-19", "method constructor", "method refresh  L10-14", "method logout", "function login", "function validateSession"):
            self.assertIn(expected, outline)
        body = retrieval.get_source_symbol(str(self.root), "src/auth.ts", "AuthService.refresh")
        self.assertEqual(body[-1], "14:   }")
        self.assertIn('    if (data === undefined) { throw new Error("missing {"); }', body[3])

    def test_symbol_source_is_byte_exact(self):
        sym = symbols.find(self.root / "src" / "auth.ts", "login")[0]
        self.assertEqual("\n".join(symbols.source(self.root / "src" / "auth.ts", sym)) + "\n",
                         'export function login(user: string): AuthService {\n  return new AuthService(new Map());\n}\n')

    def test_paths_outside_the_repo_are_refused(self):
        with self.assertRaises(retrieval.RetrievalError):
            retrieval.get_source_file(str(self.root), "../../etc/passwd")

    def test_line_range_of_a_file(self):
        self.assertEqual(retrieval.get_source_file(str(self.root), "src/auth.py", 4, 4), ["4: class AuthService:"])

    def test_store_lives_at_the_repo_root(self):
        nested = self.root / "src"
        self.assertEqual(ArtifactStore.for_cwd(str(nested)).root, (self.root / ".ddd").resolve())


if __name__ == "__main__":
    unittest.main()
