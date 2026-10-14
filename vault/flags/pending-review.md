# Pending Review

## ESCALATED: gate.test is red on main inside gate.sh (blocks every slice)
- What: 2 of 637 run-tests.sh cases pass standalone but fail when the suite runs inside gate.sh in this (now vault) repo.
- Affects: every slice; the Director's gate can't go green on main.
- Cost to reverse: one small test-isolation slice; nothing shipped depends on it.
- tests/run-tests.sh:60-63 + :169 — guard_agent runs guard.sh from the repo root, which now has vault/, so the builder brief without SLICE: is blocked.
- tests/run-tests.sh:723-729 — the outer gate exports PYTEST_XDIST_AUTO_NUM_WORKERS=4; the inner gate.sh keeps it (xdist=4, expected 3).
- Next: one-question /grill (bugfix), then a slice. Decide whether gate.sh should override inherited worker knobs or the test should unset them.

## SLICE: gate steps the repo can't support yet
- What: gate.test.focus, gate.crap and gate.mutation have no line.
- Affects: builders run the full suite mid-loop; no CRAP or mutation evidence on any slice (Python is 70% of production lines).
- Cost to reverse: tooling slices, no behaviour change.
- run-tests.sh takes no filter argument → no gate.test.focus.
- Python scripts are tested through shell suites and unittest, with no pyproject.toml or coverage run → crap and mutation need coverage wiring and mutmut config.
- Bash has no practical mutation tool: record gate.mutation scope for Bash as a /grill decision.

## TOOL: machine tools for the gate
- What: shellcheck, gitleaks, semgrep, lizard, coverage, mutmut were missing in this container (installed by hand this session; lost on restart).
- Affects: gate.lint and the planned security step fail closed without them.
- Cost to reverse: one setup-script edit.
- Add to the cloud environment's setup script: `apt-get install -y shellcheck && pip install lizard coverage mutmut semgrep` plus gitleaks from its release binary.
