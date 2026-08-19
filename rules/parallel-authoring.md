---
paths:
  - "**/.claude/skills/**"
  - "**/.claude/agents/**"
  - "**/.claude/rules/**"
  - "**/*worktree*"
---
# Parallel Authoring (Fan-Out for Independent Additive Work)

When a task splits into several independent, additive work items that share one expensive verification gate, author them with parallel sub-agents on a single branch, then run the gate once on the consolidated result — N agents write, one orchestrator verifies and ships. Handling those items sequentially would mean N runs of the same expensive gate and would leave the available authoring parallelism unused. (Measured payoff: `~/projects/cc-harness/docs/reference/rule-histories.md`.)

## When it applies

Use parallel authoring when ALL of these hold:

| # | Condition | Why it matters |
|---|---|---|
| 1 | The task splits into ≥2 items that are mutually independent — no item consumes another's output | Dependent items must be sequenced; parallel agents cannot see each other's work |
| 2 | Each item's changes are additive and touch a disjoint set of files | Two agents writing the same file clobber each other — there is no merge step between sub-agents |
| 3 | The items share one expensive verification gate, cheaper to run once on the union than N times | This is the payoff; without a shared expensive gate the pattern's only benefit is authoring concurrency |

## When it does NOT apply

| Situation | Do this instead |
|---|---|
| Items interdepend (item B needs item A's output) | Sequence them, or parallelize only the independent subset |
| Two items must edit the same file | Sequence those two, or have one agent own the shared file and others depend on it |
| Each item genuinely needs its own gate run / its own PR for independent review or rollback | Separate branches, separate PRs — accept the N gate runs |
| The work is exploratory and the file set is not known up front | Author serially until the shape is clear, then fan out the remainder |

## Procedure

1. **Branch once.** One feature branch off `origin/<integration>` for the whole batch (see `branch-discipline.md`); all items land there.
2. **Fan out.** Spawn one sub-agent per item, all in a single message so they run concurrently. Each prompt is self-contained (see `agent-purpose-statements.md`) and states:
   - exactly which files to create/edit — a disjoint set per agent;
   - that it must **author files only** — no `git`, no running the expensive gate, no issue-tracker mutations;
   - that it may run cheap local self-checks (syntax check, `bash -n`, a type-check scoped to its own files);
   - enough context to make judgment calls without the orchestrating conversation.
3. **Fan in.** Verify the files actually exist and are correct — an agent's summary is its intent, not a guarantee.
4. **Gate once, cascading.** Run the shared gate a single time on the consolidated branch, narrowest stage first, widening only after each stage passes (e.g. unit → integration → full). Fix any failure before widening.
5. **Commit per item.** One commit per work item despite the shared branch — preserves per-item traceability and the issue-tracker mapping. Delegate to the commit agent (see `agent-enforcement.md`).
6. **One PR.** A single PR for the batch; CI runs once. Merge, then close all the items' issues.

## The tradeoff: batch isolation, not per-item isolation

Gating once on the union attributes a failure to the batch, not to one item, so the orchestrator takes on the duty to **diagnose which item caused it** — by reading the failure, re-running the failing case in isolation, or bisecting the per-item commits (which is why step 5's clean per-item commits matter). Cheaper in aggregate than N gate runs, but not free: if the items are likely to interact subtly, prefer per-item gates.

## Relationship to other rules

- `agent-isolation.md` — no per-agent worktree here: safety comes from disjoint file sets plus no-git-in-sub-agents, and the orchestrator does all git work serially after fan-in. If the orchestrating *session* may overlap with other sessions, that session still wraps its whole pipeline in a worktree.
- `branch-discipline.md` / `agent-enforcement.md` / `agent-purpose-statements.md` — one feature branch created before the first edit; commits still go through the commit agent (N commits on one branch); each fanned-out agent gets a purpose statement.
- `windowed-gate-serialization.md` — if the shared or per-item gate opens real application windows, those stages funnel through one serialized stream with a machine-global lock.
