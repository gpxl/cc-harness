# Design rationale

This page explains the decisions behind the harness and points to the rules that enforce them.
For incident-level evidence, see
[`reference/rule-histories.md`](reference/rule-histories.md).

## Agents are config-driven, not per-project

A pipeline agent that hardcodes `pnpm test` works in one repository. Copying that agent into every
project creates a maintenance problem: every fix must be repeated, and the copies drift.

Instead, each agent first reads an `## Agent Config` table from the current project's
`CLAUDE.md`: commands, thresholds, branch pattern, merge labels. One set of agents spans Python,
TypeScript, Swift and Go, and `(none)` is a first-class value meaning "this project has no such
capability." The same pipeline can therefore work in a repository with no tests or CI.

Project files carry parameters, not copied policy. A copied rule freezes on the day it was copied
and misses later revisions. This has happened; see `claude-md-project-templates` in the rule
histories.

→ [`templates/agent-config.md`](../templates/agent-config.md),
[`rules/claude-md-project-templates.md`](../rules/claude-md-project-templates.md)

## The global `CLAUDE.md` is versioned here

`~/.claude/CLAUDE.md` loads into every session on the machine. An unversioned edit changes every
project with no diff, review, or easy rollback. Keeping the file here makes those changes
reviewable.

There is a tradeoff: `~/.claude/rules` is a symlink into the working tree. Checking out a branch
changes the live ruleset beneath every running session. Rules have no staging environment.

## Gate once per tree, then consume the result

Lint, tests, and build are expensive. If every pipeline agent independently "makes sure," the same
gate runs three or four times per branch. If those runs disagree, it is unclear which one counts.

The gate therefore runs once per working tree, by whoever reaches it first, and records a line
(`VERIFY RESULT: PASS sha=… tree=…`). Every later step cites that line instead of re-running. The
hash is of the working tree, not the commit, so one record survives commit → PR → merge as long as
no file changed — and stops being valid the instant one does.

An unnecessary rerun is not harmless; it is the failure mode this contract prevents.

→ [`rules/pipeline-contract.md`](../rules/pipeline-contract.md)

## A green must be able to be red

The most dangerous failure here is not a check that never ran. It is a check that could never fail
but was reported as evidence.

`pnpm verify 2>&1 | tail -40` reports the exit status of `tail`, which is 0. On a real PR, that
command reported green twice while lint was failing. A skipped check is visibly absent; a false
green is quietly wrong.

The lesson is broader than pipelines: before treating a check as evidence, establish that it could
fail. For a guard protecting a load-bearing constraint, mutate the source, watch the test go red,
then restore it. That turns "the test passes" into "the test catches this."

The same problem affects monitors, counters, and health checks. An instrument that cannot
distinguish "healthy" from "not looking" reports unknown as good.

→ [`rules/verification-integrity.md`](../rules/verification-integrity.md)

## Rules are split by load cost, not by topic

Always-loaded rules consume context on every turn of every session. That cost is why the harness
does not keep adding guidance without limit.

Rules with a `paths:` frontmatter block load only when a matching file is read. Always-loaded rules
cover surfaces without a path trigger. Commit messages and PR bodies are the clearest examples:
nothing is opened when they are written, so their rules cannot be path-scoped.

Incident evidence lives in `docs/reference/`, which is not symlinked into `~/.claude/`. It once
lived in `<!-- HISTORY -->` comments inside the rules, but HTML comments still consume tokens.

## Codex-first: Claude orchestrates, OpenAI models build

The harness treats Claude and OpenAI model budgets separately. It spends the OpenAI allowance on
implementation, debugging, review, and research, reserving Claude for orchestration: deciding,
delegating, verifying, gating, and committing.

Context is the second Claude budget. A 2,000-line file read once is sent again on every later turn.
Handoffs therefore ask Codex for a file rather than a monologue, use compact output contracts, and
favor fewer, larger tasks. The instruction not to pre-read the repository before writing a prompt
is about cost, not style.

Claude keeps the orchestrator's turn, tools Codex cannot reach, and bookkeeping such as beads, git
state, PR flow, and running the gate. The gate stays with the orchestrator for correctness: a gate
is evidence only when the reporting party ran it.

→ `## Model Routing` in [`global/CLAUDE.md`](../global/CLAUDE.md),
[`rules/codex-dispatch-protocol.md`](../rules/codex-dispatch-protocol.md),
[`rules/codex-job-status-integrity.md`](../rules/codex-job-status-integrity.md)

## A background job's status is not its liveness

Delegation makes job liveness load-bearing. A returned wrapper does not prove the job finished,
and a running wrapper does not prove the job is working. Liveness is the worker PID plus its log.
An `unknown` or `orphaned` status means the worker died mid-job. It is an integrity incident, not a
pending result, and cannot justify reporting completion or silently launching a duplicate.

Waiting uses a PID bridge that wakes once, not a polling loop in the transcript.

→ [`rules/codex-dispatch-protocol.md`](../rules/codex-dispatch-protocol.md)

## Review is bounded, and the bound is mechanical

"Repeat until GO" has no stopping condition. One pull request reached twelve adversarial review
rounds and 22 commits; three defects came from the review's own fixes. The session produced 2,360
assistant messages.

Review now stops after three rounds. Rounds two and three resume the same reviewer thread; a fresh
reviewer tends to re-derive the diff and find adjacent issues instead of converging. Each finding
gets one triage line: FIX, BEAD, or UNVERIFIED. Fixes are delegated rather than handled by the
orchestrator. A fourth round requires the owner's exact words in the acknowledgement parsed by the
gate.

The cap stops the loop; it has not made review converge faster. Every sample reached the cap and
needed a person. The record says so plainly.

→ [`rules/branch-completion-review.md`](../rules/branch-completion-review.md),
[`retrospectives/`](retrospectives/)

## Selftests are the gate; there is no CI

This repository has no server-side CI. "Green" means every selftest under
[`../CLAUDE.md`](../CLAUDE.md) § The gate passed at a real exit code, captured by redirect and
never through a pipe.

Each selftest is hermetic: it uses temporary directories, no network, and no real Codex runtime.
Each also carries a completion sentinel. On bash 3.2, a script killed by `set -e` or `set -u` runs
its EXIT trap with `$?` already reset to 0; without the sentinel, every aborting selftest appeared
to pass.

Resolving zero selftests is also a failure. A green result must have run something.

→ [`../scripts/verify.sh`](../scripts/verify.sh)

## Parallel work is isolated by worktree, and serialized where the resource is shared

Two sessions in one checkout collide on branch state. Worktrees solve that, but two sessions on one
machine can still collide on the window server, toolchain, and caches.

Git state is therefore isolated by worktree, shared machine resources are serialized by a lock,
and peers message each other directly. Messages stay scoped to the shared resource and remain
brief. The observed failure was not a corrupted tree, but a user forced to relay messages between
agents that could have spoken directly.

→ [`rules/agent-isolation.md`](../rules/agent-isolation.md),
[`rules/windowed-gate-serialization.md`](../rules/windowed-gate-serialization.md),
[`rules/peer-session-coordination.md`](../rules/peer-session-coordination.md)

## Private identities never reach a public surface

This public repository describes private work. Project, client, and ticket names use purpose-based
pseudonyms; the substitution table lives outside every repository.

A written rule was not enough. `scripts/name-hygiene.sh` now checks tracked files and commit
messages against a hashed denylist, failing the same gate as a broken test.

→ [`rules/public-surface-hygiene.md`](../rules/public-surface-hygiene.md), [`README.md`](README.md)
