# Design rationale

Why the harness is shaped the way it is. Each section states a decision, the problem it solves, and
the rule that enforces it. The per-incident evidence is in
[`reference/rule-histories.md`](reference/rule-histories.md); this file is the argument, not the
forensics.

---

## Agents are config-driven, not per-project

A pipeline agent that hardcodes `pnpm test` works in one repo. The alternative most people reach
for — a copy of the agent in every project — means a fix to the commit agent has to be applied N
times, and drifts the moment it isn't.

So each agent's first step reads an `## Agent Config` table from the current project's
`CLAUDE.md`: commands, thresholds, branch pattern, merge labels. One set of agents spans Python,
TypeScript, Swift and Go, and `(none)` is a first-class value meaning "this project has no such
capability" — which is what makes the same pipeline usable in a repo with no tests and no CI.

Project files carry **parameters**, not restated policy. A project that copies a rule's text
inherits that rule as of the day it was copied and never hears about the revision; that is not
hypothetical — see the entry for `claude-md-project-templates` in the rule histories.

→ [`templates/agent-config.md`](../templates/agent-config.md),
[`rules/claude-md-project-templates.md`](../rules/claude-md-project-templates.md)

## The global `CLAUDE.md` is versioned here

`~/.claude/CLAUDE.md` is loaded into *every* session on the machine. An unversioned edit to it is
an unversioned change to how every project behaves, with no diff, no review, and no way back.
Keeping it in this repo makes it reviewable like any other change.

The cost is real and worth naming: `~/.claude/rules` is a **symlink into the working tree**, so
checking out a branch swaps the live ruleset under every running session. There is no staging
environment for a rule.

## Gate once per tree, then consume the result

The lint+test+build triple is expensive, and a pipeline of agents each independently "making sure"
will run it three or four times per branch. Worse, when two runs disagree, nothing says which one
counted.

So the gate runs **once per working tree**, by whoever reaches it first, and records a line
(`VERIFY RESULT: PASS sha=… tree=…`). Every later step cites that line instead of re-running. The
hash is of the working tree, not the commit, so one record survives commit → PR → merge as long as
no file changed — and stops being valid the instant one does.

Re-running a gate is therefore the *default failure mode* this contract exists to prevent, not a
harmless extra.

→ [`rules/pipeline-contract.md`](../rules/pipeline-contract.md)

## A green must be able to be red

The failure that motivates more of this repository than any other is not "the check didn't run" —
it's "the check ran, could never have failed, and got reported as evidence."

`pnpm verify 2>&1 | tail -40` reports the exit status of `tail`. It is always 0. It was run twice
on a real PR, reported green twice, and lint was failing the whole time. A skipped check is
visibly missing; a fake green is invisibly wrong.

The generalization matters more than the pipe: before reporting any check as evidence, ask whether
it *could* have failed. For a guard that pins a load-bearing constraint, mutate the source, watch
the test go red, restore. Seconds of work, and it converts "the test passes" into "the test
catches this."

The same disease infects instruments — monitors, counters, health checks — and there it is worse,
because you consult an instrument precisely when you are not watching. An instrument that cannot
tell "healthy" from "not looking" is reporting *unknown* dressed as *good*.

→ [`rules/verification-integrity.md`](../rules/verification-integrity.md)

## Rules are split by load cost, not by topic

Every always-loaded rule is paid for on every turn of every session, forever. That is a real
budget, and it is the reason this repo does not simply keep adding guidance.

Rules with a `paths:` frontmatter block load only when a matching file is read. Everything else
loads always — and earns it by covering a surface that has no path to trigger on. Commit messages
and PR bodies are the clearest case: nothing is "opened" when one is written, so a rule about them
cannot be path-scoped.

Incident evidence lives in `docs/reference/`, which is **not** symlinked into `~/.claude/` at all.
It used to live in `<!-- HISTORY -->` comments inside the rule files; HTML comments are still
tokens.

## Codex-first: Claude orchestrates, OpenAI models build

Two model budgets exist, and they are not interchangeable. The harness spends the OpenAI allowance
on implementation, debugging, review and research, and keeps Claude for what only the orchestrator
can do: decide, delegate, verify, gate, commit.

