---
name: create-verification-skill
description: "Generate a project-local verification skill (.claude/skills/verify-<project>/) that launches this repo's real app and drives it like a user, so the reviewer can reach EVIDENCE: live-verified. Use for /create-verification-skill or when init-vault offers it; not for writing tests."
disable-model-invocation: true
---

# Create a verification skill

Adapted from [pstack `skills/create-verification-skill`](https://github.com/backnotprop/pstack/tree/main/skills/create-verification-skill)
(MIT — see LICENSE).

Every serious project needs a scripted way to drive the real app and prove behavior: launch it, exercise a feature the way a user would, and capture evidence. This skill generates that as a project-local skill at `.claude/skills/verify-<project>/` tailored to the repo. The reviewer agent looks for `.claude/skills/verify-*/` and drives a slice's changed behavior through it — that is the only route to `EVIDENCE: live-verified`. You write the generator's output for the next agent, not for a human: it will be read cold, mid-task, by an agent that has never seen the app.

## 1. Interview the repo, not the user

Answer these from the codebase and only ask the user what you cannot observe:

- **Surface:** what does a user actually touch? A web UI, a CLI/TUI, a desktop app, an API, a mobile app, a library? A repo can have several; pick the primary one and note the rest.
- **Run:** how does the app start locally? Prefer the repo's own documented dev command (package scripts, Makefile, README quickstart, vault/project.md gate commands). Note ports, env vars, seed data, auth.
- **Drive:** how can an agent interact with it programmatically? Existing harnesses first — Playwright/Cypress specs, expect scripts, PTY helpers, curl-able endpoints, a debug port. Then the Claude Code drivers. The generated Launch, Drive and Evidence must use drivers the reviewer can run — it has only Bash and the Chrome MCP tools: Bash (curl for HTTP services, the CLI itself, tmux for TUIs, a Playwright script), or the Chrome MCP tools (`mcp__claude-in-chrome__*`: navigate, find, form_input, read_page, computer for screenshots) for web UIs. Use the `run` skill only as a coordinator extra, never the sole driver — a reviewer that can't run the driver can only report verifier-blocked. Name the driver the generated skill uses; a driver the session may not have is a stated precondition, not an assumption.
- **Observe:** what evidence can be captured? Screenshots, terminal transcripts, response bodies, logs, exit codes, DB state.
- **Isolate:** can two instances run side by side (ports, data dirs, profiles)? If not, say so in the generated skill: refusing to double-drive a shared instance beats corrupting the user's session — parallel slice worktrees make this a real collision. A Chrome MCP driver adds a stated precondition: claude-in-chrome must run in a dedicated, signed-out Chrome profile (never the user's everyday one), and only local/dev hosts are reachable — guard.sh blocks navigation anywhere else.

If the checkout doesn't build or start as-is, fix that first (or report it precisely) before generating; a skill written against a broken base teaches wrong steps. When an irrelevant missing asset blocks startup (a static dir the API never serves, a sample config), the generated skill may create it, clearly marked as verification scaffolding, and remove it in cleanup. Secrets come from the environment; never write them into the generated skill.

## 2. Generate the skill

Write `.claude/skills/verify-<project>/SKILL.md` with YAML frontmatter (`name: verify-<project>` and a `description` that names the app, the surface, and when to reach for it — without frontmatter the skill never registers) and these sections, each grounded in what the interview actually found (no placeholders left):

- **Launch:** the exact command that starts the app for verification, and how to tell it's ready (a log line, a port answering, a prompt). Include teardown. For a short-lived CLI or TUI there is no server to keep alive: launch means build the binary (or install deps) once, then start each drive in its own isolated PTY or tmux session.
- **Doctor:** one read-only check that answers "is this instance worth driving?" — process up, right version/build, port owned by us, auth valid. An agent runs this first whenever anything looks off.
- **Drive:** the harness recipe with real selectors/commands from this repo, not examples. Prefer stable handles (ARIA labels, data attributes, prompt strings, route paths) over coordinates and tab order.
- **Evidence:** what to capture for a proof and where it goes. State the proof standards: exercise the real user path, not internal setters or test-only endpoints; capture the action and the resulting state, not just the final screen; verify side effects (files written, rows inserted, messages sent) alongside what's visible; mocks only where a production boundary already isolates the external system. When the safe path is a dry-run or test mode, verify what it actually skips by observing (files, network, git refs) rather than trusting its name: some dry-runs still touch the network or open a browser.
- **Cleanup:** how to tear down instances the run created. Never kill by process name; kill what you started. Cleanup removes instances and scratch state, never the evidence: proof artifacts survive the teardown, in a gitignored location the skill names.
- **Helpers:** any script the skill ships is executable and its invocation is shown in the skill body. A helper the reader has to reverse-engineer is not a helper.

## 3. Seed the feature map

Create `.claude/skills/verify-<project>/features/README.md` plus one file per user-facing feature you can identify (aim for the top 3-5 to start, from routes, commands, menus, docs, or vault/stories.md). Follow the shape in [`references/feature-map-example/`](references/feature-map-example/), with a README index and one file per feature. Each file answers, from the user's point of view: what the feature is, how to reach it, how to drive it with the harness, and what observable end state proves it works. The four H2s are `Sub-features`, `How to get to it (user POV)`, `Driving it with <harness>`, and `Gotchas`. The map is the repo's maintained verification source; a proof that drives one convenient entry point is incomplete when the map lists others.

## 4. Prove the generated skill before handing it over

Run its own instructions end to end once: launch, doctor, drive ONE mapped feature (one is enough; the map exists so later runs can cover the rest), capture evidence, clean up. After cleanup, confirm the evidence still exists at the named location — a cleanup that eats the proof fails this step. Fix what fails, and run the generated cleanup after every failed iteration too, so broken attempts don't strand processes and ports. A generated skill that was never executed is a draft, not a deliverable.

## 5. Ship and offer the maintenance loop

Commit the generated skill like any other change (`feat(verify): add verify-<project> skill`, on a branch per the protocol). Point the user at `/maintain-verification-skill` for keeping the map honest as the app changes; architecture-review suggests it at its 5-slice cadence.
