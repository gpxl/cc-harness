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
code change → code-quality (evaluate) → FAIL? → test-writer → code-quality (re-verify)
              [skipped when quality_gate_pattern is (none): verify_cmd → VERIFY RESULT instead]
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
| 4 | pr-monitor | Only when the project **has** CI. If Agent Config `ci` is `none`, skip it — it exists to poll checks that don't exist; the orchestrator merges on the recorded verify instead, **and takes over pr-monitor's branch-cleanup half of the job too** — see Branch cleanup below |
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

### Branch cleanup on merge

Every merge deletes the merged feature branch — whether `pr-monitor` performs the merge or the
orchestrator does. This applies globally, in every project, regardless of whether that project's
own rules say anything about it: a merged branch left lying around is dead weight the next session
has to work around (`agent-isolation.md`'s collision preflight spends a step checking for exactly
this kind of stale branch).

`pr-monitor`'s own contract already deletes the branch it merges (`gh pr merge <PR> --squash
--delete-branch`). When step 4 is skipped (`ci: none`) and the orchestrator merges directly instead,
that half of pr-monitor's job does not disappear along with it — it falls to the orchestrator:

| After merging | Do |
|---|---|
| Remote branch | `gh pr merge <PR> --squash --delete-branch` when merging directly; `git push origin --delete <branch>` if it was merged some other way and the remote branch still exists |
| Local branch (main checkout, not a worktree) | Switch off it first if it's checked out (`git checkout <integration-branch> && git merge --ff-only origin/<integration-branch>`), then `git branch -d <branch>`. A **squash** merge leaves the branch tip unreachable from the new integration-branch commit, so `-d` correctly refuses with "not fully merged" — verify the content actually landed (e.g. `grep` for something the branch added, or diff the touched paths against the integration branch) before overriding with `git branch -D <branch>`. Don't force-delete on faith. |
| Worktree, if the pipeline used one | Already handled by `agent-isolation.md`'s lifecycle (`trap ... EXIT` removes it on every exit path, and the orphan reaper catches anything a crash left behind) — nothing extra to do here |

Leave alone: branches other sessions still have checked out (`git worktree list` shows a `+`
against them — that is someone else's in-progress work, not yours to clean up), and any branch
whose PR has not actually merged yet.

## Project-Specific Rules

Each project's `.claude/rules/agents.md` (or equivalent) defines:
- Which files trigger the code-quality gate (`quality_gate_pattern`)
- Coverage thresholds (`coverage_per_module`, `coverage_overall`)
- Failure recovery policy (max retries before asking user)
- Merge policy (feature PRs never auto-merged)

See the project's CLAUDE.md `## Agent Config` table for all configuration keys.
