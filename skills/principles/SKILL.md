---
name: principles
description: Use when a design or trade-off decision needs a named engineering principle to settle it — e.g. choosing between two designs, deciding whether to keep a compatibility layer, how to sequence a refactor, where validation belongs. Index of 19 principles; read only the one reference file that applies.
---

# Engineering principles

Imported from [pstack `skills/principle-*`](https://github.com/backnotprop/pstack/tree/main/skills)
(MIT, Copyright (c) 2026 Lauren Tan — see LICENSE in this directory).

Pick the line that matches the decision in front of you, read that one file, apply it.
prove-it-works, test-behavior-not-implementation and subtract-before-you-add are
already baked into the builder/reviewer checklists.

- [attack-the-premise](references/attack-the-premise.md) — two fixes sharing one premise failed the same gate: question the premise, not the fix
- [boundary-discipline](references/boundary-discipline.md) — validate at system boundaries, trust internal types, keep logic pure
- [build-the-lever](references/build-the-lever.md) — non-trivial work: build the script/codemod that does or proves it
- [encode-lessons-in-structure](references/encode-lessons-in-structure.md) — a repeated instruction becomes a lint, check or script
- [exhaust-the-design-space](references/exhaust-the-design-space.md) — no precedent: sketch 2-3 alternatives before committing
- [experience-first](references/experience-first.md) — UX/scope trade-off: fewer, polished features over convenience
- [foundational-thinking](references/foundational-thinking.md) — data structures and scaffolding before logic
- [laziness-protocol](references/laziness-protocol.md) — prefer deletion and the smallest diff
- [make-operations-idempotent](references/make-operations-idempotent.md) — operations converge despite crashes and retries
- [migrate-callers-then-delete-legacy-apis](references/migrate-callers-then-delete-legacy-apis.md) — new internal API: migrate callers and delete the old one in the same wave
- [minimize-reader-load](references/minimize-reader-load.md) — cut layers to trace and state to hold
- [model-the-domain](references/model-the-domain.md) — encode the domain in a structure, not scattered conditionals
- [never-block-on-the-human](references/never-block-on-the-human.md) — reversible work proceeds; confirm only irreversible actions. Product direction stays with the human; grill/escalation rules still apply
- [outcome-oriented-execution](references/outcome-oriented-execution.md) — planned migrations converge on the end state, no throwaway compat code
- [prove-it-works](references/prove-it-works.md) — verify against the real artifact, not a proxy or self-report
- [redesign-from-first-principles](references/redesign-from-first-principles.md) — new requirement: redesign as if it were there from day one
- [subtract-before-you-add](references/subtract-before-you-add.md) — remove dead code and redundancy first, then build
- [test-behavior-not-implementation](references/test-behavior-not-implementation.md) — assert observed results against literal values
- [type-system-discipline](references/type-system-discipline.md) — illegal states unrepresentable, parse at boundaries, exhaust variants
