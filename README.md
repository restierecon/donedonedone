# Autonomous Engineering Setup for Claude Code

A lean, hardened multi-agent setup: 4 agents, 5 skills, mechanical guardrails,
session-surviving memory, and an autonomy dial you turn up only as trust is earned.
Built for Claude Code; also works with GitHub Copilot in VS Code (see below).

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
| skills/ | protocol-native: grill · slice-planning · compaction · architecture-review · init-vault — plus a general engineering-practice library (see Credits) |
| commands/init-vault.md | One-command project bootstrap (Claude Code `/init-vault`; `skills/init-vault` is the same workflow for Copilot) |
| commands/harvest.md | `/harvest` — merged slices become user stories in vault/stories.md, then leave the task tree (`skills/harvest` is the same workflow for Copilot) |
| settings.json | Permission deny/ask lists + 4 hooks |
| scripts/ | guard.sh (PreToolUse) · lint.sh (PostToolUse) · checkpoint.sh (Stop) · generate-copilot-agents.sh (install-time only) |
| tests/ | Test harness for the hook scripts — run after any script edit; CI runs it too |
| evals/ | 10-task benchmark + scorecard — run before trusting, re-run after any manifest edit |

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

## GitHub Copilot / VS Code compatibility
VS Code's Copilot Chat reads several of Claude Code's own files directly, so most of
this setup works with zero conversion once `./install.sh` has run:
- `~/.claude/CLAUDE.md` → loaded automatically as always-on instructions
  (`chat.useClaudeMdFile`, on by default)
- `~/.claude/skills/*/SKILL.md` → auto-discovered as personal Agent Skills (same
  format, invoked automatically or via `/skill-name`)
- `~/.claude/settings.json` hooks → loaded and run the same way, **with one caveat**:
  VS Code sends different tool names/property casing than Claude Code and ignores the
  `matcher` field (every hook fires on every tool call). `guard.sh` and `lint.sh`
  normalize both vocabularies so the guardrails still fire correctly either way —
  see the comments at the top of each script if you extend them.

What doesn't carry over automatically: VS Code only auto-detects Claude-format
subagents from a *workspace* `.claude/agents` folder, not the user-level
`~/.claude/agents` this repo installs to. `install.sh` runs
`scripts/generate-copilot-agents.sh` to translate builder/reviewer/auditor/scribe
into VS Code's native format at `~/.copilot/agents/`, plus a new `orchestrator` agent
that plays the Director role (dispatches the other four as subagents — VS Code has
genuine subagent orchestration via a custom agent's `agents:` frontmatter field). The
Bash → VS Code tool-name mapping in that script is a best-effort guess; if a
generated agent seems to be missing terminal access, check the real tool identifier
via the `#` tools picker in VS Code chat and fix the mapping.

## Iterating
This repo IS your dotfiles for Claude Code (and, via the above, Copilot in VS Code).
Edit agent manifests here, re-run ./install.sh, re-run the evals, commit. The setup
improves as you use it. Re-running install.sh also regenerates
`~/.copilot/agents/` from whatever's currently in `agents/` — that output is pure
derived content, never hand-edit it directly.
Any edit to scripts/ must keep `tests/run-tests.sh` green — the guardrails are
the last line of defense, so they are the one place tests are non-negotiable.

## Credits
The overall approach here — a skills-and-agents setup for Claude Code, driven
by ADRs, gates, and an autonomy dial — was learned from
[Matt Pocock's skills](https://github.com/mattpocock/skills). The general
engineering-practice skills under `skills/` (frontend-ui-engineering,
security-and-hardening, code-review-and-quality, and others not specific to
this protocol's own vault workflow) are sourced from
[Addy Osmani's agent-skills](https://github.com/addyosmani/agent-skills).
Thanks to both for making this work public.
