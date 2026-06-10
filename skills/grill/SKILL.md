---
name: grill
description: Use BEFORE decomposing any new feature into slices. Interrogates the feature idea to surface ambiguity, edge cases, and unstated decisions while they're cheap — instead of discovering them at Tier 3 after burned retries. Produces a grilled spec.
---

# Grill

Do NOT start planning or writing code. Ask questions first. Ambiguity resolved here
costs one message; ambiguity discovered mid-slice costs retries, tokens, and rework.

## Method
Ask ONE question at a time (this is a conversation, not a form). Pull threads in
this order, skipping what's already answered:

1. **Actor & outcome** — who does this, and what changes in the world when it works?
2. **The unhappy paths** — what should happen when input is wrong, the network fails,
   the record doesn't exist, two users collide? (Most unstated decisions live here.)
3. **Data shape & lifetime** — what's stored, what's derived, what can be deleted,
   what must never be? Any field that's expensive to change later?
4. **Boundaries** — what is explicitly OUT of scope for this feature? Get a "no" list.
5. **Existing patterns** — does the codebase already do something similar this must
   match? (Check before asking — then confirm.)
6. **Reversal cost** — which decisions here are one-way doors? Those become hitl slices.

## Stopping rule
Stop when a new question would not change the slice plan. Typically 5-10 questions.
Don't grill trivial work — a one-slice bugfix needs zero questions.

## Side effects as you go
- New domain term agreed? Add it to the Domain Language table in vault/project.md.
- A decision with a load-bearing rationale? Offer to record it as an ADR in
  vault/decisions/ so future sessions don't re-litigate it.

## Output
A grilled spec (in conversation, ≤ 30 lines): actor-outcome statement, decided
behaviors including unhappy paths, the out-of-scope "no" list, one-way doors flagged.
Then hand off to the slice-planning skill.
