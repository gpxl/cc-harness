# Agent Pipeline Enforcement

When a project has an `## Agent Config` table in its CLAUDE.md, the agent pipeline is **mandatory** for all git operations. This rule applies globally across all projects.

## Manual Git Operations Are Prohibited

**NEVER run `git add`, `git commit`, or `git push` directly.** All commits must go through the agent pipeline. Never bypass this with manual git commands.

### Commit-Agent Standing Authorization

The commit agent is pre-authorized in every project and every session: invoking it needs no per-session permission or confirmation prompt. Do not ask “shall I commit?” — when work is complete and its required gates are green, run the pipeline.

A general session-level restriction on spawning agents does not exempt commits. The commit agent is the sanctioned mechanism for a mandatory operation, not discretionary extra fan-out; “don't spawn agents” cannot mean commit by hand, nor can it mean leave completed work uncommitted.

This standing authorization covers staging, committing, pushing the feature branch, and opening the PR. It does not cover merging, force-pushing, pushing directly to an integration branch, or destructive history rewrites; those retain their existing gates.

The precondition is unchanged: required gates must be green first, including `CODE QUALITY RESULT: PASS` where the quality gate applies (see `pipeline-contract.md`). Standing authorization removes the permission question, never the gate.

| Trigger phrase | Action |
|----------------|--------|
| "commit", "push", "ship it" | Invoke code-quality agent → commit agent (**skip code-quality when `quality_gate_pattern` is `(none)`** — run `verify_cmd` and record `VERIFY RESULT:` instead) |
| "yes" (confirming a commit) | Same pipeline — not a shortcut to manual git |
| "save this", "check this in" | Same pipeline |

## Mandatory Pipeline

```
code change → code-quality (evaluate; skipped when quality_gate_pattern is (none) — verify_cmd instead)
                                       → FAIL? → test-writer → code-quality (re-verify)
                                       → PASS  → commit agent (stage, commit, push, open PR)
                                                   → pr-monitor  [only if Agent Config ci ≠ none]
                                                       → release [only if version_strategy ≠ none]
```

The lint+test+build triple runs **once** across this whole chain, recorded and then consumed — see `pipeline-contract.md`.

| Step | Agent | Required? |
|------|-------|-----------|
| 1 | code-quality | **Yes** for source files matching `quality_gate_pattern`; **never** when that key is `(none)` — see Exemptions |
| 2 | test-writer | Only if code-quality reports FAIL |
| 3 | commit | **Always** — handles staging, committing, pushing, and PR creation |
| 4 | pr-monitor | Only when the project **has** CI. If Agent Config `ci` is `none`, skip it — it exists to poll checks that don't exist; the orchestrator merges on the recorded verify instead |
| 5 | release | After merge to main, and only if `version_strategy` is not `(none)` |

### Exemptions

The **code-quality gate** (step 1) is exempt when changes ONLY touch:
- Test files
- Documentation (README, CLAUDE.md, rules/)
- Config files (pyproject.toml, ruff.toml, etc.)
- Generated output (themes/, dist/, build/)

**`quality_gate_pattern: (none)` skips step 1 entirely.** Do not invoke the code-quality agent
by reflex: with no pattern there is nothing for it to gate, the commit agent's own Step 2 already
finds no matching files, and the agent degrades to a Haiku process wrapping two shell commands.
The orchestrator runs `verify_cmd` (or the fallback triple) once, redirect-to-file, records
`VERIFY RESULT: PASS|FAIL sha= tree=`, and the commit agent consumes it (`pipeline-contract.md`).

The **commit agent** (step 3) is **never exempt** — even doc-only changes must use the commit agent, not manual git commands.

Manual `git commit` bypasses quality gates (coverage, lint, test quality Q1-Q8) that the agent pipeline enforces.

## Project-Specific Rules

Each project's `.claude/rules/agents.md` (or equivalent) defines:
- Which files trigger the code-quality gate (`quality_gate_pattern`)
- Coverage thresholds (`coverage_per_module`, `coverage_overall`)
- Failure recovery policy (max retries before asking user)
- Merge policy (feature PRs never auto-merged)

See the project's CLAUDE.md `## Agent Config` table for all configuration keys.
