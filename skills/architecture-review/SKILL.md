---
name: architecture-review
description: Use every 5 completed slices or at feature completion (Director tracks the counter in task-tree.json). Finds deepening opportunities — shallow modules, pass-throughs, cross-slice duplication — and queues them as candidates for human acceptance. Never refactors autonomously.
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
2. Spawn an explore subagent over the code added since the last review. Note friction:
   - Understanding one concept requires bouncing between many small modules
   - Shallow wrappers and pass-through layers (controller→service→repo where the
     middle adds nothing)
   - Same validation/query/transform logic re-implemented across slices (rule of
     three reached → extraction candidate)
   - Code untestable through its current interface
3. For each candidate, one card: Files · Problem (in domain language) · Proposed
   deepening · Benefit in locality/leverage terms · Strength: Strong / Worth
   exploring / Speculative.

## Output & routing (this skill detects, never repairs)
- Cards → vault/flags/pending-review.md, each with the 3-line triage block
  (what / what it affects / cost to reverse)
- Human-accepted candidates are grilled and planned like any feature — refactor slices
  run autonomously once the grill has settled the target design
- Human-rejected candidates with load-bearing reasons → offer an ADR so this
  review never re-suggests them
- Reset slices_since_arch_review to 0 in task-tree.json
