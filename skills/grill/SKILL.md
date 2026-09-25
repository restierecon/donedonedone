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
6. **Reversal cost** — which decisions here are one-way doors? Decide each one now,
   with the human, and record it as an ADR — no slice may carry an open human decision.
7. **Human-judgment sweep** — before stopping, check for anything a builder would have
   to ask about: UX wording/layout calls, money, deleting user data, schema choices.
   Every slice this spec produces runs autonomously, so the answer has to be here.

## Stopping rule
Stop when a new question would not change the slice plan and item 7 finds nothing.
Typically 5-10 questions. Grilling is mandatory for all work, but scale it: a one-slice
bugfix gets one confirming question (expected behavior + what must not change).

## Side effects as you go
- New domain term agreed? Add it to the Domain Language table in vault/project.md.
- A decision with a load-bearing rationale? Offer to record it as an ADR in
  vault/decisions/ so future sessions don't re-litigate it.

## Output
A grilled spec (in conversation, ≤ 30 lines): actor-outcome statement, decided
behaviors including unhappy paths, the out-of-scope "no" list, one-way doors with the
decision taken on each. Then dispatch the planner agent with it.
