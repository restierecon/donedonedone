---
name: user-story
description: Write user stories in Mike Cohn format with Gherkin acceptance criteria. Use when turning a user need into a slice's title/so_that and acceptance_criteria, or whenever asked to write a user story.
---

# User Story

Format:

```
As a [specific persona, not "user"]
I want to [action]
so that [outcome — the motivation, not a restatement of the action]
```

Acceptance criteria, Gherkin:

```
Scenario: [one sentence]
Given [precondition]
and Given [more preconditions as needed]
When [the one triggering event — matches "I want to"]
Then [the one expected outcome — matches "so that"]
```

## Rules
- Persona specific ("trial user", "org admin"), never generic "user."
- "So that" states motivation, not the action again. `"I want to click save, so that I save"` is not a story.
- Exactly one When, one Then per scenario. Multiple Whens/Thens = multiple stories — split it.
- Then must be verifiable (`"loads in under 2s"`, not `"is faster"`).
- Not a story: no user-facing outcome ("as a developer, refactor the DB") → that's an engineering task, skip this skill.

## In this workflow
This produces exactly the fields slice-planning needs: title ("Actor can...") and
`so_that` come straight from the Use Case; Gherkin scenarios become
`acceptance_criteria` entries (one bullet per Given/When/Then group). Write the
story before calling slice-planning, not after — a slice whose `so_that` you can't
state as real user motivation isn't a slice yet.

## Example
```
As a trial user visiting for the first time
I want to log in with my Google account
so that I can access the app without creating a new password

Scenario: First-time trial user logs in via Google OAuth
Given I am on the login page
and Given I have a Google account
When I click "Sign in with Google" and authorize
Then I am logged in and redirected to onboarding
```