The second Claude budget is subtler and easier to blow: **context**. A 2,000-line file read once is
re-sent on every turn that follows. So handoffs ask Codex for a *file* rather than a monologue, use
compact output contracts, and prefer fewer, larger tasks over many clarifying round trips. "Do not
pre-read the repo to write the prompt" is a cost rule, not a style preference.

What stays in Claude is genuinely short: the orchestrator's own turn, tools Codex cannot reach, and
the bookkeeping — beads, git state, PR flow, and **running** the gate. The gate stays here for
correctness, not cost: a gate is only evidence when run by the party reporting it.

→ `## Model Routing` in [`global/CLAUDE.md`](../global/CLAUDE.md),
[`rules/codex-dispatch-protocol.md`](../rules/codex-dispatch-protocol.md),
[`rules/codex-job-status-integrity.md`](../rules/codex-job-status-integrity.md)

## A background job's status is not its liveness

Delegation made this load-bearing. A wrapper that returns is not a job that finished, and a wrapper
still running is not a job still working. Liveness is the worker PID plus the log file — nothing
else. A status of `unknown`/`orphaned` means the worker died mid-job; it is an integrity incident,
not a pending result, and never grounds for reporting the work done or silently launching a
duplicate.

Waiting is a PID bridge that wakes once, never a polling loop in the transcript.

→ [`rules/codex-dispatch-protocol.md`](../rules/codex-dispatch-protocol.md)

## Review is bounded, and the bound is mechanical

"Repeat until GO" cannot fail. It produced a pull request with twelve adversarial review rounds and
22 commits, three of whose defects came from its own fixes, in a session that emitted 2,360
assistant messages.

Review is now capped at three rounds; rounds two and three resume the *same* reviewer thread,
because a fresh reviewer re-derives the diff and finds adjacent things instead of converging. Each
finding gets one triage line — FIX, BEAD, or UNVERIFIED — and the fixing is a delegated task, not
orchestrator work. A fourth round requires the owner's words, quoted into the acknowledgement the
gate parses.

Honest result: **the cap stops the loop; it has not made review converge faster.** Every sample
reached the cap and needed a person. That is recorded rather than smoothed over.

→ [`rules/branch-completion-review.md`](../rules/branch-completion-review.md),
[`retrospectives/`](retrospectives/)

## Selftests are the gate; there is no CI

This repo has no server-side CI, so "green" means every selftest under
[`../CLAUDE.md`](../CLAUDE.md) § The gate passed at a real exit code, captured by redirect and
never through a pipe.

Each selftest is hermetic — temp directories, no network, no real Codex runtime — and each carries
a completion sentinel. That last detail is not ceremony: on bash 3.2 a script killed by `set -e` or
`set -u` runs its EXIT trap with `$?` already reset to 0, so before the sentinel every *aborting*
selftest read as PASS.

Zero resolved selftests is also a failure. A green must have run something.

→ [`../scripts/verify.sh`](../scripts/verify.sh)

## Parallel work is isolated by worktree, and serialized where the resource is shared

Two sessions in one checkout collide on branch state. Two sessions on one machine collide on things
a worktree does not isolate: the window server, the toolchain, caches.

So git state is isolated per worktree, machine resources are serialized by a lock, and peers
message each other directly — scoped by what is actually shared, and bounded in size, because the
observed failure mode was not a corrupted tree but a user turned into a message bus between agents
that could have asked each other.

→ [`rules/agent-isolation.md`](../rules/agent-isolation.md),
[`rules/windowed-gate-serialization.md`](../rules/windowed-gate-serialization.md),
[`rules/peer-session-coordination.md`](../rules/peer-session-coordination.md)

## Private identities never reach a public surface

This repository is public and its subject matter is private work. Real project, client and ticket
names are replaced by purpose-based pseudonyms, and the substitution table lives outside any repo.

The rule alone would not hold — this archive's own history is blunt about targets that nothing
counts. So it is enforced by `scripts/name-hygiene.sh`, which scans tracked files *and commit
messages* against a hashed denylist and fails the same gate a broken test would.

→ [`rules/public-surface-hygiene.md`](../rules/public-surface-hygiene.md), [`README.md`](README.md)
