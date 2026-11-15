# Redesign proposal: scripted loop, locked contracts, GitHub as the merge authority

Status: step 1 of the build order is implemented (locked contracts, hazards derived
from the diff). Steps 2 and 3 are proposals.

## Goals

1. Faster: fewer LLM turns and no duplicated work per slice.
2. More autonomous: the human is involved in important decisions only.
3. Trustworthy: a slice cannot drift from its contract without a mechanical failure.

## What is wrong today

Findings from reading the protocol, scripts and manifests. Nothing here was timed on a
real run, so the speed claims are estimates.

| # | Finding | Evidence | Costs |
|---|---|---|---|
| 1 | The autonomy dial can never leave `supervised` | Promotion needs a dated passing scorecard; `evals/README.md` says "Status: never run" | Attention |
| 2 | The dial is prose only | No script reads it; `risk-gate.sh` ignores it by design | Trust |
| 3 | The grill is serial and mandatory for all work | `skills/grill/SKILL.md`: one question at a time, every bugfix included | Attention |
| 4 | The full gate runs twice at the same SHA | Builder self-check, then the Director's gate 2 | Speed |
| 5 | Each slice costs many Director turns and commits | Four `record-gate.sh` commits, land, harvest | Speed |
| 6 | There is no fast lane | A three-line fix pays for planner, brief, builder, reviewer, harvest | Speed |
| 7 | Review strength is inverted | Reviewer fixed on sonnet; risky slices built on the session model | Trust |
| 8 | Hazards come from the plan, not the code | `risk-gate.sh` reads declared hazards and regex-matches criteria text; the diff is checked for file scope only | Trust |
| 9 | Human-only gates are held by pattern-matching hooks | `guard.sh` is 612 lines; PRs #19, #21 and #24 each closed a bypass route | Trust |
| 10 | The risk score is arithmetic on guessed inputs | Five 0-4 ratings written by the planner, weighted to 0-100 | False precision |
| 11 | Flags are pull, not push | The human polls `pending-review.md`; the 5-slice review adds cards | Attention |

## Design

### Principle 1: a script is the Director

A state machine, `tbv next`, owns the process. It reads the state, prints exactly one
next action (spawn this agent with this brief file, run this command, wait for this
approval) and records the result. The session executes what it prints.

LLMs are called for judgment only: writing the spec, writing tests, building, reviewing.
Bookkeeping takes no LLM turn and cannot be forgotten or reordered.

### Principle 2: the contract is locked before the build

A slice's contract is three things, hashed together:

- Acceptance tests: one or more per criterion, written by a test-author agent, and
  confirmed failing before any build.
- Scope: the paths the slice may touch.
- Budget: a ceiling on changed lines.

The builder cannot edit the contract. The gate fails when the hash changed, the diff
leaves scope, or the budget is exceeded. Drift is a red gate, not a reviewer's catch.

Escape hatch: a builder that believes a test is wrong reports `CONTRACT-DISPUTE` with
the test and the reason. The test author revises once. A second dispute goes to the
human.

### Principle 3: GitHub holds the merge authority

Every slice is a pull request. Enforcement moves from local hooks to permissions the
agent does not have:

- Branch protection on main: required CI checks, no direct push.
- CODEOWNERS on the lane policy and on contract files: only the human can change them.
- A human-lane PR needs the human's approving review.

The human approves from any device. Merged PRs are the record of what shipped.

A project without GitHub falls back to the current hooks, with weaker guarantees.

## Pipeline

| Step | Who | What happens |
|---|---|---|
| 1. Spec | Agent and human | The agent reads the codebase, then drafts criteria, an out-of-scope list and its assumptions. It asks, in one message, only about one-way doors and real ambiguity. A new screen or flow gets a prototype to approve; a minor UI change does not. |
| 2. Contract | Test author | Tests written, confirmed red, contract hashed and locked. |
| 3. Build | Builder | One per slice, in parallel worktrees, looping on focused tests. Three attempts, then escalate. |
| 4. Fast gate | Script | Lint, types, tests, scope, budget, contract hash, hazards detected from the diff. Runs once; the result is cached by patch-id. |
| 5. Lane | Script | Sets the remaining controls. See below. |
| 6. Merge | Script | Opens the PR; CI is the second, independent gate. Auto-merge where the lane allows. |
| 7. Digest | Script | One push per feature: what merged, what was assumed, what waits for the human. |

### Lanes

The lane is computed from the diff by path and pattern rules in a policy file. The spec
can raise a lane, never lower it.

| Lane | Trigger | Extra control | Human |
|---|---|---|---|
| Auto | No hazard | None | Not asked |
| Verified | Shared or public surface, or a large diff | Reviewer on the session model; mutation testing on changed lines | Not asked |
| Human | Schema migration, auth, secrets, money, data deletion, new dependency | Reviewer with the security checklist | Approves the PR |

### Slow checks move off the merge path

Full mutation testing, CRAP scoring and architecture rules run nightly on main. A
failure opens a follow-up slice. It never blocks a merge that already happened.

## When the human is involved

- Spec sign-off: once per feature, one batched message.
- Prototype approval: new screens and flows only.
- Human-lane PRs: approve or reject.
- Escalations: a second contract dispute, or three failed build attempts.
- The digest: read when convenient; nothing in it blocks.

## What is removed

- Roles: the LLM Director protocol, the planner, the separate auditor, the retro agent.
- Risk machinery: the 0-100 score, the five classes, the autonomy dial, the promotion
  rule.
- Bookkeeping: `record-gate.sh` commits, harvest, `stories.md`, task-tree pruning.
- Resolution tiers 1 to 3.

## What is kept

`gate.sh`, the scope check, the context firewall, worktrees, test-worker sizing, the
patch-id rule for when a verdict goes stale, and the brief format (generated by the
script, not written by an LLM).

## Weak points

| Risk | Consequence | Mitigation |
|---|---|---|
| A wrong test locks in a wrong reading of the spec | The builder builds the wrong thing correctly | `CONTRACT-DISPUTE`; the digest lists every assumption |
| Tests are a weak contract for visual work | Minor UI changes merge unseen | Screenshots in the digest; a path rule can force the verified lane for UI files |
| Nightly checks lag | Main can hold weakly tested code for up to a day | Mutation on changed lines stays in the verified and human lanes |
| Diff-based hazard rules miss a pattern | A hazardous change lands in the auto lane | The policy file starts strict and is owned by the human; CI re-runs the lane check |
| The harness needs GitHub | Local-only projects lose the hard boundary | Hook fallback, documented as weaker |

## Build order

Each step is usable alone, and each can be the last.

1. Locked contracts and diff-derived lanes, on top of the current harness. Most of the
   trust gain. Done: `contract.sh`, the `tester` agent, gate.sh's `contract` step, and
   `diff_paths` / `diff_lines` in the risk policy. The five risk classes stay until
   step 3; a diff hazard raises a slice within them.
2. PR-based merge with branch protection and CODEOWNERS. Most of the autonomy gain.
3. The `tbv next` state machine, then removal of the old protocol. Most of the speed
   gain.

Before step 3, add per-stage timing to `log.jsonl` and measure one feature end to end,
so the removal is driven by numbers.

## Open decisions for the human

1. Lane policy defaults: which paths and patterns mark a hazard in a project with no
   policy file yet.
2. Minor UI changes: auto lane with screenshots in the digest, or always the verified
   lane.
3. Nightly failures: open follow-up slices automatically, or list them in the digest.
4. Local-only projects: support them with the hook fallback, or require GitHub.
