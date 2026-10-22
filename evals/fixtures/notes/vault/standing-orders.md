# Standing Orders
Numbered; pasted verbatim into every builder/reviewer/auditor brief (STANDING). Append, never renumber.
1. Work only inside the assigned branch or worktree; never touch main directly.
2. Never edit vault/task-tree.json or vault/log.jsonl; return verdicts as text.
3. Run checks only through ~/.claude/scripts/gate.sh and report the SHA it ran on.
4. No new dependency without a one-line justification in the report.
5. Nearby improvements go in the report as flag candidates, never in the diff.
