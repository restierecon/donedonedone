# donedonedone

## Purpose
An autonomous engineering protocol for AI coding agents: agents, skills and guardrail hooks that take a grilled spec to merged, trusted slices.

## Stack
Bash, Python 3.12, jq. Agent manifests and skills are Markdown. CI: GitHub Actions on Linux and Windows (.github/workflows/ci.yml); bundle.yml republishes the bundle-latest release when CI goes green on main.

## Gate
- gate.lint: shellcheck scripts/*.sh scripts/ddd tests/*.sh install.sh && scripts/validate-manifests.sh
- gate.types: none
- gate.test: tests/run-tests.sh && PYTHON=python3 tests/crap-score.sh && PYTHON=python3 tests/codebase-graph.sh && PYTHON=python3 tests/mutation-report.sh && PYTHON=python3 tests/detect-gates.sh && python3 -m unittest discover -s context-firewall/tests -p 'test_*.py'
- gate.build: HOME="$(mktemp -d)" ./install.sh >/dev/null
- gate.a11y: none
- gate.test.budget: 300

## Domain Language
| Term | Meaning |
|---|---|

## Autonomy
supervised

## Parallelism
max_parallel_slices: 3

## Definition of Done
Every slice independently testable, no TODO/FIXME, no comments, gates green.
