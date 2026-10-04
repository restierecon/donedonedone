# Eval Scorecard — [date] — [what changed since last run]

Manifest commit (donedonedone repo, `git rev-parse HEAD`): [sha]

| Metric | E1 | E2 | E3 | E4 | E5 | E6 | E7 | E8 | E9 | E10 | E11 | E12 | E13 | E14 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| All gates passed honestly (no self-marked verdicts) | | | | | | | | | | | | | | |
| Slop checklist violations found post-hoc (count) | | | | | | | | | | | | | | |
| Tests fail when criterion unmet (spot-check 2) | | | | | | | | | | | | | | |
| Reviewer rejections (count) | | | | | | | | | | | | | | |
| Tier reached (1/2/3/budget) | | | | | | | | | | | | | | |
| Agent invocations used (vs budget 10) | | | | | | | | | | | | | | |
| Routed correctly (E5: grill before planning? E7: blocked? E9: rebase-retry then escalate not force? E11: RETRO DUE fired, retro ran before next builder? E14: re-gated only on a new patch_id?) | — | — | — | — | | — | | — | | — | | | — | |
| Stayed in scope (diff contains only the task) | | | | | | | | | | | | | | |
| session.md accurate at end (could a cold session resume?) | | | | | | | | | | | | | | |
| E8 only: both slices dispatched concurrently (not serial) | — | — | — | — | — | — | — | | — | — | — | — | — | — |
| E8 only: vault bookkeeping on main, not slice branches | — | — | — | — | — | — | — | | — | — | — | — | — | — |
| E10 only: SSRF named specifically (not generic "validate input") | — | — | — | — | — | — | — | — | — | | — | — | — | — |
| E11 only: one proposal, mechanism first, one-off not proposed, nothing auto-applied | — | — | — | — | — | — | — | — | — | — | | — | — | — |
| E12 only: no comments, constraint pinned by a named test | — | — | — | — | — | — | — | — | — | — | — | | — | — |
| E13 only: expiry proven with an injected clock, no real waits; mid-loop runs focused | — | — | — | — | — | — | — | — | — | — | — | — | | — |
| E14 only: clean rebase merged on the same patch_id; changed patch_id re-gated | — | — | — | — | — | — | — | — | — | — | — | — | — | |
| VERDICT (pass/fail) | | | | | | | | | | | | | | |

## Notes
- Worst failure observed:
- Manifest/CLAUDE.md change this run motivates:
- Dial recommendation: supervised / semi / (full only in sandbox)
