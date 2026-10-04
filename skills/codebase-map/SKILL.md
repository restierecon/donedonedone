---
name: codebase-map
description: Use to see or explain any repository's structure — code (folders → files → functions, imports and name references, cycles, hubs, complexity hotspots, test reach) and, where the repo holds a Claude Code setup, its agent workflow (stages → agents/skills → hooks → scripts) — or to size a change's surface before planning it. Generates .gate/graph.json and a drill-down .gate/graph.html from git, on demand. Also /codebase-map. Read-only; architecture-review and blast-radius call it.
---

# Codebase map

The map is regenerated from git each time it's needed and never committed, so it can't
go stale. Nothing has to keep it in sync. It reads committed trees only, so commit
before you build.

## Commands (run from anywhere in the repo; Python 3, lizard for complexity)
- `python3 ~/.claude/scripts/codebase-graph.py build [--coverage <report>] [--rules vault/architecture.json] [--days 90]`
  writes `.gate/graph.json` and `.gate/graph.html` for HEAD (`--rev` for another
  revision) and prints a summary of at most 20 lines: GRAPH totals, a SEEN line
  saying how much of the repo it analysed and how, the flagged folders and files,
  and one SETUP line per Claude Code setup it found. It exits 1 when a setup's
  workflow.json has errors; the map is still written.
- `python3 ~/.claude/scripts/codebase-graph.py impact (--base main | <files>…)` prints a
  CHANGE IMPACT block: direct and indirect dependents, modules reached, tests in reach,
  docs that mention the change, setup components it touches, cycles, and an estimated
  regression risk.
- `python3 ~/.claude/scripts/codebase-graph.py check --rules <file> --base main` reports
  the architecture violations HEAD adds over the base. gate.sh's `arch` step runs it.

## What it reads (any repo)
- **Every tracked text file is a node.** Vendored, binary and >1 MB files are skipped
  and counted.
- **Links:**
  - `import`: parsed, for Python, JS/TS (relative paths), Go and Java/Kotlin.
  - `reference`: a script, config or CI file naming another file's path, or a unique
    file name (`source ./lib/x.sh`, `"$(dirname "$0")/gate.sh"`, `run: bin/deploy.sh`).
  - `mention`: a doc, or a string inside parsed code, naming a file. It shows in the
    map but is never a dependency.
- **Complexity:**
  - measured: lizard's languages.
  - estimated: shell, counting branches per function plus the script body.
  - not measured: other code, e.g. PowerShell or Makefiles.
  - n/a / other: docs, data and unknown text.
- **The SEEN line** gives these shares. A WARNING appears when more than 30% of the
  code has no complexity measure, so a blind map says so instead of looking clean.
- **Flags, each with a `why`:**
  - `cycle`: import cycles are high risk; cycles that go through name references are
    medium, since they may just be message strings.
  - `violation`: breaks a rule in architecture.json.
  - `hub`: 5 or more non-test modules depend on it.
  - `hotspot`: complexity ≥ 10 and changed 3 or more times.
  - `complex`: complexity ≥ 15.
  - `untested`: no test imports it, names it or reaches it, or coverage is under 50%.

## Facts (any repo, each with evidence)
`graph.json` → `facts`, shown on the code lens root and as one FACTS summary line:
- **Stack:** languages by production lines, dependency manifests at any depth (test
  fixtures excluded), and monorepo signals (workspaces, pnpm/lerna/nx/turbo/rush,
  repeated manifests).
- **Dependencies:** per manifest, split runtime / dev / optional / peer / indirect.
  Parsed for package.json, pyproject.toml (PEP 621, dependency groups, Poetry),
  requirements*.txt (a dev, test or lint name means dev), go.mod, Cargo.toml, Gemfile
  groups and composer.json. Other manifests are listed only.
- **Entry points:** what manifests declare (main, bin, scripts.start,
  [project.scripts]), conventional files (`__main__.py`, `main.go` with
  `package main`, root install/run scripts, Makefile), and container CMD/ENTRYPOINT.
- **Configuration:** variables in env templates, and variables production code reads
  (docstrings and tests excluded). A variable read but missing from the template is
  an `[ASK USER]`.
