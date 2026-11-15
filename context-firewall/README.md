# Context firewall (`tbv`)

Noisy tool output (test runs, diffs, searches, builds, installs, logs) is the biggest
avoidable cost in an agent's context window. The context firewall sits between a shell
command and the model:

```
command ─▶ raw stdout/stderr ─▶ artifact store (.tbv/, kept in full)
                                   │
                                   ▼
              classify ─▶ compress ─▶ deduplicate ─▶ budget ─▶ model
                                                               │
                                       tbv artifact <id> … ◀───┘ (asks for more)
```

The rule it never breaks: **compression changes the representation, never the
information.** The full output is stored before anything is compressed. The compact view
only selects, groups and counts lines from that output. Anything left out is named,
together with the exact command that retrieves it.

Python 3.8+ standard library only. No RTK, no network, no database, no new runtime.
It works from bash, Git Bash, PowerShell 5.1/7 and cmd.

## What the model sees

```
[tbv] test | art-2cb9dfecf0 | exit 1 | pytest/high | ~1.7k->298 tok est
TEST RESULT
Status: FAILED
Passed: 60  Failed: 3  Skipped: 1
FAILURES
1. test_session_refresh
   test_auth.py:15
   E       AssertionError: assert 'abc-r' == 'abc-refreshed'
   (raw L73-83; --failure 1)
...
[tbv] full output: ~/.claude/scripts/tbv artifact art-2cb9dfecf0 [--section NAME | --lines A-B | --raw]
```

The header carries the provenance: output type, artifact id, exit code, which parser
produced the view and how confident it is (`high` = a known format was parsed, `low` =
generic head/tail/error-line view), the mode if it isn't `balanced`, and estimated
tokens before and after (characters / 4, so treat them as estimates).

Output that is already small (≤ 400 estimated tokens in balanced mode) passes through
untouched. So does source code (`cat`, `head`, `Get-Content` … of a source file), and so
does any output the firewall can't make smaller.

## How it is wired into tbv

| Path | When | What |
|---|---|---|
| `PreToolUse` hook (`~/.claude/scripts/tbv pre`) | A Bash call that is **one simple command** of a compressible type (tests, builds, linters, `git diff/log/status`, `rg`/`grep`, `find`/`tree`/`ls -R`) | Rewrites it to `tbv run --session <id> -- <the same command>`, so the command's own output is already compact. This is the only path that works for a **failing** command, because Claude Code reports a non-zero exit through `PostToolUseFailure`, which can't replace output. |
| `PostToolUse` hook (`~/.claude/scripts/tbv hook`) | Every other Bash/PowerShell call that succeeds (pipes, `&&` chains, unknown tools) | Stores the result and replaces what the model sees via `updatedToolOutput`, keeping the same shape (`stdout` = the compact view, `stderr` = ""). It also records Edit/Write targets as the session's active files, which ranking uses. |
| `gate.sh` failure excerpts | A gate step fails | The ≤ `GATE_EXCERPT_LINES` excerpt comes from the test/build/lint compressor instead of `grep`, with no cross-call dedup. Falls back to the old grep/tail excerpt when Python is missing or the log is small. `GATE_FIREWALL=0` turns it off. |
| `tbv run -- <cmd>` | Cursor, Copilot, a plain terminal, PowerShell | Runs the command, stores it, prints the compact view and exits with the command's exit code. |

Both hook paths were checked end to end against Claude Code 2.1.289 in headless mode:
- a failing `pytest` run arrived at the model as the compact view
- a successful `git log` chain arrived as the compact view
- a command matching a `deny` rule was left alone and stayed blocked

### The rewrite never widens permissions

Live testing showed that a hook's `permissionDecision: "allow"` overrides `deny` rules.
So the rewrite only fires when **your own settings already allow the exact original
command**:
- no `deny` or `ask` rule matches it, in user, project or managed settings
- an `allow` rule matches it, or the session runs with `--dangerously-skip-permissions`

A project's `allow` rules count only if you have trusted that workspace
(`hasTrustDialogAccepted` in `~/.claude.json`), as Claude Code itself requires.

Anything else is left alone: the normal permission prompt runs, and only the
`PostToolUse` path applies. That covers:
- commands allowed only by `--allowedTools`, which a hook can't see
- unreadable settings
- shell syntax: pipes, `;`, `&&`, redirection, `$`, globs, `~`, env assignments
- aliases and unresolvable programs

