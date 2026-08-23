#!/usr/bin/env python3
"""Print a filled-in user-story Markdown stub. No network, no file writes."""

import argparse


def render(persona: str, action: str, outcome: str) -> str:
    return (
        "### User Story [ID]:\n\n"
        "- **Summary:** [Brief, memorable title focused on value to the user]\n\n"
        "#### Use Case:\n"
        f"- **As a** {persona}\n"
        f"- **I want to** {action}\n"
        f"- **so that** {outcome}\n\n"
        "#### Acceptance Criteria:\n"
        "- **Scenario:** [one sentence]\n"
        "- **Given:** [precondition]\n"
        "- **When:** [the one triggering event]\n"
        "- **Then:** [the one verifiable outcome]\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--persona", required=True, help='e.g. "trial user"')
    parser.add_argument("--action", required=True, help='e.g. "log in with Google"')
    parser.add_argument(
        "--outcome", required=True, help='e.g. "access the app without a new password"'
    )
    args = parser.parse_args()
    print(render(args.persona, args.action, args.outcome))


if __name__ == "__main__":
    main()
