# Agent Pipeline Enforcement

When a project has an `## Agent Config` table in its CLAUDE.md, the agent pipeline is **mandatory** for all git operations. This rule applies globally across all projects.

## Manual Git Operations Are Prohibited

**NEVER run `git add`, `git commit`, or `git push` directly.** All commits must go through the agent pipeline. Never bypass this with manual git commands.

| Trigger phrase | Action |
|----------------|--------|
| "commit", "push", "ship it" | Invoke code-quality agent → commit agent |
| "yes" (confirming a commit) | Same pipeline — not a shortcut to manual git |
| "save this", "check this in" | Same pipeline |

## Mandatory Pipeline

```
code change → code-quality (evaluate) → FAIL? → test-writer → code-quality (re-verify)
                                       → PASS  → commit agent (stage, commit, push, open PR)
                                                   → pr-monitor (watch CI, merge on green)
                                                       → release (evaluate, tag if warranted)
```

| Step | Agent | Required? |
|------|-------|-----------|
| 1 | code-quality | **Yes** for source files matching `quality_gate_pattern` |
| 2 | test-writer | Only if code-quality reports FAIL |
| 3 | commit | **Always** — handles staging, committing, pushing, and PR creation |
| 4 | pr-monitor | When PR is opened — watches CI, merges on green |
| 5 | release | After merge to main — evaluates if release is needed |

### Exemptions

The **code-quality gate** (step 1) is exempt when changes ONLY touch:
- Test files
- Documentation (README, CLAUDE.md, rules/)
- Config files (pyproject.toml, ruff.toml, etc.)
- Generated output (themes/, dist/, build/)

The **commit agent** (step 3) is **never exempt** — even doc-only changes must use the commit agent, not manual git commands.

## Why This Exists

Manual `git commit` bypasses quality gates (coverage, lint, test quality Q1-Q8) that the agent pipeline enforces. Even when the code-quality gate is exempt (e.g., doc changes), using the commit agent ensures consistent commit formatting, proper branch workflow, and PR creation.

## Project-Specific Rules

Each project's `.claude/rules/agents.md` (or equivalent) defines:
- Which files trigger the code-quality gate (`quality_gate_pattern`)
- Coverage thresholds (`coverage_per_module`, `coverage_overall`)
- Failure recovery policy (max retries before asking user)
- Merge policy (feature PRs never auto-merged)

See the project's CLAUDE.md `## Agent Config` table for all configuration keys.
