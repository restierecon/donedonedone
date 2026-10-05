from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import support

from firewall import permissions, rewrite


class RuleMatching(unittest.TestCase):
    def test_prefix_rules(self):
        self.assertTrue(permissions.matches("Bash(npm test:*)", "npm test"))
        self.assertTrue(permissions.matches("Bash(npm test:*)", "npm test -- --watch=false"))
        self.assertFalse(permissions.matches("Bash(npm test:*)", "npm testing"))

    def test_wildcards_and_exact(self):
        self.assertTrue(permissions.matches("Bash(git push*)", "git push --force"))
        self.assertTrue(permissions.matches("Bash(*DROP TABLE*)", "psql -c 'DROP TABLE x'"))
        self.assertTrue(permissions.matches("Bash(pytest)", "pytest"))
        self.assertFalse(permissions.matches("Bash(pytest)", "pytest -q"))
        self.assertTrue(permissions.matches("Bash", "anything"))
        self.assertFalse(permissions.matches("Read(./.env)", "cat .env"))


class Verdicts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def files(self, data, allow_counts=True):
        path = self.dir / f"s{len(list(self.dir.iterdir()))}.json"
        path.write_text(json.dumps({"permissions": data}), encoding="utf-8")
        return [(path, allow_counts)]

    def test_deny_and_ask_beat_allow(self):
        files = self.files({"allow": ["Bash(pytest:*)"], "deny": ["Bash(pytest --boom)"], "ask": ["Bash(pytest -x)"]})
        self.assertEqual(permissions.verdict("pytest -q", ".", "default", files), "allow")
        self.assertEqual(permissions.verdict("pytest --boom", ".", "default", files), "deny")
        self.assertEqual(permissions.verdict("pytest -x", ".", "default", files), "ask")

    def test_unlisted_is_not_allowed_unless_bypassing(self):
        files = self.files({"allow": []})
        self.assertEqual(permissions.verdict("pytest", ".", "default", files), "unlisted")
        self.assertEqual(permissions.verdict("pytest", ".", "acceptEdits", files), "unlisted")
        self.assertEqual(permissions.verdict("pytest", ".", "bypassPermissions", files), "allow")

    def test_untrusted_project_allow_rules_do_not_count_but_its_denies_do(self):
        files = self.files({"allow": ["Bash(pytest:*)"], "deny": ["Bash(pytest --boom)"]}, allow_counts=False)
        self.assertEqual(permissions.verdict("pytest -q", ".", "default", files), "unlisted")
        self.assertEqual(permissions.verdict("pytest --boom", ".", "bypassPermissions", files), "deny")

    def test_unreadable_settings_mean_unknown(self):
        bad = self.dir / "bad.json"
        bad.write_text("{not json", encoding="utf-8")
        self.assertEqual(permissions.verdict("pytest", ".", "bypassPermissions", [(bad, True)]), "unknown")

    def test_trust_comes_from_claude_json(self):
        root = self.dir / "proj"
        root.mkdir()
        (self.dir / ".claude.json").write_text(json.dumps({"projects": {str(root): {"hasTrustDialogAccepted": True}}}), encoding="utf-8")
        with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(self.dir)}):
            self.assertTrue(permissions.trusted(root))
            self.assertFalse(permissions.trusted(self.dir))


class Planning(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / ".git").mkdir()
        self.config = self.root / "cfg"
        self.config.mkdir()
        tool = self.root / "pytest"
        tool.write_text("#!/bin/sh\necho hi\n", encoding="utf-8")
        tool.chmod(tool.stat().st_mode | stat.S_IEXEC)
        self.env = mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(self.config), "DDD_SELF": "/home/me/.claude/scripts/ddd"})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def allow(self, *rules, deny=()):
        (self.config / "settings.json").write_text(json.dumps({"permissions": {"allow": list(rules), "deny": list(deny)}}), encoding="utf-8")

    def payload(self, command, mode="default"):
        return {"hook_event_name": "PreToolUse", "session_id": "abc-123", "cwd": str(self.root), "permission_mode": mode,
                "tool_name": "Bash", "tool_input": {"command": command, "description": "d"}}

    @unittest.skipIf(os.name == "nt", "a shell script is not an executable on Windows")
    def test_allowed_simple_noisy_command_is_wrapped_and_allowed(self):
        self.allow("Bash(./pytest:*)")
        out = rewrite.plan(self.payload("./pytest -q tests/test_a.py"))
        spec = out["hookSpecificOutput"]
        self.assertEqual(spec["permissionDecision"], "allow")
        self.assertEqual(spec["updatedInput"]["command"], "/home/me/.claude/scripts/ddd run --session abc-123 --origin hook -- ./pytest -q tests/test_a.py")
        self.assertEqual(spec["updatedInput"]["description"], "d")

    def test_nothing_is_granted_that_settings_do_not_already_allow(self):
        self.allow()
        self.assertIsNone(rewrite.plan(self.payload("./pytest -q")))
        self.allow("Bash(./pytest:*)", deny=["Bash(./pytest -q)"])
        self.assertIsNone(rewrite.plan(self.payload("./pytest -q")))

    def test_shell_syntax_is_never_rewritten(self):
        self.allow("Bash")
        for command in ("./pytest -q | tail", "./pytest && echo ok", "./pytest > out.txt", "FOO=1 ./pytest", "./pytest $(cat args)",
                        "cd sub; ./pytest", "./pytest tests/*.py", "./pytest ~/x", "./pytest\n./pytest"):
            self.assertIsNone(rewrite.plan(self.payload(command)), command)

    def test_only_compressible_types_are_rewritten(self):
        self.allow("Bash")
        for command in ("echo hello", "python3 script.py", "rm file", "npm install left-pad", "cat src/a.py"):
            self.assertIsNone(rewrite.plan(self.payload(command, mode="bypassPermissions")), command)

    def test_unknown_programs_and_aliases_are_left_to_the_shell(self):
        self.allow("Bash")
        self.assertIsNone(rewrite.plan(self.payload("definitely-not-installed-xyz test", mode="bypassPermissions")))
        self.assertIsNone(rewrite.plan(self.payload("./missing-pytest -q", mode="bypassPermissions")))

    def test_firewall_and_raw_requests_pass(self):
        self.allow("Bash")
        for command in ("~/.claude/scripts/ddd artifact art-1", "~/.claude/scripts/gate.sh test", "DDD_RAW=1 ./pytest"):
            self.assertIsNone(rewrite.plan(self.payload(command, mode="bypassPermissions")), command)

    def test_disabled_or_without_a_shim_path(self):
        self.allow("Bash(./pytest:*)")
        with mock.patch.dict(os.environ, {"DDD_DISABLE": "1"}):
            self.assertIsNone(rewrite.plan(self.payload("./pytest -q")))
        with mock.patch.dict(os.environ, {"DDD_SELF": ""}):
            self.assertIsNone(rewrite.plan(self.payload("./pytest -q")))

    def test_other_tools_and_events_are_ignored(self):
        self.allow("Bash")
        p = self.payload("./pytest")
        p["tool_name"] = "PowerShell"
        self.assertIsNone(rewrite.plan(p))
        p = self.payload("./pytest")
        p["hook_event_name"] = "PostToolUse"
        self.assertIsNone(rewrite.plan(p))

    def test_main_fails_open(self):
        self.assertEqual(rewrite.main("garbage"), "")
        with mock.patch("firewall.rewrite.plan", side_effect=RuntimeError("x")):
            self.assertEqual(rewrite.main(json.dumps(self.payload("./pytest"))), "")


if __name__ == "__main__":
    unittest.main()
