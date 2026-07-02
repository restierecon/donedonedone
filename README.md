# Autonomous Engineering Setup for Claude Code

A lean, hardened multi-agent setup: 4 agents, 4 skills, mechanical guardrails,
session-surviving memory, and an autonomy dial you turn up only as trust is earned.

Built on: vertical slices (tracer bullets) · red-green-refactor TDD · deep modules
and the deletion test (Ousterhout) · ADRs · OWASP · Conventional Commits ·
branch-per-slice trunk discipline · mechanisms-over-instructions (hooks + git, not hope).

## Mac quick start

```bash
git clone https://github.com/restierecon/donedonedone ~/claude-setup
cd ~/claude-setup && ./install.sh
brew install jq gitleaks semgrep   # guardrail dependencies
```

Then in any project:

```bash
cd your-project
claude
> /init-vault          # one-time per project
> /grill               # interrogate the first feature, then build
```

## What's inside

| Path | What |
|---|---|
| CLAUDE.md | Global protocol — the main session IS the Director |
| agents/ | builder · reviewer · auditor · scribe (least-privilege tools, model-per-agent) |
| skills/ | grill · slice-planning · compaction · architecture-review |
| commands/init-vault.md | One-command project bootstrap |
| settings.json | Permission deny/ask lists + 4 hooks |
| scripts/ | guard.sh (PreToolUse) · lint.sh (PostToolUse) · checkpoint.sh (Stop) |
| tests/ | Test harness for the hook scripts — run after any script edit; CI runs it too |
| evals/ | 7-task benchmark + scorecard — run before trusting, re-run after any manifest edit |

## The loop
grill → slice-plan (vertical, afk/hitl tagged) → per slice on its own branch:
builder (test-first) → automated gate → reviewer (cold eyes + slop checklist) →
auditor (security surfaces only) → scribe checkpoint → merge + tag.
Failures resolve through 3 self-healing tiers with a hard budget ceiling.
Every 5 slices: architecture review.

## Safety model
- Deny/ask permission lists + PreToolUse tripwire (destructive commands can't run;
  fails closed if jq is missing)
- Subagents can't write gate state — enforced mechanically via the hook's `agent_id`
  field across Bash, Write, and Edit; reviewer/auditor can't write code at all
- Checkpoints never auto-commit on main (main is always green)
- gitleaks scan before every checkpoint commit
- `autonomy: full` is only legal in a sandbox; new projects start `supervised`

## Verify on first install
Hook and permission syntax evolves — if a hook doesn't fire, check the current
Claude Code docs (docs.claude.com) and adjust settings.json patterns.

## Iterating
This repo IS your dotfiles for Claude Code. Edit agent manifests here, re-run
./install.sh, re-run the evals, commit. The setup improves as you use it.
Any edit to scripts/ must keep `tests/run-tests.sh` green — the guardrails are
the last line of defense, so they are the one place tests are non-negotiable.
