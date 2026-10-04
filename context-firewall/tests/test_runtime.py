from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from support import HERE, TempStore, fixture, run, settings

from firewall import capture, hook, pipeline
from firewall.models import CommandResult
from firewall.store import ArtifactStore

DDD = str(HERE.parent / "ddd.py")
PY = sys.executable


def ddd(*args, cwd=None, env=None, stdin=None):
    full_env = dict(os.environ, **(env or {}))
    return subprocess.run([PY, DDD, *args], cwd=cwd, env=full_env, input=stdin, capture_output=True, text=True, encoding="utf-8", timeout=60)


class Capture(unittest.TestCase):
    def test_exit_code_and_split_streams(self):
        result = capture.run([PY, "-c", "import sys; print('out'); print('err', file=sys.stderr); sys.exit(3)"])
        self.assertEqual((result.exit_code, result.stdout.strip(), result.stderr.strip()), (3, "out", "err"))

    def test_timeout_keeps_partial_output(self):
        code = "import sys, time; print('started', flush=True); time.sleep(30)"
        start = time.monotonic()
        result = capture.run([PY, "-c", code], timeout=1.5)
        self.assertLess(time.monotonic() - start, 15)
        self.assertTrue(result.timed_out)
        self.assertEqual(result.exit_code, capture.TIMEOUT_EXIT)
        self.assertIn("started", result.stdout)

    def test_missing_program(self):
        result = capture.run(["definitely-not-a-real-program-xyz"])
        self.assertEqual(result.exit_code, 127)
        self.assertIn("definitely-not-a-real-program-xyz", result.stderr)

    def test_timed_out_artifact_is_flagged_in_the_header(self):
        with TempStore() as store:
            noise = "waiting for server\n" * 2000
            out = run(CommandResult(command="long", cwd="/w", stdout=noise, exit_code=124, timed_out=True), store)
            self.assertIn("TIMED OUT (partial output)", out.text.split("\n")[0])


class Robustness(unittest.TestCase):
    def test_very_large_output_is_cheap(self):
        lines = "".join(f"2026-10-04T10:00:{i % 60:02d}Z INFO request {i} served in {i % 97}ms\n" for i in range(120_000))
        lines += "2026-10-04T10:00:00Z ERROR request 7 failed: timeout\n"
        with TempStore() as store:
            start = time.perf_counter()
            out = run(CommandResult(command="tail -n 200000 app.log", cwd="/w", stdout=lines, exit_code=0), store)
            elapsed = time.perf_counter() - start
            self.assertLess(elapsed, 10)
            self.assertIn("ERROR request 7 failed: timeout", out.text)
            self.assertEqual(store.stdout(out.artifact), lines)

    def test_small_output_costs_little(self):
        with TempStore() as store:
            start = time.perf_counter()
            for _ in range(50):
                run(CommandResult(command="git status", cwd="/w", stdout="On branch main\n", exit_code=0), store, passthrough=None)
            self.assertLess((time.perf_counter() - start) / 50, 0.05)

    def test_firewall_error_falls_back_to_raw_and_is_logged(self):
        with TempStore() as store:
            with mock.patch("firewall.adapters.compress", side_effect=RuntimeError("boom")):
                out = run(fixture("pytest_fail"), store)
            self.assertTrue(out.passthrough)
            self.assertIn("firewall error", out.reason)
            failures = [e for e in store.events() if e["kind"] == "failure"]
            self.assertEqual(len(failures), 1)
            self.assertIn("boom", failures[0]["error"])
            self.assertEqual(store.stdout(out.artifact), fixture("pytest_fail").stdout)

    def test_unwritable_store_falls_back_to_raw(self):
        with tempfile.TemporaryDirectory() as tmp:
            blocker = Path(tmp) / "file"
            blocker.write_text("x")
            store = ArtifactStore(blocker / "store")
            out = pipeline.process(fixture("pytest_fail"), settings(), store)
            self.assertTrue(out.passthrough)

    def test_source_code_is_never_compressed(self):
        with TempStore() as store:
            body = "".join(f"def f{i}():\n    return {i}\n" for i in range(500))
            out = run(CommandResult(command="cat src/big.py", cwd="/w", stdout=body, exit_code=0), store)
            self.assertTrue(out.passthrough)
            self.assertEqual(out.reason, "source code is passed through exactly")

    def test_pipe_filtered_output_within_budget_passes_through(self):
        with TempStore() as store:
            text = "".join(f"src/a{i}.ts:{i}:match\n" for i in range(150))
            out = run(CommandResult(command="rg -n match | head -150", cwd="/w", stdout=text, exit_code=0), store)
            self.assertTrue(out.passthrough)


