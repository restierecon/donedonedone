# Autonomous Engineering Setup for Claude Code

A lean, hardened multi-agent setup: 5 agents, protocol skills, mechanical guardrails,
session-surviving memory, and an autonomy dial you turn up only as trust is earned.
Built for Claude Code; also works with GitHub Copilot in VS Code and with Cursor (see below).

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
> /init-vault          # one-time per project; asks for your lint/test/build commands
> /grill               # mandatory before any work — settles every human decision
```

After the grill, the Director dispatches the planner, shows you the slice table, and
builds. Nothing after the grill should need you unless a slice escalates.

## What's inside

| Path | What |
|---|---|
| CLAUDE.md | Global protocol — the main session IS the Director |
| agents/ | planner · builder · reviewer · auditor · scribe (least-privilege tools, model-per-agent) |
| skills/ | protocol-native: grill · slice-planning · parallel-dispatch · compaction · architecture-review · `/init-vault` · `/harvest` — plus a general engineering-practice library (see Credits) |
| settings.json | Permission deny/ask lists + 4 hooks |
| scripts/ | guard.sh (PreToolUse) · lint.sh (PostToolUse) · checkpoint.sh (Stop) · session-start.sh (SessionStart) · gate.sh (quiet lint/types/test/build runner) · generate-agents.sh (Copilot/Cursor agents, install-time) · agents-md.sh (protocol block in a project's AGENTS.md, for Cursor/Copilot) |
| tests/ | Test harness for the hook scripts — run after any script edit; CI runs it too |
| evals/ | 10-task benchmark + scorecard — run before trusting, re-run after any manifest edit |

## The loop
grill (mandatory; settles every human decision) → planner (vertical slices, all
autonomous) → per slice on its own branch:
builder (test-first) → gate.sh once → reviewer (cold eyes + slop checklist) →
auditor (security surfaces only) → merge + tag → scribe (story + compaction, once).
Failures resolve through 3 self-healing tiers. A slice that exhausts them, hits the
budget ceiling (10 builder/reviewer/auditor calls), or fails a merge twice **escalates**:
it halts, lands in `vault/flags/pending-review.md`, and goes back through the grill —
other slices keep going. Every 5 slices: architecture review.

## Autonomy dial (`vault/project.md`)
- **supervised** (default) — every slice pauses for your approval after its gates
- **semi** — green slices merge; an escalation or an auditor finding pauses the queue
- **full** — everything green merges, flags reviewed async; sandbox/devcontainer only

Promotion past supervised needs a 10-slice clean streak *and* a dated passing
scorecard in `evals/` — see the promotion rule in `evals/README.md`.

## Gate commands
`gate.sh` reads one line per step from `vault/project.md` (`/init-vault` writes them):

```markdown
## Gate
- gate.lint: ruff check -q .
- gate.types: mypy src
- gate.test: python -m pytest -q
- gate.build: python -m build
```

Leave out a step your stack doesn't have — it reports SKIP. Run `gate.sh test` for one
step, no arguments for all four; full logs land in `.gate/` (gitignored).

## Token budget
Where the protocol spends tokens, and what keeps it down:
- **Test output** — the biggest avoidable cost. Every check runs through `gate.sh`,
  which prints one line per step and a ≤ 30-line failure excerpt; full logs stay in
  `.gate/`. The full gate runs once per slice (Director), not three times.
- **Subagent cold starts** — scribe runs once per slice, not after every gate; the
  planner reads the codebase for decomposition so the Director's long-lived context
  doesn't; agents get file paths, not pasted contents.
- **Model choice** — builder drops to sonnet for small slices; reviewer is sonnet,
  scribe haiku.
- **Always-loaded text** — the global CLAUDE.md is kept small (rarely-needed procedure
  lives in on-demand skills like parallel-dispatch) and is inert outside a vault project.
- **Resume** — the SessionStart hook injects session state, live slices, git status and
  leftover worktrees in one go.

These are design estimates, not measurements. To measure, run eval E1 against two
manifest commits and compare cost and token counts.

## Safety model
- Deny/ask permission lists + PreToolUse tripwire (destructive commands can't run;
  fails closed if jq is missing)
- Subagents can't write gate state — enforced mechanically via the hook's `agent_id`
  field across Bash, Write, and Edit; reviewer/auditor have no write tools at all; the
  planner can Write but is scoped to its draft plan file by its manifest (prompt
  discipline, not enforcement — the hook still blocks it from task-tree.json)
- Checkpoints never auto-commit on main (main is always green)
- gitleaks scan before every checkpoint commit
- `autonomy: full` is only legal in a sandbox; new projects start `supervised`

## Upgrading an existing install
Pull, re-run `./install.sh`. It retires old `~/.claude/commands/init-vault.md` and
`harvest.md` (now skills) to `.bak-<timestamp>` copies. In each existing project:
1. Add `gate.*` lines to `vault/project.md` (see Gate commands) — without them every
   gate step reports SKIP.
2. Add `.gate/` to `.gitignore`.
3. Run `~/.claude/scripts/agents-md.sh` once in the project so Cursor and Copilot get
   the protocol through AGENTS.md; commit it.
4. Slices already in `task-tree.json` with a `mode: afk|hitl` field keep working; the
   field is ignored. Any former hitl slice whose human decision is still open should
   go back through `/grill` before it's built.

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
`scripts/generate-agents.sh copilot` to translate every agent in `agents/`
into VS Code's native format at `~/.copilot/agents/`, plus a new `orchestrator` agent
that plays the Director role (dispatches the five agents above as subagents — VS Code has
genuine subagent orchestration via a custom agent's `agents:` frontmatter field). The
Bash → VS Code tool-name mapping in that script is a best-effort guess; if a
generated agent seems to be missing terminal access, check the real tool identifier
via the `#` tools picker in VS Code chat and fix the mapping.