- **Delivery and tooling:** CI systems, containers and orchestration, security and
  ownership config, lint, format and type configs.
- **Intent vs reality:** the intent docs to read first (README, specs, ADRs). A path a
  doc names that exists nowhere in the repo is an `[ASK USER]`; fenced examples and
  paths relative to the doc are skipped.
- **Concerns:** TODO/FIXME/HACK/XXX markers in comments, counted separately for
  production and tests (test markers are coverage gaps, not debt), and the
  most-changed files.

Anything it can't establish is a `[TODO]`, never a guess. These facts feed
/init-codebase's onboarding brief.

## Workflow lens (a repo holding a Claude Code setup)
- **Detection:** a root with `agents/*.md`, `skills/*/SKILL.md`, `commands/*.md` or
  hooks in `settings.json`. Both the repo root (a setup like this one) and a project's
  `.claude/` count.
- **Components:**
  - agents (with model and tools from frontmatter), skills (with their files),
    commands, and the protocol (CLAUDE.md/AGENTS.md)
  - hooks: settings.json event → matcher → the script it runs
  - scripts: file nodes from the code lens, so you can drill down to their functions
- **Links between components** come from paths and names in their files: `skills/x`,
  `/x`, "x skill", backticked agent names, "x agent", table rows, and bare hyphenated
  names. Each link carries its file:line evidence.
- **`workflow.json`** at the setup root declares the stage order:
  ```json
  {"name": "…", "description": "…",
   "stages": [{"id": "review", "label": "Review", "description": "…", "when": "…",
               "uses": ["agent:reviewer", "skill:blast-radius", "script:gate.sh"],
               "next": ["audit", {"to": "build", "label": "REJECTED"}]}],
   "on_demand": ["skill:frontend-ui-engineering"]}
  ```
  Refs are `agent:` / `skill:` / `command:` / `script:<path or unique name>` /
  `hook:<Event>` / `protocol:`.
- **Verification:**
  - Errors: a ref that doesn't exist, a `next` that isn't a stage, or an agent, skill
    or command that no stage, hook, protocol file or on_demand entry reaches (directly
    or through other components).
  - Warning: an unreached script.
- **Without workflow.json** the lens groups components by kind.

## Limits (say them when you report)
- Name references find literal paths and names, not string-built ones. Dynamic
  imports, path aliases (`@/…`), DI wiring and reflection are invisible.
- Callers are per file, not per function. Before calling a function unused, grep for
  its name.
- Shell complexity is an estimate. Without `--coverage`, "untested" means no test
  reaches the code in a way the map can see.
- Very large repos produce large pages: Django is about 5,600 files and a 24 MB HTML
  file. Use `--out` and open it locally.

## Reading it (signals, not verdicts)
A flag is a reason to look, not a defect. A 40-line function that reads top to bottom
can be fine. A 3-line function that only forwards a call can still be a problem
(apply the deletion test from architecture-review). Read the code behind a flag before
proposing a change. Rank by what hurts change most: import cycles and violations, then
hubs that are hotspots, then the rest.

## Reporting to a human (≤ 15 lines)
Lead with the GRAPH, SEEN, FACTS and SETUP lines (include any WARNING, [ASK USER] or ERROR). Then, for each
high-risk item: name, signals, and the `why` that matters most. Then a link to the
HTML: open it with the Artifact tool or send the file, and never paste its contents.
End with one suggested next step.

## Fitness rules (vault/architecture.json, set by a human in /grill)
```json
{"no_new_cycles": true,
 "forbid": [{"from": "src/domain/**", "to": "src/infra/**", "why": "ADR-004: domain stays free of I/O"}]}
```
- **Globs:** `**` crosses directories; `*` stays within one.
- **What counts:** `forbid` applies to dependencies (imports, plus references from
  scripts and config). `no_new_cycles` (default true) looks at import cycles only.
- **Where the rules live:** the gate reads them from `main`, so a slice can't loosen
  them on its branch. It fails only on violations the diff adds, so legacy ones show in
  the map as flags instead.
