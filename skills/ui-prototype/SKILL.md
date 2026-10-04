---
name: ui-prototype
description: The grill's UI step. Use when a grilled feature adds or changes anything a user sees or clicks (screen, page, component, form, dialog, navigation, dashboard, copy). Writes a UI contract and a clickable prototype covering every state, gets the human's explicit approval, and records it so slices build to an approved design instead of inventing one.
---

# UI Prototype

Show, then build. A layout, hierarchy or interaction call made by a builder mid-slice
is a human decision made by the wrong party. This step makes it during the grill,
where it costs one review instead of a rebuilt slice.

## 1. Classify the UI impact
Ask once, record the answer in the grilled spec as `UI: none | minor | major`:
- **none** — nothing a user sees changes (API, job, schema, refactor with identical
  output). Skip the rest of this skill; slices carry `"ui_contract": null`.
- **minor** — a change inside an existing screen that follows a pattern already in the
  app (a new column, a field on an existing form, a copy fix). Contract required,
  prototype optional: a contract naming the existing pattern it copies, with a
  screenshot of that pattern, is enough when the human agrees.
- **major** — a new screen, flow, navigation change, dashboard, or any layout the app
  has no precedent for. Contract and prototype both required.
Unsure between two classes → take the higher one.

## 2. Write the contract
`vault/ui/<feature-slug>/contract.md`, ≤ 60 lines, first line `status: draft`:

```markdown
status: draft
# <Screen name>
Purpose: <the job this screen does for the actor, one sentence>
Precedent: <existing screen/component it matches, or "new">

## Layout & hierarchy
Primary action: <one> · Secondary: <...> · Destructive: <... and where they live>
Regions, top to bottom: <...>

## States
<Every state, each with what the user sees and the copy shown:
initial · loading · populated · empty · error · validation · success · disabled
— drop only the ones this screen cannot reach, and say why>

## Interaction
<Where each action leads; inline vs. panel vs. dialog and why; keyboard path; focus
after each action>

## Responsive
<What changes at 375px, 768px and 1280px>

## Tokens & components
<Design-system components and tokens by name (`Button variant=primary`,
`--space-4`), never raw hex or px. No design system yet? That is a one-way door:
decide it now, as an ADR, before this contract>

## Accessibility
<Labels, landmarks, contrast pairs to check, live regions for async results>
```

Every "or" in a contract is an open decision. Settle it with the human before review —
"modal or banner" is exactly the call a builder must not make.

## 3. Build the prototype (major; minor when asked)
`vault/ui/<feature-slug>/prototype.html` — one self-contained file, no build step:
- Every state in the contract reachable from a visible state switcher, so the reviewer
  clicks through them instead of imagining them.
- Real copy and realistic data at realistic lengths: the long name, the 0-item list,
  the 4-digit count. No lorem ipsum.
- The project's real tokens (colors, type scale, spacing, radius) copied in as CSS
  custom properties, and its fonts. A prototype in default styling approves nothing.
- Hover, focus-visible, disabled and pressed styles on every control.
- Throwaway code: optimize for speed of change, never for reuse. Builders read it as a
  reference; they never copy it into the app.
Before showing it, check it against the frontend-ui-engineering skill's AI-default
table and screenshot it at 375, 768 and 1280px (`vault/ui/<feature-slug>/<state>-<width>.png`
— the reviewer compares against these later). Fix any AI default you find first.

## 4. Get approval
Give the human the prototype path (and a hosted link when the host can publish a
private page), the contract, and the screenshots, with a review list: hierarchy
(is the primary action obvious?), every state, copy, responsive behavior, anything
deliberately left out. Then wait.
- Changes requested → revise contract and prototype, re-screenshot, ask again.
- Approved → set the first line to `status: approved <YYYY-MM-DD> — "<the human's
  words>"`, only after an explicit approval in this conversation. Silence, "looks
  fine so far" or approval of a different revision is not approval.
- Commit the folder: `docs(ui): approve <feature-slug> contract`.

## 5. Hand off to planning
The grilled spec carries `UI: <class> — vault/ui/<feature-slug>/contract.md
(approved)`. Every slice that renders part of it gets `"ui_contract"` set to that
path, and acceptance criteria that name the contract states the slice delivers
("empty state shows the contract's empty copy and its primary action"). check-plan.sh
refuses a slice whose contract is missing or not approved.

## After approval
The approved contract is the spec. A builder that finds it can't be built as written
stops with STATUS: SCOPE-EXPANSION naming the conflict; the Director takes it back
to this skill — a new revision, a new approval — never a builder's improvisation. Any
later UI requirement change does the same.
