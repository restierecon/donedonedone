---
name: harden-diff
description: Builder's hardening pass over a slice that crosses a trust boundary — run when the brief's STANDING names harden-diff, which the Director does for every slice with auditor_triggers. Walks each trigger the slice carries (auth, sessions, data-access, user-input, file-uploads, secrets, dependencies, external-calls, llm-tools), fixes the gaps in the lines the slice adds, and proves each fix with a test named for the threat. The auditor stays the gate; this pass makes its findings rarer.
---

# Harden Diff

The auditor maps the trust boundaries your diff crosses and BLOCKs what can be abused.
A BLOCK costs a builder round and a second audit. This pass closes the common gaps first,
each one with a test, so the auditor confirms instead of discovers.

Run it once per slice whose brief's STANDING names it: after the criteria are green,
before clean-diff, the final `gate.sh` and the report. Under Cursor or Copilot without
a skill loader, read this file from `~/.claude/skills/harden-diff/SKILL.md`.

## 1. Map the boundaries the diff crosses
From `git diff main...HEAD -- . ':(exclude)vault'`, list every place data crosses a
trust line: request handler, form, CLI argument, file read, queue message, query,
outbound call, model output fed to a tool. The slice's `auditor_triggers` say which
kinds to expect; the diff decides which are real.

## 2. Close each gap — one test per fix, named for the threat
| Trigger | Check in the lines you add | Test named like |
|---|---|---|
| user-input | parsed into a typed schema at the boundary; rejects unknown fields, oversize and wrong types with a 4xx-class error, never a 500 | "rejects a title over 200 chars" |
| data-access | every query parameterized; every read and write checks the caller owns the row (no ID taken on trust) | "user B cannot read user A's note by id" |
| auth, sessions | deny by default; authz checked on the server per request; tokens expire; session id rotates on login; equal timing and message for unknown user and wrong password | "login does not reveal whether the email exists" |
| secrets | read from the environment; never logged, never in an error body, never in a fixture | "a failed payment call does not log the API key" |
| external-calls | timeout on every call; bounded retries with backoff only on idempotent requests; a user-supplied URL checked against an allowlist and private IP ranges | "a webhook URL pointing at 169.254.169.254 is refused" |
| file-uploads | size cap, type checked by content not extension, stored outside the web root under a generated name | "an .html file renamed .png is rejected" |
| dependencies | pinned version, lockfile committed, the audit tool (pip-audit, npm audit) clean for what you added | — the gate's lockfile and the auditor's scan cover it |
| llm-tools | model output treated as untrusted input: tool arguments validated, no shell or eval of model text, tool scope as narrow as the task | "a tool call with a path outside the workspace is refused" |

Fail closed: on a check that can't decide, deny and log, never allow and continue.
Every error path you add gets a test, like any criterion's failure mode.

## 3. Report
Commit, then continue with clean-diff and the full `gate.sh`. Add one line to your report:
`HARDENED: <trigger> → <test name>; ...` for every trigger the slice carries. A
trigger the diff turns out not to touch gets `<trigger> → not crossed (<why>)`. The
reviewer REJECTs a missing or empty HARDENED line on a slice with triggers.

## Never
- Hand-roll crypto, sanitizers or auth when the framework or stdlib has one.
- Widen scope: hardening code the slice didn't add goes under FLAG CANDIDATES for
  vault/flags/, never into the diff.
- Mark a trigger "not crossed" to skip its test when the diff does cross it.
- Add a dependency for hardening without the one-line justification the builder rules ask for.
