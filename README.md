# Autonomous Engineering Setup for Claude Code

A lean, hardened multi-agent setup: 6 agents, 25 skills, mechanical guardrails,
session-surviving memory, a learning loop that turns repeated failures into fixes, and an autonomy dial you turn up only as trust is earned.
Built for Claude Code; also works with GitHub Copilot in VS Code and with Cursor (see below).

Built on: vertical slices (tracer bullets) · red-green-refactor TDD · the test pyramid ·
deep modules and the deletion test (Ousterhout) · ADRs · OWASP · Conventional Commits ·
branch-per-slice trunk discipline · mechanisms-over-instructions (hooks + git, not hope).

## Quick start

macOS or Linux:

```bash
git clone https://github.com/restierecon/donedonedone ~/claude-setup
cd ~/claude-setup && ./install.sh
brew install jq gitleaks semgrep   # guardrail dependencies; on Linux, your package manager
```

Windows: install [Git for Windows](https://git-scm.com/downloads/win), then run the same
clone and `./install.sh` in **Git Bash**, or work inside WSL, which is Linux. Guardrail
dependencies: `winget install jqlang.jq` and `winget install Gitleaks.Gitleaks`. Each
tool needs one setting there; see [Windows](#windows).

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
| skills/ | protocol-native: grill · slice-planning · parallel-dispatch · compaction · architecture-review · learning-loop · test-speed · crap-hotspots · `/init-vault` · `/harvest` — plus a general engineering-practice library and pstack's prose skills: unslop · technical-writing (docs/README/ADR work) (see Credits) |
| settings.json | Permission deny/ask lists + hooks on 6 events + env that keeps Claude Code on Windows in Git Bash |
| scripts/ | guard.sh (PreToolUse) · vault-guard.sh (Pre/PostToolUse, SubagentStop — restores Director-only files) · lint.sh (PostToolUse) · checkpoint.sh (Stop) · session-start.sh (SessionStart) · crap-score.py (lizard + coverage report → CRAP lines for `gate.crap`) · gate.sh (quiet lint/types/test/build runner + diff-scoped CRAP, TODO/FIXME and no-comments checks) · find-comments.sh (the comment detector behind that check) · log-event.sh (the Director's structured log.jsonl writer) · generate-agents.sh (Copilot/Cursor agents, install-time) · agents-md.sh (protocol block in a project's AGENTS.md, for Cursor/Copilot) |
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

Run `gate.sh test` for one step, no arguments for all seven (the six above plus `crap`, see CRAP); a misspelled step name is an
error, not a SKIP. Full logs land in `.gate/` (gitignored). The gate refuses to run on
uncommitted changes outside `vault/` so `GATE: PASS @ <sha>` always describes that SHA;
`GATE_ALLOW_DIRTY=1` overrides it for a local look.

## Test speed
A slow suite costs every slice twice, since the builder and the Director each run it
in full, and every later slice too. Two optional lines keep that cost down:

```markdown
- gate.test.focus: python -m pytest -q {}
- gate.test.budget: 300
```

- **`gate.test.focus`** lets the builder run only the tests it is working on, on every
  red-green loop: `gate.sh test -- tests/test_notes.py` puts the targets where `{}` is
  (each one shell-quoted; with no `{}` they're appended). A focused run checks nothing
  else and runs on an uncommitted tree. It ends with `FOCUSED: PASS` or `FOCUSED: FAIL`,
  never `GATE:`, so it can't be passed off as a verdict. Without the line,
  `gate.sh test -- …` is an error, not a silent full-suite run.
- **`gate.test.budget`** is in seconds. A full test step that passes but takes longer
  prints `test PASS (612s) — over gate.test.budget (300s)`. The gate still passes,
  because the slice may not be what slowed the suite. The Director opens one
  pending-review entry and the `test-speed` skill takes it from there: measure,
  classify, grill, slice. A budget that isn't whole seconds fails before the suite runs.

The builder's rules keep new tests fast: each criterion is proven at the lowest layer
that can prove it, with at most one browser-driven test per slice; tests never wait on
a real clock; expensive setup is built once per run and reset per test. The reviewer
checks all three and, when `gate.test.focus` is set, times the slice's own tests.

## CRAP
CRAP (Change Risk Anti-Patterns) scores each function by complexity and missing
coverage: `comp² × (1 − cov)³ + comp`, where `comp` is cyclomatic complexity and `cov`
the covered fraction. A fully covered function scores its complexity; an untested one
roughly its complexity squared. The metric and the threshold of 30 come from crap4j
(Alberto Savoia and Bob Evans). Two optional lines turn it on:

```markdown
- gate.crap: python3 ~/.claude/scripts/crap-score.py coverage.lcov src
- gate.crap.max: 30
```

- **`gate.crap`** is any command that prints one line per function:
  `<path>:<start>-<end> <score> <name>`, path relative to the repo root. Other lines
  are ignored; output with no such line at all fails the step, so a broken command
  can't pass on nothing. A line with only `<start>` counts as touched whenever its file
  is in the diff. CRLF output and backslash paths are accepted.
- The step fails only for functions the diff against `main` touches (an added line
  inside `<start>-<end>`) that score over **`gate.crap.max`** (default 30, decimals
  allowed). Existing hotspots don't block unrelated slices; the `crap-hotspots` skill
  plans them as their own slices from the architecture review or `/init-vault`.
- It runs right after `test`, so the command can read the coverage file the test
  command just wrote; after a failed `test` it reports SKIP, since that coverage is
  stale. The full output stays in `.gate/crap.log` for the reviewer, which NITs touched
  functions over half the max.
- Any command that prints that format works. The setup ships one:
  **`crap-score.py <coverage file> [-x <glob>]... [source paths]`**. It takes each
  function's cyclomatic complexity and line range from
  [lizard](https://github.com/terryyin/lizard) (`pip install lizard`; covers Java,
  JavaScript/TypeScript/JSX/TSX, Python and ~25 more languages) and its coverage from the
  report your tests already write: LCOV, Cobertura XML, JaCoCo XML or coverage.py JSON,
  detected from the file. It needs Python 3 and lizard, and nothing else.
  - Coverage is **line** coverage over the function's own lines. It leaves out the first
    line (a Python `def` runs at import even when the body never does) and the lines of
    any function nested inside (a React component's handlers are scored on their own).
    crap4j used path coverage, so scores here can be a little lower on branchy one-liners.
  - A file the coverage report never mentions counts as untested.
  - Report paths are matched to source files by their trailing path, so absolute paths
    (Jest), Windows paths, and JaCoCo's package paths (`shop/Pricing.java`) all resolve.
  - It skips `node_modules`, `target`, `build`, `dist`, `coverage`, virtualenvs and
    `vault/`. Add `-x` for anything else (test files that coverage leaves out).

### Per-stack setup
Every report file the test command writes must be gitignored. Otherwise the next gate
run sees an untracked file and refuses the dirty tree. On Windows, write `python` or
`py -3` in place of `python3`. CI runs the first three on every push, against sample
projects in `tests/fixtures/crap/`, through the real gate (`tests/crap-stacks.sh`).
Each one must pass a change to tested code and fail an untested complexity-6 function
at CRAP 42.

| Stack | `gate.test` | `gate.crap` |
|---|---|---|
| Python: pytest + coverage.py *(CI)* | `python3 -m coverage run -m pytest -q && python3 -m coverage lcov -q -o coverage.lcov` | `python3 ~/.claude/scripts/crap-score.py coverage.lcov src` |
| React: Vitest *(CI)* | `npx vitest run --coverage`, with `coverage: { provider: "v8", reporter: ["lcov"], include: ["src/**"] }` in vitest.config | `python3 ~/.claude/scripts/crap-score.py coverage/lcov.info -x '*.test.*' src` |
| Java: Maven + JaCoCo *(CI)* | `mvn -q -B test`, with jacoco-maven-plugin's `prepare-agent` and its `report` goal bound to the `test` phase (see `tests/fixtures/crap/java/pom.xml`) | `python3 ~/.claude/scripts/crap-score.py target/site/jacoco/jacoco.xml src/main/java` |
| Python: pytest-cov | `python3 -m pytest -q --cov=src --cov-report=lcov:coverage.lcov` | as above |
| React: Jest | `npx jest --coverage --coverageReporters=lcov` | `python3 ~/.claude/scripts/crap-score.py coverage/lcov.info -x '*.test.*' src` |
| Java: Gradle + JaCoCo | `./gradlew test jacocoTestReport`, with `jacocoTestReport { reports { xml.required = true } }` | `python3 ~/.claude/scripts/crap-score.py build/reports/jacoco/test/jacocoTestReport.xml src/main/java` |

The last three rows write the same report formats as the CI-tested rows. Their
commands are not run in CI.

The step is plain gate.sh, so it behaves the same under Claude Code, Cursor and
Copilot, including from PowerShell through Git Bash on Windows.

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
Two layers, because no pattern match over shell text can be complete (a variable, a
glob or a script file hides what a command does):

**1. guard.sh — blocks before the call runs** (PreToolUse, every tool; fails closed when
jq is missing, the payload isn't JSON, or a field has the wrong type).
- It matches both the raw command and a normalized one: quotes and backslashes stripped,
  lowercased (macOS and Windows resolve `RM` to `rm`), `/bin/rm` → `rm`, `rm.exe` → `rm`,
  a drive path like `C:\Users` or `C:/` → an absolute path, and git's global options
  (`-C dir`, `-c k=v`, `--git-dir`…) removed. So `g""it -C . reset --hard` and
  `rm -rf C:/` are caught.
- Blocked: the settings.json Bash denies, repeated here because Cursor and Copilot never
  read settings.json (`git reset --hard`, `git clean -f`, force pushes, `sudo`,
  `chmod 777`, DROP/TRUNCATE), plus remote branch deletion (`--delete`, `:branch`,
  `--mirror`), `git checkout/restore .`, forced checkouts, `stash drop/clear`,
  deleting main, history rewrites (`filter-branch`/`filter-repo`) and `--no-verify`.
- Recursive `rm`, and `find -delete`/`-exec rm`, on `/`, an absolute path, `~`, `.`, `..`
  or a `$VARIABLE` are blocked, however the flags are spelled or ordered. Relative
  `rm -rf ./build` stays allowed there (settings.json still denies it under Claude Code).
- Anything that hides the real command is blocked: a pipe into a shell, `eval`, a
  command substitution run as the command, `sh -c` with a substitution, and a
  destructive git command whose arguments contain a `$variable`.
- Secret files (`.env*` except `.example/.sample/.template/.dist`, `*.pem`, `*.key`, ssh
  keys, `secrets/`) are blocked for every tool and in shell commands, including Cursor's
  `beforeReadFile`. `cp .env.example .env` and `.gitignore` edits stay allowed.
- Subagents (identified by the hook's `agent_id`) can't Write/Edit/NotebookEdit
  task-tree.json or log.jsonl, or session.md unless they are the scribe; matching is
  case-insensitive, for macOS and Windows. A subagent shell command that mentions vault/
  at all must be plainly read-only (`cat`, `grep`, `jq`, `git diff/log/show`… with no
  redirect, substitution or `--output`), and log-event.sh is off limits.

**2. vault-guard.sh — undoes what got through, by content, not by syntax.** It snapshots
the main checkout's task-tree.json, log.jsonl and memory/session.md (in `.git/`, at
session start and after each Director call that may touch them). After every subagent
tool call, and when a subagent stops, any change to those files is restored from the
snapshot and the subagent is told. Only the scribe's session.md change is kept. A
change that turns up during a Director call that shouldn't touch vault/ is reported to
the Director and then accepted as theirs. gate.sh adds the worktree case: a slice branch
that changes those files fails the gate before a squash-merge carries it into main.

What this still doesn't stop: code the agent writes to a file and then runs (a script or
a test can do anything the user can), and the narrow window where a subagent's write
lands while a Director call that touches vault/ is in flight. Commands still run as
you, so run `autonomy: full` only in a sandbox.

Also:
- reviewer/auditor have no write tools at all; the planner's Write is scoped to its
  draft by its manifest (and the hooks above)
- Checkpoints auto-commit only on `slice/*` branches (main is always green)
- gitleaks scan before every checkpoint commit
- `autonomy: full` is only legal in a sandbox; new projects start `supervised`

## Upgrading an existing install
Pull, re-run `./install.sh`. It retires old `~/.claude/commands/init-vault.md` and
`harvest.md` (now skills) to `.bak-<timestamp>` copies. If it kept your settings.json
and left a `settings.json.new-<timestamp>`, merge its hooks: guard.sh now runs on every
tool (no matcher), and vault-guard.sh runs on PreToolUse, PostToolUse,
PostToolUseFailure and SubagentStop. Without them the vault restore layer is off.
In each existing project:
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
7. Add `gate.test.focus` and `gate.test.budget` (see Test speed). Without `focus`,
   builders rerun the whole suite on every red-green loop. If the suite is already
   over budget, run the `test-speed` skill to plan the fix.
8. Optionally add `gate.crap` (see CRAP), then run the `crap-hotspots` skill once for
   a baseline of the hotspots already there.
9. On Windows, install from a fresh clone and merge settings.json's new `env` block,
   which keeps Claude Code in Git Bash (see Windows).

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
- `~/.claude/settings.json` hooks → run by VS Code too once you turn on
  `chat.useClaudeHooks` (off by default), **with one caveat**: VS Code sends different
  tool names/property casing than Claude Code and ignores the `matcher` field (every
  hook fires on every tool call). `guard.sh` and `lint.sh` normalize both vocabularies
  so the guardrails still fire correctly either way; the named tests in
  `tests/run-tests.sh` pin each mapping.

What doesn't carry over as-is: VS Code reads user-level agents from both
`~/.claude/agents` and `~/.copilot/agents`, so you may see each agent listed twice.
`install.sh` runs `scripts/generate-agents.sh copilot` to translate every agent in
`agents/` into VS Code's native format at `~/.copilot/agents/`, plus a new `orchestrator` agent
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
- `~/.cursor/hooks.json`: the same scripts on Cursor's events. `beforeShellExecution` and
  `beforeReadFile` → guard.sh (answers with Cursor's allow/deny JSON), `afterFileEdit` → lint.sh,
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
- **No hooks on Windows.** See Windows below.

## Windows
Every script is bash, so on Windows the setup runs in Git Bash (from
[Git for Windows](https://git-scm.com/downloads/win)) or in WSL. WSL is Linux and needs
nothing below. CI runs the whole test harness on Windows (Git Bash) and macOS
(`/bin/bash` 3.2) as well as Linux.

- **Install** from Git Bash, from a fresh clone: `.gitattributes` keeps the scripts LF,
  and an older clone checked out with Git's default CRLF line endings can't run them.
- **Your projects** can stay CRLF. gate.sh strips the `\r` that Git for Windows leaves
  on every `gate.*` line in `vault/project.md`.
- **Claude Code** uses Git Bash for its Bash tool when Git for Windows is installed. Set
  the path explicitly, since hooks have been reported to fall back to cmd.exe without it.
  In `~/.claude/settings.json`:
  `"env": {"CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe"}`.
  This setup's settings.json also turns Claude Code's PowerShell tool off
  (`CLAUDE_CODE_USE_POWERSHELL_TOOL: "0"`): guard.sh reads bash, so a command run
  through PowerShell would skip it.
- **Copilot in VS Code** runs agent commands in PowerShell unless its chat terminal is
  set to Git Bash:
  `"chat.tools.terminal.terminalProfile.windows": {"path": "C:\\Program Files\\Git\\bin\\bash.exe"}`.
- **Cursor**'s agent runs PowerShell on Windows whatever your default terminal is (per
  Cursor's forum; its Legacy Terminal Tool setting is the reported workaround).
- **From PowerShell**, a script goes through Git Bash. The generated Cursor and Copilot
  agents and the AGENTS.md block tell the agents how. CI runs this form from PowerShell 7
  and Windows PowerShell 5.1:
  `& "$env:ProgramFiles\Git\bin\bash.exe" -c '~/.claude/scripts/gate.sh test -- tests/test_notes.py'`

Known gaps on Windows:
- **No hooks under Cursor or Copilot.** Both start hook commands with Windows shells
  there (Cursor through PowerShell), and those can't execute a `.sh` file, so guard.sh,
  vault-guard.sh, lint.sh and checkpoint.sh don't fire. gate.sh, the agents and the
  skills still work. For the guardrails too, open the project in WSL: hooks then run on
  Linux.
- **guard.sh reads bash, not PowerShell or cmd.** It knows `rm.exe` and `rm -rf C:/`,
  but not `Remove-Item -Recurse` or `rd /s`. Under Claude Code, keeping the PowerShell
  tool off covers this; under Cursor and Copilot there are no hooks to begin with.

## AGENTS.md (Cursor and Copilot)
Cursor and GitHub Copilot both read a project's `AGENTS.md`; Claude Code reads the
global `~/.claude/CLAUDE.md` instead. `/init-vault` runs `~/.claude/scripts/agents-md.sh`,
which writes the protocol into AGENTS.md between
`<!-- skeletoncrew:protocol:begin … -->` and `<!-- skeletoncrew:protocol:end -->`.
Anything else in the file is yours and is never touched. The session-start hook rewrites
the block whenever `~/.claude/CLAUDE.md` changes, so upgrades propagate — commit the diff.

Every CRAP rule sits where all three tools read it: gate.sh, the generated agents,
and the protocol block; the skill is named by its path so a tool without a skill
loader can open it.

This also reaches Copilot surfaces that never see `~/.claude/`: the cloud coding agent
and the CLI get the protocol text, but not gate.sh, the hooks, or the agents, so there it
is guidance only.

VS Code reads both files: `~/.claude/CLAUDE.md` (`chat.useClaudeMdFile`, on by default)
and AGENTS.md, so in a vault project the protocol loads twice. To avoid paying for it
twice, turn off `chat.useClaudeMdFile`. Nothing is lost: the protocol only applies in
vault projects, and every vault project carries AGENTS.md.

## Scripts
Installed to `~/.claude/scripts/`. Each one's behavior is pinned by a named test in
`tests/run-tests.sh`; crap-score.py's in `tests/crap-score.sh` (formats) and
`tests/crap-stacks.sh` (Python, React and Java end to end).

| Script | Usage | What it does |
|---|---|---|
| crap-score.py | `crap-score.py <coverage file> [-x <glob>]... [paths]` | Prints `<path>:<start>-<end> <score> <name>` per function for `gate.crap`: lizard complexity joined with LCOV, Cobertura, JaCoCo or coverage.py JSON line coverage. Unknown report format or missing lizard exits non-zero. |
| gate.sh | `gate.sh [lint\|types\|test\|build\|crap\|markers\|comments ...]` or `gate.sh test -- <targets>` | Refuses a dirty tree (`GATE_ALLOW_DIRTY=1` overrides), an unknown step, or a missing `gate.test`. With `-- <targets>`, runs only those tests through `gate.test.focus` and ends `FOCUSED:`, never `GATE:`. Flags a passing test step slower than `gate.test.budget`. Fails a function the diff touches whose `gate.crap` score is over `gate.crap.max`. Runs the gate one line per step, a ≤ 30-line failure excerpt (`GATE_EXCERPT_LINES`), full log in `.gate/<step>.log`. Exit 0 all pass, 1 otherwise. From a worktree that predates project.md, it reads the main checkout's. |
| find-comments.sh | `find-comments.sh --base <ref>` or `find-comments.sh <file>...` | Prints `path:line: text` for every comment added since `<ref>`, or in the given files. Exit 1 when it finds one, 2 on bad usage. |
| log-event.sh | `log-event.sh <ID\|-> <event> <verdict> [--sha S] [--attempt N] [--category C]... [--signal TEXT]...` | Appends one JSON line to the main checkout's `vault/log.jsonl`. Up to 5 signals of 200 chars. Unknown events or categories exit 1 and list the valid ones. Prints `RETRO DUE` when a category recurs across slices. |
| guard.sh | PreToolUse hook (every tool) | Exit 2 blocks the call and feeds the reason back. Fails closed without jq or on a malformed payload. Understands Claude Code, VS Code Copilot (its own tool names; an unknown tool carrying a command is treated as a shell call) and Cursor (`beforeShellExecution` and `beforeReadFile`, answered with allow/deny JSON). See Safety model. |
| vault-guard.sh | PreToolUse, PostToolUse, PostToolUseFailure, SubagentStop hook; `vault-guard.sh --snapshot` | Restores task-tree.json, log.jsonl and session.md in the main checkout when a subagent changes them (exit 2 tells it why); warns the Director about unexplained changes. Snapshots live in `.git/skeletoncrew-vault-guard/`. Claude Code only — other tools' payloads don't name the subagent. |
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
Several mechanisms are learned from
[Lauren Tan's pstack](https://github.com/backnotprop/pstack): the brief
contract and refuse-to-spawn rule, SHA- and patch-id-keyed gate verdicts with
an evidence ladder, plan linting, skip-with-reason, and the throughput
checkpoint before parallel waves. Skills imported or adapted from pstack
(blast-radius, the verification skills, principles, unslop and
technical-writing) are used under MIT; each folder carries pstack's LICENSE.
Thanks to all of them for making this work public.
