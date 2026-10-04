---
name: architecture-review
description: Use every 5 completed slices or at feature completion (Director tracks the counter in task-tree.json), alongside the learning-loop skill. Finds deepening opportunities — shallow modules, pass-throughs, cross-slice duplication — and queues them as candidates for human acceptance. Never refactors autonomously.
---

# Architecture Review

Vertical slicing's known failure mode: every slice builds its own end-to-end path,
so the codebase accumulates near-duplicates and shallow modules even though each
slice was locally correct. This review is the counterweight.

## Vocabulary (use exactly these terms)
**Module** — anything with an interface and an implementation. **Deep** — lots of
behavior behind a small interface (leverage). **Shallow** — interface nearly as
complex as the implementation. **Seam** — where behavior can be swapped without
editing in place. **Locality** — change, bugs, and knowledge concentrated in one place.

## The deletion test (primary instrument)
Mentally delete a suspect module. If complexity simply vanishes → it was a
pass-through earning nothing. If complexity reappears across N callers → it was
earning its keep. "Vanishes" is your refactor candidate.

## Process
1. Read vault/project.md (domain language) and vault/decisions/ FIRST — never
   re-suggest what an ADR has already rejected, unless friction has become severe
   enough to say so explicitly ("contradicts ADR-00n, but worth reopening because…").
2. Run `python3 ~/.claude/scripts/codebase-graph.py build` (codebase-map skill), with
   `--rules vault/architecture.json` if that file exists and `--coverage` if the project
   writes a report. Its flagged modules (cycles, rule violations, hubs, hotspots,
   untested code) seed the explore subagent's list, and each `why` line is a card's
   evidence. Signals, not verdicts: a flag becomes a card only after the deletion
   test or a read of the code confirms the friction.
3. Spawn an explore subagent over the code added since the last review, plus the
   flagged modules — and, in the
   same message, the `retro` agent per the learning-loop skill (process lens; it routes
   its own proposals). Note friction:
   - Understanding one concept requires bouncing between many small modules
   - Shallow wrappers and pass-through layers (controller→service→repo where the
     middle adds nothing)
   - Same validation/query/transform logic re-implemented across slices (rule of
     three reached → extraction candidate)
   - Code untestable through its current interface
   - With `gate.crap` set in project.md: the repo-wide CRAP hotspots, measured and
     classified per the crap-hotspots skill (~/.claude/skills/crap-hotspots/SKILL.md)
4. For each candidate, one card: Files · Problem (in domain language) · Evidence (the
   graph's numbers or file:line) · Options considered with their trade-off (coupling,
   cognitive load, change cost) · Proposed deepening · Benefit in locality/leverage
   terms · Risk of the change · Strength: Strong / Worth exploring / Speculative.

## Output & routing (this skill detects, never repairs)
- Cards → vault/flags/pending-review.md, each with the 3-line triage block
  (what / what it affects / cost to reverse)
- Human-accepted candidates are grilled and planned like any feature — refactor slices
  run autonomously once the grill has settled the target design
- Human-rejected candidates with load-bearing reasons → offer an ADR so this
  review never re-suggests them
- A boundary the human wants held (no cycles here, domain never imports infra) →
  offer it as a rule for vault/architecture.json; the gate's `arch` step then holds it
- Attach the map: `.gate/graph.html` (regenerated, never committed) is named in the
  pending-review entry so the human can drill into the flagged modules
- Reset slices_since_arch_review to 0 in task-tree.json (one counter drives both reviews)
- Project has `.claude/skills/verify-*/` → also suggest /maintain-verification-skill (feature map drifts at the same cadence)
