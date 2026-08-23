# Sample User Stories

## Good

### User Story 042:

- **Summary:** Enable Google login for trial users to reduce signup friction

#### Use Case:
- **As a** trial user visiting the app for the first time
- **I want to** log in using my Google account
- **so that** I can access the app without creating and remembering a new password

#### Acceptance Criteria:
- **Scenario:** First-time trial user logs in via Google OAuth
- **Given:** I am on the login page
- **and Given:** I have a Google account
- **When:** I click "Sign in with Google" and authorize the app
- **Then:** I am logged into the app and redirected to the onboarding flow

---

## Bad — restates the action, doesn't explain why

- **As a** user
- **I want to** click the save button
- **so that** I can save my work

Fix: "so that I don't lose my progress if the page crashes."

## Bad — technical task, no user-facing outcome

- **As a** developer
- **I want to** refactor the database layer
- **so that** the code is cleaner

This is an engineering task, not a story. Skip this skill for it.

## Bad — untestable Then

- **Then** the user has a better experience

Fix: "Then the page loads in under 2 seconds."

## Needs splitting — multiple When/Then pairs

- **When** I add an item to my cart **Then** the cart count updates
- **When** I remove an item **Then** the cart count updates
- **When** I apply a coupon **Then** the total recalculates

Three scenarios, three stories. One When/Then per story.
