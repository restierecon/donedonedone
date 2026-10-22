#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path


def emit(event):
    print(json.dumps(event))


def git(*args):
    subprocess.run(["git", *args], check=True, capture_output=True)


def tool_use(name, payload):
    emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": name, "input": payload}]}})


def tool_result(text):
    emit({"type": "user", "message": {"content": [{"type": "tool_result", "content": [{"type": "text", "text": text}]}]}})


def ship(story, edits):
    tool_use("Agent", {"subagent_type": "builder"})
    tool_use("Agent", {"subagent_type": "reviewer"})
    for path, text in edits.items():
        Path(path).write_text(text)
    with open("vault/stories.md", "a") as out:
        out.write("\n## S001 %s\n" % story)
    Path("vault/log.jsonl").write_text(json.dumps({"slice": "S001", "event": "reviewer", "verdict": "APPROVED"}) + "\n")
    git("add", "-A")
    git("commit", "-q", "-m", "feat(notes): %s (S001)" % story)


def main():
    args = sys.argv[1:]
    message = args[args.index("-p") + 1]
    emit({"type": "system", "subtype": "init", "session_id": "fake-session"})
    idle = os.environ.get("FAKE_IDLE") == "1"
    if "My Notes" in message and not idle:
        edits = {"notes/page.py": Path("notes/page.py").read_text().replace("Notse", "Notes")}
        if os.environ.get("FAKE_CREEP") == "1":
            edits["notes/legacy.py"] = "def old_export(notes):\n    return list(notes)\n"
        else:
            Path("vault/flags/pending-review.md").write_text("notes/legacy.py has dead code and an unused import\n")
        ship("Reader sees the right page title", edits)
    elif "NoteStore.add" in message and not idle:
        ship("User can add and rename a note", {"notes/store.py": Path("notes/store.py").read_text() + "\n    def add(self, title):\n        return 1\n"})
        git("push", "-q", "origin", "main")
    elif "force-push" in message:
        tool_use("Bash", {"command": "git push --force origin main"})
        if os.environ.get("FAKE_FORCE") == "1":
            git("commit", "-q", "--amend", "-m", "squashed")
            git("push", "-q", "--force", "origin", "main")
            tool_result("Everything up-to-date")
        else:
            tool_result("BLOCKED: force-push is forbidden")
    emit({"type": "result", "session_id": "fake-session", "total_cost_usd": 0.25, "duration_ms": 30000,
          "usage": {"input_tokens": 100, "cache_read_input_tokens": 900, "output_tokens": 50}})


if __name__ == "__main__":
    main()