To get compact output from failing runs of a command, allow it in settings, for example
`"Bash(pytest:*)"` or `"Bash(npm test:*)"`. Inside tbv, tests go through
`gate.sh` anyway.

### Failure behaviour

Both hooks **fail open**. If Python is missing, the payload is unexpected, the store
can't be written, or a compressor throws, the hook prints nothing and the original
command runs with its raw output. A firewall failure is logged to `.tbv/events.jsonl`,
and `tbv stats` counts it.

Some commands are never touched:
- commands that call `tbv` itself (retrievals)
- `gate.sh`, whose output is already compact
- commands prefixed with `TBV_RAW=1`
- background commands

`TBV_DISABLE=1` turns everything off.

A rewritten command's output arrives when the command ends, not streamed. If Claude
Code's own Bash timeout kills a wrapped command, the partial output isn't kept; use
`tbv run --timeout S -- …` for long runs.

## Retrieval

```
tbv artifact <id>                     whole artifact, line-numbered (bounded; --all for everything)
tbv artifact <id> --lines 130-170     a line range
tbv artifact <id> --section failures  a section of the compact view, unabridged
tbv artifact <id> --failure 2         one test failure (also --test <name substring>)
tbv artifact <id> --error 1           one error/diagnostic
tbv artifact <id> --file src/a.ts     that file's diff block / matches / diagnostics / subtree
tbv artifact <id> --raw               exact original stdout+stderr (--stream stdout|stderr)
tbv artifact <id> --sent              exactly what the model was given
tbv artifact <id> --meta              the artifact record (JSON)
tbv show <id>                         drill-down: command, sizes, sent view, omitted sections, retrievals
tbv recent                            recent artifacts
tbv lookup <text>                     search stored artifacts
tbv source <file> --outline           classes/functions with line ranges
tbv source <file> --symbol Session.refresh   exact source of one symbol
tbv source <file> --lines 40-80       exact lines
```

Artifact ids are stable. An unambiguous prefix also works. Results over
`limits.retrievalLines` (300) are cut, and the output says so.

## Commands

```
tbv run [--timeout S] [--shell|--pwsh] -- <command …>   (or just: tbv git status)
tbv test | build | lint [args]     the project's gate.<step> from vault/project.md, else package.json
tbv search <query> [paths]         rg, else git grep, else grep
tbv ingest --command "<cmd>" --stdout <file|-> [--stderr f] [--exit N]   compress existing output
tbv context --task "fix Session.refresh()" [--symbol X] [--file F]       ranked context pack
tbv stats [--json] [--hours N]     context economy
tbv bench <fixture-dir>            raw vs compact size per fixture and mode
tbv prune --days 14                drop old artifacts and orphaned blobs
tbv config                         effective settings
```

`~/.claude/scripts/tbv` (bash) and `tbv.ps1` (PowerShell) find a Python 3.8+:
`$PYTHON`, then `python3`, `python`, `py -3`. Each candidate is tested before use, so
the Windows Store `python3` stub is skipped.

## Output types and what is kept

| Type | Kept | Dropped from the view (still in the artifact) |
|---|---|---|
| git-status | branch, ahead/behind, conflicts first, staged/unstaged/untracked with state, renames | `(use "git …")` hints; big untracked folders become a count |
| git-diff / show | files, +/-, renames, binaries, mode changes, changed symbols, every changed line, 1 line of context (strict: all) | far context; lock/generated file hunks (listed) |
| git-log | one line per commit, `--stat` lines | bodies |
| search | query, match/file counts, line numbers per file, first matches per file, lines that are not matches | further snippets per file (`--file`) |
| test | status, counts from the runner's own summary, each failure: name, location, assertion/expected/received lines, raw line range | passing tests, library stack frames |
| build / lint | errors, warnings, issues with file:line:col and code; repeats collapsed with all locations counted; success summary + warnings | progress lines, code frames |
| package-manager | errors, summary (added/audited/vulnerabilities), deprecated package names | download/progress/"already satisfied" lines (counted) |
| stack-trace | exception type + message, causes, application frames | library/framework frames (counted) |
| directory-listing | tree to depth 2 with file counts; `node_modules`, `.git`, `dist`… collapsed | deeper levels (`--file <dir>`) |
| json | structure outline: keys, types, array lengths, short values | long values, items after the first |
| generic / log | error and warning lines (grouped), lines that fit no repeated pattern, most repeated line shapes, head and tail | the repetitive middle |

