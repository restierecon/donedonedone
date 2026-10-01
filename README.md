# Autonomous Engineering Setup for Claude Code

A lean, hardened multi-agent setup: 6 agents, protocol skills, mechanical guardrails,
session-surviving memory, a learning loop that turns repeated failures into fixes, and an autonomy dial you turn up only as trust is earned.
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
| agents/ | planner · builder · reviewer · auditor · scribe · retro (least-privilege tools, model-per-agent) |
| skills/ | protocol-native: grill · slice-planning · parallel-dispatch · compaction · architecture-review · learning-loop · `/init-vault` · `/harvest` — plus a general engineering-practice library (see Credits) |
| settings.json | Permission deny/ask lists + 4 hooks |
| scripts/ | guard.sh (PreToolUse) · lint.sh (PostToolUse) · checkpoint.sh (Stop) · session-start.sh (SessionStart) · gate.sh (quiet lint/types/test/build runner + built-in TODO/FIXME and no-comments checks) · find-comments.sh (the comment detector behind that check) · log-event.sh (the Director's structured log.jsonl writer) · generate-agents.sh (Copilot/Cursor agents, install-time) · agents-md.sh (protocol block in a project's AGENTS.md, for Cursor/Copilot) |
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

## Learning loop
Every gate verdict goes into `vault/log.jsonl` through `log-event.sh`, with the CRITICAL
critique lines and a category attached when a gate fails. Tier 3 tiebreaks, escalations
and your corrections are logged the same way. The scribe discards reasoning trails when
it compacts; this log is never compacted, so the failure signal survives.

Every 5 slices, alongside architecture review (code lens), the `retro` agent reads the
log since the last retro (process lens). It only reports a failure that recurred across
two or more slices. It names the rule that let the failure through and proposes the
strongest fix: a check that fails mechanically before more manifest text. Proposals go
to `pending-review.md`; nothing is applied without you. Accepted global fixes land in
this repo; re-run `./install.sh` and the eval the proposal names. If the same category
fails in two slices before the counter comes round, `log-event.sh` prints `RETRO DUE`
and the retro runs before the next builder. Run it by hand with `/learning-loop`.

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

Leave out a step your stack doesn't have — it reports SKIP. The exception is `test`:
without a `gate.test` line the gate fails, so an unconfigured project can't pass on
nothing. A project that really has no tests writes `- gate.test: none`. Two more steps are built in
and need no line; both look only at what the diff against `main` (`GATE_BASE` to
override) adds, outside `vault/`:
- `markers` fails on an added TODO, FIXME or XXX.
- `comments` fails on an added comment (see No comments below).

Run `gate.sh test` for one step, no arguments for all six; a misspelled step name is an
error, not a SKIP. Full logs land in `.gate/` (gitignored). The gate refuses to run on
uncommitted changes outside `vault/` so `GATE: PASS @ <sha>` always describes that SHA;
`GATE_ALLOW_DIRTY=1` overrides it for a local look.

## No comments
No codebase built with this setup carries comments: no line comments, block comments,
docstrings or doc comments. Names, types and small functions say *what*. A *why* the
code can't say — a vendor quirk, an editor's payload format, a legal rule — goes where
it can't silently rot:
- **a test named for the constraint** (strongest: undo the constraint and it fails,
  and its name says why) — this repo's own tests are the example, e.g. "guard blocks a
  force push sent as Copilot's run_in_terminal"
- **an ADR** in `vault/decisions/` for a decision with a load-bearing rationale
- **the commit message**, found through `git blame`

Machine-read directives aren't comments and stay: shebangs, encoding cookies, lint and
type suppressions (`# noqa`, `// eslint-disable-next-line`, `# shellcheck disable`,
`@ts-expect-error`), build tags (`//go:build`), bundler annotations (`/*#__PURE__*/`),
and SPDX/copyright lines. Write them bare — the reason goes in the commit message.

`scripts/find-comments.sh` enforces it. It knows Python, shell, Ruby, JS/TS, Go, Rust,
the C and JVM families, PHP, CSS/SCSS, SQL, Lua, Haskell, YAML/TOML/HCL, Dockerfiles,
Makefiles and HTML/XML/Vue/Svelte, and it steps over strings, template literals,
heredocs and raw strings. File types it doesn't know pass; the reviewer checks what
the gate can't parse. Two optional project.md lines:

```markdown
- gate.comments.skip: migrations/ alembic/versions/
- gate.comments.directives: ^my-tool:
```

`skip` takes path prefixes for generated code; `directives` adds a regex for a tool
directive the gate doesn't know. In an adopted codebase only added lines are checked:
existing comments stay until a slice rewrites those lines.

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
  fails closed if jq is missing). guard.sh carries the settings.json Bash denies itself
  (`git reset --hard`, `git clean -f`, force pushes, `sudo`, `curl | sh`, `chmod -R 777`,
  DROP/TRUNCATE) because Cursor and Copilot never read settings.json; it also blocks
  `git checkout/restore .`, deleting main, and a recursive rm of `/`, `~`, `$HOME`, `.`
  or `..` however the flags are spelled. Relative `rm -rf ./build` stays allowed there
  (settings.json still denies it under Claude Code).
- Subagents can't write gate state — enforced mechanically via the hook's `agent_id`
  field across Bash, Write, and Edit. A subagent Bash command that names
  task-tree.json, log.jsonl or session.md is allowed only when it is plainly read-only
  (`cat`, `head`, `grep`, `jq`, `git diff/log/show`… with no redirect or command
  substitution); anything else that names them is blocked; reviewer/auditor have no write tools at all; the
  planner can Write but is scoped to its draft plan file by its manifest (prompt
  discipline, not enforcement — the hook still blocks it from task-tree.json). The same
  hook keeps subagents out of vault/log.jsonl, including through log-event.sh
