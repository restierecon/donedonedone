---
name: crap-hotspots
description: Use when CRAP scores show risky code outside a slice's diff — an architecture review with gate.crap set, /init-vault on an existing codebase, or a human asking where the untested complexity is. Ranks functions by CRAP score from .gate/crap.log, classifies each hotspot, and routes the fix through /grill as ordinary slices; builders on those slices load it too. Never buys coverage with assertion-free tests or raises gate.crap.max to pass.
---

# CRAP Hotspots

CRAP (Change Risk Anti-Patterns) scores a function by how complex it is and how little
of it the tests run: `comp² × (1 − cov)³ + comp`, with `comp` its cyclomatic complexity
and `cov` its covered fraction (0–1). A fully covered function scores its complexity; an
untested one scores roughly its complexity squared. Over 30 is the conventional bar.

The gate's `crap` step blocks a slice only for functions its diff touches. Hotspots the
diff doesn't touch are planned work: found here, fixed in their own slices.

Under Cursor or Copilot without a skill loader, read this file from
`~/.claude/skills/crap-hotspots/SKILL.md`; everything it asks for is gate.sh and files.

## 1. Measure — in a subagent, so the full score list stays out of your context
Needs `gate.crap` in vault/project.md (contract: README → CRAP). Have a subagent that
can run commands run `~/.claude/scripts/gate.sh test crap` once, so the scores rest on
fresh coverage, then rank every line of `.gate/crap.log` (the full output of
`gate.crap`, not just touched functions). It returns ≤ 20 lines: the 10 highest
scores as `path:start name score`, how many functions exceed `gate.crap.max`, and for
each of the 10 whether coverage or complexity drives it, if the tool reports both.

## 2. Classify — cheapest, most reversible fix first
| Signature | Fix |
|---|---|
| Untested or barely covered, moderate complexity | characterization tests that pin current behavior; often enough on its own, and changes no production code |
| Covered but complex (score ≈ complexity, still over the bar) | split along its branches into deeper functions, behind the tests that already exist |
| Untested and very complex | characterization tests first, then split — two slices, tests merged before the refactor |
| Unreachable or unused | delete it (deprecation-and-migration skill), not test it |
| Generated code | exclude it in the `gate.crap` command itself, recorded as an ADR — never ad hoc |

## 3. Route
- One pending-review.md card: the 3-line summary (what / what it affects / cost to
  reverse), then the ranked list and the class of each.
- Accepted → /grill settles which hotspots to take and in what order. The planner
  slices it like any feature: "Developer can change <module> safely, so that <the
  feature that keeps touching it> ships without regressions". Characterization-test
  slices come before the refactors that depend on them.
- Architecture review: the hotspots join its candidate cards; a hotspot that is also a
  shallow module or a duplicate is one card, not two.

## Never
- Tests without assertions, or assertions that can't fail, to buy coverage — a test
  counts only if it fails when the behavior it names breaks.
- Raise `gate.crap.max`, or exclude a path from `gate.crap`, to get a slice through
  the gate. A threshold change is a grilled decision with an ADR.
- Fix a hotspot inside an unrelated slice — that is scope creep; it goes to a card.