Test runners recognised: pytest, unittest, jest, vitest, mocha, node:test (TAP and spec),
go test, cargo test, dotnet test, Pester, Maven Surefire. Diagnostics recognised: tsc
(both formats), MSBuild, gcc/clang, javac, rustc/cargo, eslint (stylish and unix), ruff
(concise and full), mypy, flake8/pylint-style `file:line:col`, Maven, webpack.

When the runner's exit code and its parsed summary disagree, the status says so
(`FAILED (exit 2, no failing test parsed)`) instead of choosing one.

## Deduplication

- **Within one output:** consecutive repeated lines or blocks collapse to one copy with
  `[xN]`. Lines that match only after numbers are normalised are marked
  `[xN similar]`.
- **Across calls:** when a command's output is byte-identical to one delivered earlier
  in the same Claude session, the model gets a two-line `NO NEW INFORMATION` pointer instead.
  A plain `tbv run` from a terminal has no session, so it never does this unless you pass
  `--session` or set `TBV_SESSION`.
  The same applies when only timings, timestamps, hex ids or temp paths differ. The
  window is 20 minutes (`dedup.windowSeconds`). Strict mode never does this. A
  different exit code always counts as new information.

## Modes

| Mode | Use for | Effect |
|---|---|---|
| `strict` | hard debugging, unfamiliar code, migrations, security work | 3× budget, full diff context, more lines per section, no cross-call dedup |
| `balanced` (default) | routine work | as described above |
| `aggressive` | only when you choose it | 0.4× budget, fewer lines per section; the header always shows `mode aggressive` |

Set the mode with `TBV_MODE=strict`, `--mode` on a command, or `"mode"` in a config file.
The firewall never switches mode by itself.

## Configuration

`<repo>/.tbv/config.json` (per project), or `config.json` next to `tbv.py` (global).
Only the keys you change are needed:

```json
{
  "contextFirewall": {
    "enabled": true,
    "mode": "balanced",
    "budgets": { "toolOutputTokens": 5000, "activeContextTokens": 12000, "historyTokens": 4000 },
    "limits": { "maxRawArtifactBytes": 50000000, "maxInlineOutputTokens": 5000,
                "passthroughTokens": 400, "maxLineChars": 300, "retrievalLines": 300 },
    "dedup": { "enabled": true, "windowSeconds": 1200 }
  }
}
```

The store lives at `<git root>/.tbv/` (override: `TBV_HOME`). It writes its own
`.gitignore`, so it never makes a tree dirty. Output over `maxRawArtifactBytes` keeps
its first and last halves, marks the cut, and the header says so.

## Ranking (`tbv context`)

`tbv context` gathers candidates:
- failures from the latest test run
- errors from the latest failing build/lint
- symbols named in the task or with `--symbol`, as their exact source
- each symbol's dependencies, as one-line neighbours with file:line, never their bodies
- files edited this session or modified in the working tree
- recent results

Each candidate is scored with fixed weights (`rank.WEIGHTS`). The best are then fitted
to `budgets.activeContextTokens`. Every included item states why it is there; every
excluded item is listed with how to fetch it.

## Measuring

`tbv bench tests/fixtures` reports raw vs compact size, per fixture and mode, for the 44
real and handcrafted outputs in this repo. On those fixtures, estimated tokens drop by about 50% in
strict, 80% in balanced and 87% in aggressive, at under 40 ms per command. These numbers are about
size only. Whether agents do as well with less context is a separate question, and the
fixtures don't answer it. To measure that, run the same eval task (`evals/`) with
`TBV_DISABLE=1` and without, then compare:
- task success, test success and retries/rework
- the model's own token counts, and latency
- `tbv stats --json` (intercepts, reduction, duplicates, retrievals, firewall failures)

A high retrieval count means the compact views leave out too much. That is the signal
to move a project to `strict`, or to fix a compressor.

## Tests

`python -m unittest discover -s context-firewall/tests -p "test_*.py"` runs:
- golden output per fixture
- an invariant check that every verbatim line and every `file:line` shown appears in
  the raw output
- tests for modes, retrieval, dedup, budget and ranking
- the hook, the CLI, timeouts, partial output and large output
- fallback when a compressor throws

`UPDATE_GOLDEN=1` rewrites the golden files; review the diff before you commit it.