- Checkpoints never auto-commit on main (main is always green)
- gitleaks scan before every checkpoint commit
- `autonomy: full` is only legal in a sandbox; new projects start `supervised`

## Upgrading an existing install
Pull, re-run `./install.sh`. It retires old `~/.claude/commands/init-vault.md` and
`harvest.md` (now skills) to `.bak-<timestamp>` copies. In each existing project:
1. Add `gate.*` lines to `vault/project.md` (see Gate commands). `gate.test` is now
   required — the gate fails without it (`- gate.test: none` if there are no tests).
   Commit before running the gate: it now refuses uncommitted changes outside `vault/`.
2. Add `.gate/` and `vault/handoffs/plan-draft.json` to `.gitignore`.
3. Run `~/.claude/scripts/agents-md.sh` once in the project so Cursor and Copilot get
   the protocol through AGENTS.md; commit it.
4. Slices already in `task-tree.json` with a `mode: afk|hitl` field keep working; the
   field is ignored. Any former hitl slice whose human decision is still open should
   go back through `/grill` before it's built.
5. Nothing to migrate in `vault/log.jsonl`: older hand-written lines are skipped by the
   retro and RETRO DUE check. The first retro reads the whole log; after that, each run
   starts where the previous one's `retro` line left off. If the default branch isn't
   `main`, set `GATE_BASE` or the `markers` and `comments` gate steps report SKIP.
6. The `comments` step checks only lines a slice adds, so existing comments don't fail
   the gate. Add `gate.comments.skip` for generated code (see No comments).

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
that plays the Director role (dispatches every agent above as a subagent — its
`agents:` roster is generated from `agents/`, so a new agent needs no generator edit;
VS Code has genuine subagent orchestration via that frontmatter field). The
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
  subagent is acting, so "subagents can't write task-tree.json or log.jsonl" is prompt
  discipline there, not a hook.
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

## Scripts
Installed to `~/.claude/scripts/`. Each one's behavior is pinned by a named test in
`tests/run-tests.sh`.

| Script | Usage | What it does |
|---|---|---|
| gate.sh | `gate.sh [lint\|types\|test\|build\|markers\|comments ...]` | Refuses a dirty tree (`GATE_ALLOW_DIRTY=1` overrides), an unknown step, or a missing `gate.test`. Runs the gate one line per step, a ≤ 30-line failure excerpt (`GATE_EXCERPT_LINES`), full log in `.gate/<step>.log`. Exit 0 all pass, 1 otherwise. From a worktree that predates project.md, it reads the main checkout's. |
| find-comments.sh | `find-comments.sh --base <ref>` or `find-comments.sh <file>...` | Prints `path:line: text` for every comment added since `<ref>`, or in the given files. Exit 1 when it finds one, 2 on bad usage. |
| log-event.sh | `log-event.sh <ID\|-> <event> <verdict> [--sha S] [--attempt N] [--category C]... [--signal TEXT]...` | Appends one JSON line to the main checkout's `vault/log.jsonl`. Up to 5 signals of 200 chars. Unknown events or categories exit 1 and list the valid ones. Prints `RETRO DUE` when a category recurs across slices. |
| guard.sh | PreToolUse hook | Exit 2 blocks the call and feeds the reason back. Fails closed without jq. Understands Claude Code, VS Code Copilot (its own tool names; it ignores the matcher, so the hook sees every call) and Cursor (`beforeShellExecution`, answered with allow/deny JSON). |
| lint.sh | PostToolUse hook | Formats the edited file, exit 2 with lint errors. Reads Claude Code's `file_path`, Copilot's `filePath` and Cursor's top-level `file_path`; Cursor ignores the exit code, so there errors surface at the gate. |
| checkpoint.sh | Stop hook | Commits progress on `slice/*` branches only (never main, a feature branch or a detached HEAD), inside worktrees too. Scans with `gitleaks git --staged` (v8.19+) or `gitleaks protect --staged` (older) and aborts on a finding. |
| session-start.sh | SessionStart hook | Injects session.md, live slices, git status and leftover worktrees; plain text, or `{"additional_context": ...}` for Cursor. Refreshes the AGENTS.md protocol block. |
| agents-md.sh | `agents-md.sh [project-dir]` | Writes the protocol into the project's AGENTS.md between its markers; leaves everything else in the file alone. |
| generate-agents.sh | `generate-agents.sh <copilot\|cursor> [dest]` | Emits derived agents (always overwritten, never hand-edit). Copilot gets an `orchestrator` whose roster is every agent in `agents/`; it isn't called "director" because that name means the main Claude Code session. |
| validate-manifests.sh | `validate-manifests.sh` | Checks agent and skill frontmatter, and that CLAUDE.md's Agents table matches `agents/`. |

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
This repo follows its own no-comments rule; CI runs `find-comments.sh` over every
script (test fixtures aside, since they are comment samples on purpose).

## Credits
The overall approach here — a skills-and-agents setup for Claude Code, driven
by ADRs, gates, and an autonomy dial — was learned from
[Matt Pocock's skills](https://github.com/mattpocock/skills). The general
engineering-practice skills under `skills/` (frontend-ui-engineering,
security-and-hardening, code-review-and-quality, and others not specific to
this protocol's own vault workflow) are sourced from
[Addy Osmani's agent-skills](https://github.com/addyosmani/agent-skills).
Thanks to both for making this work public.