## Cursor compatibility
What Cursor picks up with no conversion: `~/.claude/skills/` (all skills) and
`~/.claude/agents/` (all subagents). What `./install.sh` adds when it finds `~/.cursor`
(or `cursor` on PATH, or you run `CURSOR=1 ./install.sh`):
- `~/.cursor/agents/*.md`: the same agents, re-emitted with Cursor's `readonly` flag.
  Cursor ignores Claude's `tools:` allowlist, so without these copies the reviewer and
  auditor could edit files. Same-named files here take precedence over `~/.claude/agents`.
  Models: `haiku` becomes `fast`; everything else becomes `inherit`.
- `~/.cursor/hooks.json`: the same scripts on Cursor's events. `beforeShellExecution` →
  guard.sh (answers with Cursor's allow/deny JSON), `afterFileEdit` → lint.sh,
  `stop` → checkpoint.sh, `sessionStart` → session-start.sh. An existing hooks.json is
  never overwritten; the new one lands next to it as `hooks.json.new-<timestamp>`.

Cursor never reads CLAUDE.md and has no file-based global rules; it reads the project's
`AGENTS.md`. See "AGENTS.md" below.

Known gaps under Cursor:
- **Vault-integrity check isn't enforced.** Cursor's hook payloads don't say which
  subagent is acting, so "subagents can't write task-tree.json" is prompt discipline
  there, not a hook.
- **Lint errors don't reach the agent.** `afterFileEdit` runs after the edit and Cursor
  ignores its exit code. Files still get formatted; errors surface at `gate.sh`.
- **Session context injection may not work.** Cursor has a reported bug where
  `sessionStart`'s `additional_context` isn't injected. If the agent doesn't see its
  session state, it can read `vault/memory/session.md` itself.
- **Hook payload fields are unverified.** They come from secondary sources (Cursor's
  docs weren't reachable when this was written). If a hook doesn't fire, check Cursor's
  hooks docs and adjust the event names in `install.sh`.

## AGENTS.md (Cursor and Copilot)
Cursor and GitHub Copilot both read a project's `AGENTS.md`; Claude Code reads the
global `~/.claude/CLAUDE.md` instead. `/init-vault` runs `~/.claude/scripts/agents-md.sh`,
which writes the protocol into AGENTS.md between
`<!-- skeletoncrew:protocol:begin … -->` and `<!-- skeletoncrew:protocol:end -->`.
Anything else in the file is yours and is never touched. The session-start hook rewrites
the block whenever `~/.claude/CLAUDE.md` changes, so upgrades propagate — commit the diff.

This also reaches Copilot surfaces that never see `~/.claude/`: the cloud coding agent
and the CLI get the protocol text, but not gate.sh, the hooks, or the agents, so there it
is guidance only.

VS Code reads both files: `~/.claude/CLAUDE.md` (`chat.useClaudeMdFile`, on by default)
and AGENTS.md, so in a vault project the protocol loads twice. To avoid paying for it
twice, turn off `chat.useClaudeMdFile`. Nothing is lost: the protocol only applies in
vault projects, and every vault project carries AGENTS.md.

## Iterating
This repo IS your dotfiles for Claude Code (and, via the above, Copilot in VS Code and Cursor).
Edit agent manifests here, re-run ./install.sh, re-run the evals, commit. The setup
improves as you use it. Re-running install.sh also regenerates
`~/.copilot/agents/` (and `~/.cursor/agents/`) from whatever's currently in `agents/` — that output is pure
derived content, never hand-edit it directly.
The global CLAUDE.md is inert in any directory without a `vault/` — including this
repo — so editing the setup itself doesn't put Claude into Director mode.
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
