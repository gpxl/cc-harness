# Parallel Authoring (Fan-Out for Independent Additive Work)

When a task splits into several independent, additive work items that share one
expensive verification gate, author them with parallel sub-agents on a single
branch, then run the gate once on the consolidated result. This is a
fan-out/fan-in pattern: N agents write in parallel, one orchestrator verifies
and ships.

## Why this rule exists

The naive approach to N independent work items is sequential: take item 1 end to
end (author → gate → commit → PR), then item 2, and so on. When each item must
pass an expensive shared gate (a full test suite, an eval suite, CI), that is N
expensive gate runs — and on the agentic side, sequential authoring leaves most
of the available parallelism unused.

The items are usually independent: each adds new files, none depends on
another's output, and no two touch the same file. Independent additive work has
no reason to be serialized. Authoring it in parallel and verifying it once
collapses N gate runs into one and N authoring passes into wall-clock-one.

Measured on a real run (CMS phases 9d–9h, May 2026): five workflow-skill
beads, each a new skill file plus two eval scenarios. Five parallel authoring
agents and one consolidated `eval/run.sh all` replaced five sequential ~60-min
gate runs — roughly 3–6 h saved — and avoided compounding a known eval-pool
flake by running the heavy gate once instead of five times.

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

1. **Branch once.** Create a single feature branch off `origin/<integration>`
   for the whole batch (see `branch-discipline.md`). All items land here.
2. **Fan out.** Spawn one sub-agent per item, all in a single message so they
   run concurrently. Each agent's prompt is self-contained (see
   `agent-purpose-statements.md`) and states:
   - exactly which files to create/edit — a disjoint set per agent;
   - that it must **author files only** — no `git`, no running the expensive
     gate, no issue-tracker mutations;
   - that it may run cheap local self-checks (syntax check, `bash -n`, a
     type-check scoped to its own files);
   - enough context to make judgment calls without the orchestrating
     conversation.
3. **Fan in.** When all agents return, the orchestrator verifies the actual
   files exist and are correct — trust but verify; an agent's summary is its
   intent, not a guarantee.
4. **Gate once, cascading.** Run the shared verification gate a single time on
   the consolidated branch, narrowest stage first, widening only after each
   stage passes (e.g. unit → integration → full). Diagnose and fix any failure
   before widening.
5. **Commit per item.** One commit per work item even though they share a
   branch — this preserves per-item traceability in history and keeps the
   issue-tracker mapping clean. Delegate to the commit agent (see
   `agent-enforcement.md`).
6. **One PR.** Open a single PR for the batch; CI runs once. Merge, then close
   all the items' issues.

## The tradeoff: batch isolation, not per-item isolation

Running the gate once on the union means a failure is attributed to the batch,
not to one item. The orchestrator accepts the duty to **diagnose which item
caused a failure** — by reading the failure, by re-running the failing case in
isolation, or by bisecting the per-item commits. This is cheaper in aggregate
than N gate runs, but it is not free: if the items are likely to interact in
subtle ways, prefer per-item gates. Keeping the per-item commits clean (step 5)
is what makes bisection possible.

## Relationship to other rules

- **`agent-isolation.md`** — that rule is about *concurrent sessions / scheduled
  routines* corrupting a shared working tree through git operations, solved with
  worktrees. Parallel authoring is different: it is *one session* spawning
  sub-agents that **only write files**, to **disjoint paths**, performing **no
  git operations**. No per-agent worktree is needed — the safety comes from
  disjoint file sets plus the no-git-in-sub-agents rule, and the orchestrator
  does all git work serially after fan-in. The two rules compose: if the
  orchestrating *session itself* may overlap with other sessions, that session
  still wraps its whole pipeline in a worktree per `agent-isolation.md`.
- **`branch-discipline.md`** — the batch uses one feature branch, created before
  the first edit. Unchanged.
- **`agent-purpose-statements.md`** — each fanned-out agent gets a purpose
  statement: why it is invoked and how its output will be used.
- **`agent-enforcement.md`** — commits still go through the commit agent; the
  only change is N commits on one branch instead of N branches.
