# Autonomous Engineering Setup for Claude Code

A lean, hardened multi-agent setup: 5 agents, 34 skills, mechanical guardrails,
git-backed resume (no memory files), a learning loop that turns repeated failures into fixes, a risk gate that scales controls to each change's risk, a codebase map with architecture fitness rules, and an autonomy dial you turn up only as trust is earned.
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
> /init-codebase       # one-time per project; asks for your lint/test/build commands
> /grill               # mandatory before any work — settles every human decision
```

After the grill, the Director dispatches the planner, shows you the slice table, and
builds. Nothing after the grill should need you unless a slice escalates.

## What's inside

| Path | What |
|---|---|
| CLAUDE.md | Global protocol — the main session IS the Director |
| agents/ | planner · builder · reviewer · auditor · retro (least-privilege tools, model-per-agent) |
| skills/ | protocol-native: grill · slice-planning · risk-gate · parallel-dispatch · architecture-review · learning-loop · test-speed · crap-hotspots · mutation-survivors · clean-diff · harden-diff · blast-radius · `/codebase-map` · brief-contract · `/init-codebase` · `/harvest` · `/create-verification-skill` · `/maintain-verification-skill` (opt-in, `/`-only: a project-local `verify-*` skill that lets the reviewer reach live-verified evidence) — plus a general engineering-practice library, a principles index (19 pstack principles, read on demand) and pstack's prose skills: unslop · technical-writing (docs/README/ADR work) (see Credits) |
| settings.json | Permission deny/ask lists + hooks on 6 events + env that keeps Claude Code on Windows in Git Bash |
| scripts/ | guard.sh (PreToolUse) · vault-guard.sh (Pre/PostToolUse, SubagentStop — restores Director-only files) · lint.sh (PostToolUse) · checkpoint.sh (Stop) · session-start.sh (SessionStart) · codebase-graph.py + graph-viewer.html (module/file/function graph, change impact, `arch` fitness check, drill-down HTML map) · crap-score.py (lizard + coverage report → CRAP lines for `gate.crap`) · mutation-report.py (mutation tool report → mutant lines for `gate.mutation`) · gate.sh (quiet lint/types/test/build runner + diff-scoped CRAP, mutation, TODO/FIXME, no-comments and architecture-rule checks) · find-comments.sh (the comment detector behind that check) · log-event.sh (the Director's structured log.jsonl writer) · risk-gate.sh (scores each slice's risk, judges builder spawns and merges) · approve-risk.sh (the human's approval command — refuses inside an agent) · check-plan.sh (the Director's lint for a planner draft: fields, "Actor can" titles, resolvable acyclic `depends_on`, `auditor_triggers` from a fixed list, gates as a verdict or `skip: <reason>`) · generate-agents.sh (Copilot/Cursor agents, install-time) · agents-md.sh (protocol block in a project's AGENTS.md, for Cursor/Copilot) |
| tests/ | Test harness for the hook scripts — run after any script edit; CI runs it too |
| evals/ | 16-task benchmark + scorecard — run before trusting, re-run after any manifest edit |

## The loop
grill (mandatory; settles every human decision) → planner (vertical slices, all
autonomous, each with a risk assessment) → risk gate (score, class, controls; critical
stops for a human) → per slice on its own branch:
builder (minimum necessary change, test-first) → gate.sh once (incl. `scope`) → reviewer
(cold eyes + slop checklist) → auditor (security surfaces, and every high/critical slice) →
risk check (+ human approval for high/critical) → merge + tag → Director harvests the story.
Failures resolve through 3 self-healing tiers. A slice that exhausts them, hits the
budget ceiling (10 builder/reviewer/auditor calls), or fails a merge twice **escalates**:
it halts, lands in `vault/flags/pending-review.md`, and goes back through the grill —
other slices keep going. Every 5 slices: architecture review.

## Learning loop
Every gate verdict goes into `vault/log.jsonl` through `log-event.sh`, with the CRITICAL
critique lines and a category attached when a gate fails. Tier 3 tiebreaks, escalations
and your corrections are logged the same way. There are no memory files and reasoning
trails die with the session; this log is append-only, so the failure signal survives.

Every 5 slices, alongside architecture review (code lens), the `retro` agent reads the
log since the last retro (process lens). It only reports a failure that recurred across
two or more slices. It names the rule that let the failure through and proposes the
strongest fix: a check that fails mechanically before more manifest text. Proposals go
to `pending-review.md`; nothing is applied without you. Accepted global fixes land in
this repo; re-run `./install.sh` and the eval the proposal names. If the same category
fails in two slices before the counter comes round, `log-event.sh` prints `RETRO DUE`
and the retro runs before the next builder. Run it by hand with `/learning-loop`.

## Risk gate
Risk decides autonomy. The planner rates every slice on five dimensions (blast radius,
reversibility, security, complexity, uncertainty; 0-4 each) and names its hazards, its
minimum necessary change (`scope`: the change, the files, behavior that must not change,
regressions to watch) and its rollback. `risk-gate.sh` turns that into a 0-100 score
deterministically: round((25·blast + 25·reversibility + 25·security + 10·complexity +
15·uncertainty) / 4).

| Score | Class | Required controls (cumulative) |
|---|---|---|
| 0-20 | low | gate PASS + reviewer APPROVED (autonomous) |
| 21-40 | moderate | + reviewer evidence unit-test-verified or live-verified |
| 41-60 | elevated | + deep tests (`gate.mutation` or live-verified, else a human merge approval); builder on the session model |
| 61-80 | high | + auditor CLEARED + a human approval of the merge, bound to its patch-id |
| 81-100 | critical | + a human authorization before any build, bound to the assessment and its safeguards |

A low score can't hide a serious hazard: data-loss and destructive operations are always
critical; auth, secrets, sensitive data, money, irreversible changes and security or
reversibility rated 4 are at least high; migrations, external side effects and new
dependencies are at least elevated. Auditor triggers raise the security rating (an auth
slice is at least high). Words in a slice's criteria that suggest a hazard (delete,
password, payment…) must be declared or ruled out with a reason, or check-plan.sh fails.
Thresholds and weights can be changed in `vault/risk-policy.json`. Only a human edits it;
agents are blocked from it, and a malformed policy fails closed. The floors can't be
configured away. See `skills/risk-gate/SKILL.md` for the rubric.

Enforcement is mechanical, not prose:
- **Before building** — guard.sh runs `risk-gate.sh check <ID> build` on every builder
  spawn: no recorded assessment, an assessment changed since it was recorded, a
  critical slice without a human authorization, a brief whose `RISK:` line names another
  class, or a sonnet builder on an elevated+ slice → the spawn is refused.
- **While building** — gate.sh's `scope` step fails any changed file outside
  `risk.scope.files`. The builder stops with SCOPE-EXPANSION; the Director logs it,
  re-rates the slice and records it again (`assess`). A higher class brings its controls
  (and invalidates approvals, which are tied to the assessment hash). A lower one needs a human
  `downgrade` approval, so reassessing can't be used to shed controls.
- **Before merging** — guard.sh runs `risk-gate.sh check <ID> merge` on any git command
  that would land `slice/<ID>` on main (merge, cherry-pick, rebase, pull, reset,
  update-ref, `branch -f`/`checkout -B` main, `push . x:main`). It reads the verdicts
  logged at the slice's current patch-id and the human approvals. Any gap blocks the merge.
- **Human approvals** — only `~/.claude/scripts/approve-risk.sh <authorize|merge|downgrade> <ID>`,
  run by you in your own terminal. It refuses without a TTY or inside an agent's shell
  (CLAUDECODE set), shows you what you're approving, and appends your decision (git
  email, assessment hash, patch-id) to `.git/donedonedone/approvals.jsonl`. guard.sh blocks
  every agent, the Director included, from writing that ledger or running the command;
  vault-guard.sh restores the ledger and the policy if any tool call changes them.
- **Audit** — every assessment, reassessment, scope expansion, rollback and verdict is a
  log.jsonl line (`risk`, `scope`, `rollback` events carry score and hash); the check
  refuses a log.jsonl that no longer starts with its committed content.
  `risk-gate.sh audit <ID>` prints one slice's trail. `risk-gate.sh calibrate` lists
  slices whose class was likely too low, for the retro. It never changes thresholds.

The dial below adds oversight on top; it never removes a control the risk class requires.

## Autonomy dial (`vault/project.md`)
- **supervised** (default) — every slice pauses for your approval after its gates
- **semi** — green slices merge; an escalation or an auditor finding pauses the queue
- **full** — everything green merges, flags reviewed async; sandbox/devcontainer only

At every setting, a high or critical slice still waits for your `approve-risk.sh`.

Promotion past supervised needs a 10-slice clean streak *and* a dated passing
scorecard in `evals/` — see the promotion rule in `evals/README.md`.

## Gate commands
`gate.sh` reads one line per step from `vault/project.md` (`/init-codebase` writes them):

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

A third built-in, `scope`, fails a slice branch whose diff leaves the slice's approved
`risk.scope.files` (see Risk gate); it reports SKIP off a `slice/<ID>` branch or
without a task tree. A fourth, `arch`, fails an import the diff adds that breaks a rule
in `vault/architecture.json`, or a new dependency cycle (see Codebase map); it reports
SKIP until that file exists on `main`.

Run `gate.sh test` for one step, no arguments for all ten (the six above plus `crap`, `mutation`, `scope` and `arch`); a misspelled step name is an
error, not a SKIP. Full logs land in `.gate/` (gitignored). The gate refuses to run on
uncommitted changes outside `vault/` so `GATE: PASS @ sha=<sha> patch_id=<id>` always
describes that SHA. The patch-id hashes the diff against the base outside `vault/`
(`none` when the diff is empty or the base is missing): a clean rebase keeps it, so
verdicts survive; any content change moves it, so verdicts go stale;
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
  plans them as their own slices from the architecture review or `/init-codebase`.
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

## Mutation
Coverage says a line ran. It doesn't say any test would notice if that line were wrong:
a test that calls the code and asserts nothing covers it fully. Mutation testing closes
that gap. The tool makes one small change at a time (`<` to `<=`, `+` to `-`, a return
value to its default) and runs the tests. A failing test **kills** the mutant; a mutant
every test **survives** is a bug the suite would ship. Two optional lines turn it on:

```markdown
- gate.mutation: rm -rf mutants && python3 -m mutmut run >/dev/null 2>&1 && python3 -m mutmut results --all true 2>/dev/null | python3 ~/.claude/scripts/mutation-report.py -
- gate.mutation.min: 80
```

- **`gate.mutation`** is any command that prints one line per mutant:
  `<path>:<line> <killed|survived|timeout|no-coverage> <description>`, path relative to
  the repo root. `timeout` counts as killed and `no-coverage` as survived. A valid run
  that made no mutants prints `no-mutants`. Other lines are ignored; output with no such
  line at all fails the step, so a broken command can't pass on nothing. CRLF output and
  backslash paths are accepted.
- The score is killed ÷ all, over the mutants on lines the diff against `main` adds.
  The step fails under **`gate.mutation.min`** (whole percent, default 80) and lists
  every survivor on those lines either way, so the reviewer sees them on a pass too.
  80 rather than 100 leaves room for equivalent mutants, changes no test can catch; the
  slice explains each one with a test named for why. Survivors on lines the diff doesn't
  touch don't block it; the `mutation-survivors` skill plans them as their own slices.
- It runs after `test` and `crap`; after a failed `test` it reports SKIP. Before the
  command runs, the gate writes the diff's files to `.gate/mutation.files` and exports
  its path as `GATE_MUTATION_FILES`, and the base as `GATE_BASE`, so a tool that takes
  a file list or a diff mutates only what the slice changed. The full output stays in
  `.gate/mutation.log`.
- Mutation runs are slow: every mutant is a test run. Scope the command to the diff
  where the tool allows it, and clear the tool's cache first, since a cached verdict
  from before the slice's new tests is wrong (mutmut keeps one in `mutants/`).
- Any command that prints that format works. The setup ships one adapter:
  **`mutation-report.py <report>`**, or `-` for `mutmut results` on stdin. It reads, by
  detecting the file:
  - the shared [mutation-testing-report-schema](https://github.com/stryker-mutator/mutation-testing-elements)
    JSON (Stryker for JS/TS, .NET and Scala; Infection for PHP; Mull for C/C++), with
    absolute paths made relative to `projectRoot`
  - PIT's `mutations.xml` (Java, Kotlin), with each class's package and source file
    matched to a file in the repo
  - cargo-mutants' `mutants.out/outcomes.json` (Rust)
  - Gremlins' `--output` JSON (Go)
  - mutmut 3's `results --all true` (Python), with each mutant traced to the line it
    changes through mutmut's `mutants/` copy
  Compile errors, run errors, unviable, ignored and skipped mutants are dropped; no
  test could have judged them. It needs Python 3 and nothing else.

### Per-stack setup
Every report or cache the command writes must be gitignored, or the next gate run
refuses the dirty tree. CI runs the first row on every push, against a sample project
in `tests/fixtures/mutation/python/`, through the real gate (`tests/mutation-stacks.sh`):
it must fail tests that run the code without asserting, naming each survivor's line,
and pass tests that pin the boundary. The adapter's parsing of every format is tested
from fixtures (`tests/mutation-report.sh`); the other rows' commands are not run in CI.

| Stack | `gate.mutation` | Gitignore |
|---|---|---|
| Python: mutmut 3 *(CI)* | `rm -rf mutants && python3 -m mutmut run >/dev/null 2>&1 && python3 -m mutmut results --all true 2>/dev/null \| python3 ~/.claude/scripts/mutation-report.py -`, with `[tool.mutmut] source_paths = ["src/"]` in pyproject.toml and pytest's `testpaths` set so it skips the copy in `mutants/` | `mutants/` |
| JS/TS: StrykerJS | `npx stryker run --reporters json && python3 ~/.claude/scripts/mutation-report.py reports/mutation/mutation.json` | `reports/`, `.stryker-tmp/` |
| Java: Maven + PIT | `mvn -q -B test-compile org.pitest:pitest-maven:mutationCoverage -DoutputFormats=XML -DtimestampedReports=false && python3 ~/.claude/scripts/mutation-report.py target/pit-reports/mutations.xml` | `target/` |
| Rust: cargo-mutants | `git diff "$GATE_BASE...HEAD" > .gate/diff.patch; cargo mutants --in-diff .gate/diff.patch; case $? in 0\|2\|3) python3 ~/.claude/scripts/mutation-report.py mutants.out/outcomes.json ;; *) exit 1 ;; esac` (exit 2 and 3 mean survivors and timeouts, which the gate judges) | `mutants.out*/` |
| Go: Gremlins | `gremlins unleash --diff "$GATE_BASE" --output .gate/gremlins.json && python3 ~/.claude/scripts/mutation-report.py .gate/gremlins.json` | |

The step is plain gate.sh, so it behaves the same under Claude Code, Cursor and
Copilot, including from PowerShell through Git Bash on Windows.

## Codebase map
`/codebase-map` (or `python3 ~/.claude/scripts/codebase-graph.py build`) turns the
committed tree into `.gate/graph.json` and a self-contained `.gate/graph.html`:
repository → module (directory) → file → function, with imports and importers both
ways, fan-in/fan-out, instability, complexity (lizard), churn (git log, 90 days),
test reach or measured coverage (`--coverage`, any format crap-score.py reads), and
cycles. Modules are colored by risk, and every highlight says why with its numbers
("`make_response()` has complexity 16 and the file changed 3 times in 90 days").
Click a module to see its dependencies and dependents, then drill into files and
functions. It's regenerated on demand, never committed, so it can't drift.

- **Change impact.** `codebase-graph.py impact --base main` prints a CHANGE IMPACT block
  (files, modules, direct and indirect dependents, tests in reach, cycles touched,
  estimated regression risk). The reviewer's blast-radius pass starts from it, then
  greps for what static imports miss.
- **Fitness rules.** Boundaries the human settles in `/grill` go in
  `vault/architecture.json`:

  ```json
  {"no_new_cycles": true,
   "forbid": [{"from": "src/domain/**", "to": "src/infra/**", "why": "ADR-004"}]}
  ```

  gate.sh's `arch` step reads the rules from `main` (a slice can't relax them on its
  branch) and fails only on violations the diff introduces, so legacy debt never
  blocks unrelated work. It shows up in the map instead.
- **Architecture review** runs the map first; its flags seed the review's candidates,
  which are confirmed by the deletion test before they become cards.
- **Limits.** Imports are found by regex for Python, JS/TS (relative paths), Go and
  Java/Kotlin. Other languages get complexity and churn without edges. Path aliases,
  dynamic imports and DI wiring are invisible. Callers are per file, not per function.
  Flags are signals for a human or reviewer to judge, not gate failures; only explicit
  rules fail the gate.

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
- **Subagent cold starts** — no bookkeeping agent: the Director records gates and
  harvests the story itself; the planner reads the codebase for decomposition so the Director's long-lived context
  doesn't; agents get file paths, not pasted contents.
- **Model choice** — builder drops to sonnet for small slices; reviewer is sonnet.
- **Always-loaded text** — the global CLAUDE.md is kept small (rarely-needed procedure
  lives in on-demand skills like parallel-dispatch) and is inert outside a vault project.
- **Resume** — the SessionStart hook injects live slices, git status and leftover
  worktrees in one go; git and task-tree.json are the only resume state.

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
  task-tree.json or log.jsonl; matching is
  case-insensitive, for macOS and Windows. A subagent shell command that mentions vault/
  at all must be plainly read-only (`cat`, `grep`, `jq`, `git diff/log/show`… with no
  redirect, substitution or `--output`), and log-event.sh is off limits.
- A builder, reviewer or auditor spawn (Agent or Task tool) whose prompt lacks any of
  the brief-contract headers (GOAL, SCOPE, ACCEPTANCE, VERIFY, FORBIDDEN, REPORT,
  STANDING, each at the start of a line) is refused, naming the missing ones.
- In a project with vault/task-tree.json, a builder spawn needs a `SLICE: <ID>` line
  naming a slice there. When that slice's `auditor_triggers` is non-empty, the brief's
  STANDING must name the harden-diff skill; a slice without the field fails closed.
- The risk gate (see Risk gate): builder spawns and every git route that lands a
  `slice/<ID>` on main run `risk-gate.sh check`. No agent may write
  `.git/donedonedone/approvals.jsonl` or `vault/risk-policy.json`, or run
  `approve-risk.sh` or `vault-guard.sh`. Subagents may not run `risk-gate.sh`.
- The reviewer's Chrome tools (claude-in-chrome navigate and tabs_create) may only open
  http(s) on localhost, 127.0.0.1, [::1], *.local, *.localhost or *.test; userinfo,
  numeric-IP spellings, non-ASCII hosts and whitespace or control characters are refused.
  Run claude-in-chrome in a dedicated, signed-out Chrome profile all the same.

**2. vault-guard.sh — undoes what got through, by content, not by syntax.** Human-only
files (the approvals ledger and `vault/risk-policy.json`) are restored after any tool
call that changed them, the Director's included. A human's edits between calls are
kept, and approve-risk.sh re-snapshots the ledger after it writes. It also snapshots
the main checkout's task-tree.json and log.jsonl (in `.git/`, at
session start and after each Director call that may touch them). After every subagent
tool call, and when a subagent stops, any change to those files is restored from the
snapshot and the subagent is told. A
change that turns up during a Director call that shouldn't touch vault/ is reported to
the Director and then accepted as theirs. gate.sh adds the worktree case: a slice branch
that changes those files fails the gate before a squash-merge carries it into main.

What this still doesn't stop: code the agent writes to a file and then runs (a script or
a test can do anything the user can — including allocating a pseudo-terminal, unsetting
CLAUDECODE and driving approve-risk.sh), and the narrow window where a subagent's write
lands while a Director call that touches vault/ is in flight. A human approval is
therefore as strong as the sandbox it runs in. Every approval in the ledger names the
approver's git email, so read the ledger (`risk-gate.sh audit <ID>`) before trusting a
merge you didn't watch. Commands still run as
you, so run `autonomy: full` only in a sandbox.

Also:
- reviewer/auditor have no write tools at all; the planner's Write is scoped to its
  draft by its manifest (and the hooks above)
- Checkpoints auto-commit only on `slice/*` branches (main is always green)
- gitleaks scan before every checkpoint commit
- `autonomy: full` is only legal in a sandbox; new projects start `supervised`

## Upgrading an existing install
Pull, re-run `./install.sh`. It retires old `~/.claude/commands/init-vault.md` and
`harvest.md` (now skills) to `.bak-<timestamp>` copies. /init-vault is now
/init-codebase: install.sh moves a stale `~/.claude/skills/init-vault/` to
`~/.claude/init-vault-skill.bak-<timestamp>/`, outside skills/ so it stops loading;
the project's `vault/` directory keeps its name. If it kept your settings.json
and left a `settings.json.new-<timestamp>`, merge its hooks: guard.sh now runs on every
tool (no matcher), and vault-guard.sh runs on PreToolUse, PostToolUse,
PostToolUseFailure and SubagentStop. Without them the vault restore layer is off.
In each existing project:
1. Add `gate.*` lines to `vault/project.md` (see Gate commands). `gate.test` is now
   required — the gate fails without it (`- gate.test: none` if there are no tests).
   Commit before running the gate: it now refuses uncommitted changes outside `vault/`.
2. Add `.gate/` and `vault/plan-draft.json` to `.gitignore`.
   The vault memory layer is gone: install.sh backs up a stale scribe agent and
   compaction skill (Claude, Copilot and Cursor copies) as `.bak-<timestamp>` outside
   the live folders, and session-start.sh prints a hint while `vault/memory` or
   `vault/handoffs` remains. Re-run `/init-codebase`: on a clean tree it `git rm -r`s
   them in their own commit (history keeps them).
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
   a baseline of the hotspots already there. Same for `gate.mutation` (see Mutation)
   and the `mutation-survivors` skill.
9. On Windows, install from a fresh clone and merge settings.json's new `env` block,
   which keeps Claude Code in Git Bash (see Windows).
10. Risk gate: every live slice in `task-tree.json` needs a `risk` assessment before its
    next builder spawn or merge (see Risk gate). Add one to each (the planner can draft
    them), run `~/.claude/scripts/risk-gate.sh assess <ID>`, and check
    `risk-gate.sh pending`. Builder briefs need a `RISK: <class>` line. Slices already
    shipped need nothing. The risk gate stays off in projects without a vault/.

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
  live slices, it can read `vault/task-tree.json` and `git log` itself.
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
global `~/.claude/CLAUDE.md` instead. `/init-codebase` runs `~/.claude/scripts/agents-md.sh`,
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
`tests/crap-stacks.sh` (Python, React and Java end to end); mutation-report.py's in
`tests/mutation-report.sh` (formats) and `tests/mutation-stacks.sh` (Python with mutmut
end to end); codebase-graph.py's in `tests/codebase-graph.sh`.

| Script | Usage | What it does |
|---|---|---|
| crap-score.py | `crap-score.py <coverage file> [-x <glob>]... [paths]` | Prints `<path>:<start>-<end> <score> <name>` per function for `gate.crap`: lizard complexity joined with LCOV, Cobertura, JaCoCo or coverage.py JSON line coverage. Unknown report format or missing lizard exits non-zero. |
| codebase-graph.py | `codebase-graph.py build [--rev R] [--days N] [--coverage F] [--rules F] [--out D]` · `impact (--base R \| <files>…)` · `check --rules F --base R` | `build` writes `graph.json` + `graph.html` (from graph-viewer.html) to `.gate/` and prints a ≤ 15-line summary; `impact` prints the CHANGE IMPACT block; `check` exits 1 listing each forbidden import or new module cycle edge HEAD adds over the base, and backs gate.sh's `arch` step. Reads committed trees only (`git cat-file`). Bad usage exits 2. |
| mutation-report.py | `mutation-report.py <report \| ->` | Prints `<path>:<line> <killed\|survived\|timeout\|no-coverage> <description>` per mutant for `gate.mutation`, or `no-mutants`: reads mutation-testing-report-schema JSON, PIT XML, cargo-mutants outcomes.json, Gremlins JSON, or mutmut 3 results (`-` for stdin). Unknown format exits non-zero. |
| gate.sh | `gate.sh [lint\|types\|test\|build\|crap\|mutation\|markers\|comments\|scope\|arch ...]` or `gate.sh test -- <targets>` | Refuses a dirty tree (`GATE_ALLOW_DIRTY=1` overrides), an unknown step, or a missing `gate.test`. With `-- <targets>`, runs only those tests through `gate.test.focus` and ends `FOCUSED:`, never `GATE:`. Flags a passing test step slower than `gate.test.budget`. Fails a function the diff touches whose `gate.crap` score is over `gate.crap.max`, and a diff whose added lines' mutants score under `gate.mutation.min`. Runs the gate one line per step, a ≤ 30-line failure excerpt (`GATE_EXCERPT_LINES`), full log in `.gate/<step>.log`. Exit 0 all pass, 1 otherwise. From a worktree that predates project.md, it reads the main checkout's. |
| find-comments.sh | `find-comments.sh --base <ref>` or `find-comments.sh <file>...` | Prints `path:line: text` for every comment added since `<ref>`, or in the given files. Exit 1 when it finds one, 2 on bad usage. |
| log-event.sh | `log-event.sh <ID\|-> <event> <verdict> [--sha S] [--patch-id P] [--evidence E] [--attempt N] [--score 0-100] [--hash H] [--category C]... [--signal TEXT]...` | Appends one JSON line to the main checkout's `vault/log.jsonl`. Events include `risk`, `scope` and `rollback`. Up to 5 signals of 200 chars. Unknown events, categories or evidence rungs, or a score outside 0-100, exit 1 and list the valid ones. Prints `RETRO DUE` when a category recurs across slices. |
| risk-gate.sh | `risk-gate.sh lint\|table <plan>` · `score [file\|-]` · `show\|assess\|audit <ID>` · `check <ID> build\|merge` · `scope [ID]` · `pending` · `calibrate` | Scores a slice's `risk` (0-100, class, floors, controls) the same way every time. `assess` records it in log.jsonl; `check` exits 1 listing every missing control and ends `RISK: PASS\|FAIL`; `scope` backs gate.sh's step; `pending` feeds the SessionStart hook. Exit 2 (fail closed) without jq or on a malformed `vault/risk-policy.json`. |
| approve-risk.sh | `approve-risk.sh <authorize\|merge\|downgrade> <ID>` | The human's approval. Refuses without a TTY or with CLAUDECODE set; shows the assessment (merge: diffstat and controls); records the typed decision in `.git/donedonedone/approvals.jsonl`. Typing anything other than the prompt records a denial; an empty line cancels. |
| guard.sh | PreToolUse hook (every tool) | Exit 2 blocks the call and feeds the reason back. Fails closed without jq or on a malformed payload. Understands Claude Code, VS Code Copilot (its own tool names; an unknown tool carrying a command is treated as a shell call) and Cursor (`beforeShellExecution` and `beforeReadFile`, answered with allow/deny JSON). See Safety model. |
| vault-guard.sh | PreToolUse, PostToolUse, PostToolUseFailure, SubagentStop hook; `vault-guard.sh --snapshot` | Restores task-tree.json and log.jsonl in the main checkout when a subagent changes them (exit 2 tells it why); warns the Director about unexplained changes. Snapshots live in `.git/skeletoncrew-vault-guard/`. Claude Code only — other tools' payloads don't name the subagent. |
| lint.sh | PostToolUse hook | Formats the edited file, exit 2 with lint errors. Reads Claude Code's `file_path`, Copilot's `filePath` and Cursor's top-level `file_path`; Cursor ignores the exit code, so there errors surface at the gate. |
| checkpoint.sh | Stop hook | Commits progress on `slice/*` branches only (never main, a feature branch or a detached HEAD), inside worktrees too. Scans with `gitleaks git --staged` (v8.19+) or `gitleaks protect --staged` (older) and aborts on a finding. |
| session-start.sh | SessionStart hook | Injects live slices, slices the risk gate is holding, git status and leftover worktrees (plus a one-line migration hint while vault/memory or vault/handoffs exists; deletes nothing); plain text, or `{"additional_context": ...}` for Cursor. Refreshes the AGENTS.md protocol block. |
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