class Hook(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = self.tmp.name
        Path(self.cwd, ".git").mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def payload(self, command, stdout, stderr="", tool="Bash", **extra):
        body = {"hook_event_name": "PostToolUse", "session_id": "sess-1", "cwd": self.cwd, "tool_name": tool,
                "tool_input": {"command": command}, "tool_response": {"stdout": stdout, "stderr": stderr, "interrupted": False, "isImage": False}}
        body.update(extra)
        return body

    def test_noisy_output_is_replaced_with_the_same_shape(self):
        result = fixture("pytest_fail")
        out = hook.handle(self.payload(result.command, result.stdout))
        updated = out["hookSpecificOutput"]["updatedToolOutput"]
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "PostToolUse")
        self.assertEqual(set(updated), {"stdout", "stderr", "interrupted", "isImage"})
        self.assertTrue(updated["stdout"].startswith("[ddd] test | art-"))
        self.assertEqual(updated["stderr"], "")
        store = ArtifactStore.for_cwd(self.cwd)
        self.assertEqual(store.all()[0].session, "sess-1")
        self.assertEqual(store.all()[0].origin, "hook")
        self.assertTrue((Path(self.cwd) / ".ddd" / ".gitignore").exists())

    def test_small_output_is_left_alone(self):
        self.assertIsNone(hook.handle(self.payload("git status", "On branch main\n")))

    def test_firewall_commands_and_raw_requests_are_never_rewritten(self):
        noisy = fixture("pytest_fail").stdout
        for command in ("~/.claude/scripts/ddd artifact art-1 --raw", "python3 /x/ddd.py artifact art-1", "DDD_RAW=1 pytest -v"):
            self.assertIsNone(hook.handle(self.payload(command, noisy)), command)

    def test_background_and_non_shell_tools_are_ignored(self):
        noisy = fixture("pytest_fail").stdout
        p = self.payload("pytest", noisy)
        p["tool_input"]["run_in_background"] = True
        self.assertIsNone(hook.handle(p))
        self.assertIsNone(hook.handle(self.payload("pytest", noisy, tool="Read")))

    def test_edits_mark_files_active(self):
        p = {"hook_event_name": "PostToolUse", "session_id": "sess-1", "cwd": self.cwd, "tool_name": "Edit", "tool_input": {"file_path": f"{self.cwd}/src/a.py"}, "tool_response": {}}
        self.assertIsNone(hook.handle(p))
        from firewall import dedup
        self.assertEqual(dedup.active_files(dedup.load(ArtifactStore.for_cwd(self.cwd), "sess-1"), self.cwd), ["src/a.py"])

    def test_powershell_tool_and_string_responses(self):
        err = fixture("powershell_error").stderr
        p = self.payload("./scripts/deploy.ps1", "", err, tool="PowerShell")
        updated = hook.handle(p)["hookSpecificOutput"]["updatedToolOutput"]
        self.assertIn("powershell:error-records", updated["stdout"])
        p = self.payload("pytest", "")
        p["tool_response"] = fixture("pytest_fail").stdout
        self.assertIsInstance(hook.handle(p)["hookSpecificOutput"]["updatedToolOutput"], str)

    def test_disabled(self):
        with mock.patch.dict(os.environ, {"DDD_DISABLE": "1"}):
            self.assertIsNone(hook.handle(self.payload("pytest", fixture("pytest_fail").stdout)))

    def test_garbage_payload_produces_no_output(self):
        self.assertEqual(hook.main("not json"), "")
        self.assertEqual(hook.main("[]"), "")
        self.assertEqual(hook.main(json.dumps({"tool_name": "Bash", "tool_input": {"command": "x"}, "tool_response": {"stdout": 5}})), "")

    def test_hook_process_end_to_end(self):
        payload = json.dumps(self.payload("npm test", fixture("jest").stdout))
        done = ddd("hook", stdin=payload)
        self.assertEqual(done.returncode, 0)
        self.assertIn("updatedToolOutput", done.stdout)
        self.assertIn("Session › refresh returns a new token", json.loads(done.stdout)["hookSpecificOutput"]["updatedToolOutput"]["stdout"])


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = {"DDD_HOME": str(Path(self.tmp.name) / "store"), "DDD_COMMAND": "ddd"}

    def tearDown(self):
        self.tmp.cleanup()

    def test_run_propagates_exit_code_and_compresses(self):
        script = "import sys\nfor i in range(400): print(f'2026-10-04T10:00:00Z INFO step {i} ok')\nprint('FATAL: disk full')\nsys.exit(4)"
        done = ddd("run", "--", PY, "-c", script, env=self.env)
        self.assertEqual(done.returncode, 4)
        self.assertIn("FATAL: disk full", done.stdout)
        self.assertTrue(done.stdout.startswith("[ddd] "))
        artifact_id = done.stdout.split(" | ")[1]
        lines = ddd("artifact", artifact_id, "--lines", "401-401", env=self.env)
        self.assertEqual(lines.stdout.strip(), "401: FATAL: disk full")
        raw = ddd("artifact", artifact_id, "--raw", env=self.env)
        self.assertEqual(raw.stdout.count("\n"), 401)
        show = ddd("show", artifact_id, env=self.env)
        self.assertIn("--- sent to the model ---", show.stdout)
        self.assertIn("retrievals   2", show.stdout)

    def test_small_command_output_is_printed_untouched(self):
        done = ddd("run", "--", PY, "-c", "import sys; print('hi'); print('warn', file=sys.stderr)", env=self.env)
        self.assertEqual((done.stdout, done.stderr.strip()), ("hi\n", "warn"))

    def test_bare_command_shorthand(self):
        done = ddd(PY, "-c", "print('x')", env=self.env)
        self.assertEqual(done.stdout, "x\n")

    def test_stats_after_activity(self):
        ddd("run", "--", PY, "-c", "for i in range(3000): print('same line')", env=self.env)
        stats = ddd("stats", env=self.env)
        self.assertIn("Commands intercepted  1", stats.stdout)
        self.assertIn("estimates", stats.stdout)
        data = json.loads(ddd("stats", "--json", env=self.env).stdout)
        self.assertGreater(data["raw"], data["sent"])

    def test_bench_over_fixtures(self):
        done = ddd("bench", str(HERE / "fixtures"), "--modes", "balanced", env=self.env)
        self.assertEqual(done.returncode, 0)
        self.assertIn("TOTAL balanced", done.stdout)

    def test_unknown_artifact_is_a_clean_error(self):
        done = ddd("artifact", "art-ffffffffff", env=self.env)
        self.assertEqual(done.returncode, 1)
        self.assertIn("no artifact", done.stderr)

    def test_ingest_quiet_passthrough_for_gate(self):
        done = ddd("ingest", "--command", "test", "--quiet-passthrough", env=self.env, stdin="ok\n")
        self.assertEqual((done.returncode, done.stdout), (3, ""))


if __name__ == "__main__":
    unittest.main()
