# Codex integration and unbounded review loops

**Period:** 29 August – 5 September 2026 · **Repos:** StemLab, cc-harness · **Published:** 2026-09-05
**Shareable rendering:** <https://claude.ai/code/artifact/90a4771d-cb2d-4d73-9e7f-63ec43b1dc5d>

First entry in this series, so there is no previous follow-through section. Sources: 30 StemLab
pull requests, the merge-gate acknowledgement ledger (277 rows), `docs/reference/rule-histories.md`,
`docs/reference/loop-baseline-2026-09.md`, targeted transcript searches, and `loop-report.sh`
/ `routing-report.sh` runs on 5 September.

## Summary

| | |
|---:|---|
| **12** | review rounds on StemLab PR #410, 22 commits, 19 of them fixes; the last blocker was fabricated |
| **65** | merge-gate invocations in one session, against a target of 2 per pull request |
| **12** | commits to live, globally shared rules and scripts in six days |
| **3** | round cap now enforced by the merge gate; a fourth round needs the owner's words in the acknowledgement |
| **3 of 3** | pull requests under the new rule reached the cap and stopped; every round past it has the owner's words attached |

Two things collided. We moved implementation and review work onto OpenAI Codex behind a Claude
orchestrator, and we let adversarial code review run "until GO". The Codex plugin's job model was
misread several times: status is not liveness, the sandbox cannot build Swift, the review commands
are user-typed only. The review rule had no round budget, used a fresh reviewer every round, and
turned every finding into a fix commit. Together they produced PR #410's twelve rounds, a
2,360-message session, and a week in which three sessions worked on the pipeline instead of the
product.

The response landed in three parts: an instrument that counts rounds, gate runs and messages per
pull request; a rule that caps review at three rounds with same-reviewer resume and
fix/bead/unverified triage; and mechanical enforcement in StemLab's merge gate plus shared scripts
in cc-harness. Results are early and mixed. All three pull requests run under the cap reached it.
One merged after the owner authorised a fourth round, one was split so the contested component
could be rebuilt separately, one merged after a root-cause fix elsewhere. The enforcement scripts
shipped with two real defects of their own. The fourteen-day rule freeze was breached by a
documentation PR within eighty minutes.

## The setup

The parts that make this week hard to read from outside are the parts that are unusual. Each is a
deliberate choice, and each widened the blast radius of a mistake.

| Moving part | What it is | Why it matters here |
|---|---|---|
| **cc-harness** | One repository holding the global Claude Code instructions and rules. `~/.claude/CLAUDE.md`, `~/.claude/rules` and `~/.claude/scripts` are symlinks into it. | A rule commit changes every project's behaviour at once, live. There is no staging. Incident rationale lives in `docs/reference/rule-histories.md`, which is never loaded into context. |
| **Codex-first routing** | Claude is the orchestrator: decide, delegate, verify, gate, commit. Implementation, debugging and review go to OpenAI models through the `openai-codex` plugin (1.0.6, codex-cli 0.147.0). The budget rule: spend the OpenAI allowance first, Claude tokens are the reserve. | Every review round, fix and negative control is a Codex job with its own status model, sandbox and thread. Misreading any of those is a workflow incident, not a tooling nit. |
| **Adversarial branch review** | A read-only reviewer is dispatched when a diff hits one of five risk classes: lifetime/cancellation, persistence, integrity of a check or the policy behind it, trusted external surface, real-time audio. It returns GO or NO-GO with BLOCKER/MAJOR/MINOR findings. | Until 4 September the rule's step 5 read "Repeat until GO". |
| **StemLab merge gate** | No server-side CI. `scripts/merge-gate.sh` runs build, tests, a signed bundle plus launch smoke, path-triggered scanners, and checks a ledger of manual-step acknowledgements keyed by commit sha. Only `MERGE GATE RESULT: PASS` authorises a merge. | The acknowledgement ledger is the only durable record of review rounds, which is how we can count them at all. It is also where the cap is enforced. |
| **Worktrees and peer sessions** | Several Claude sessions run against the same repository at once, each in its own git worktree, and can message each other. | Peer messaging turned into engineering debate and delegation. Worktrees isolate git state but not machine state, window-server locks or caches. |
| **beads (`bd`)** | A local issue tracker. Every task is an issue with acceptance criteria; the issue is meant to be the stop condition for work. | The loops happened when review findings replaced the issue's acceptance criteria as the definition of done. |
| **Verification-integrity rules** | Exit codes never read through a pipe; every new guard proven by mutating the source and watching the test go red; instruments must distinguish healthy from not looking. | This discipline caught most of the week's defects, including defects in the fix itself. |

## Timeline

- **29–30 Aug** — Normal week. StemLab ships #389–#392. The ledger already shows a four-round
  review that found two real defects, and feature pull requests taking 49–74 hours open to merge.
- **31 Aug – 1 Sep** — Codex job-status integrity rule lands, then a second commit for the missing
  `queued` state. The dispatch, wait and broker protocol follows after a foreground timeout killed
  a worker while its app-server turn kept editing files. A session in another repository reads
  `running` as live for 25 minutes before learning no job existed.
- **2 Sep** — PR #404 merges after six review rounds with a fresh, no-context Codex reviewer each
  round. A note claims the Codex stop-time review gate is on in every main checkout.
- **3 Sep** — The review route changes three times in one day: the rule points at a user-typed-only
  slash command, a peer refuses a Bash workaround, a Claude reviewer stands in and returns three
  MAJOR NO-GOs, and the route settles on read-only `/codex:rescue`. The stop-gate claim is measured
  and found false. A selftest fix lands because bash 3.2 resets `$?` before the EXIT trap, so an
  aborting selftest could look green. #406 merges after five rounds and six defects.
- **4 Sep** — PR #410 opens at 06:44 and merges at 17:05 after twelve rounds and 22 commits. The
  same session records 65 merge-gate invocations. PR #415 reaches four rounds with blockers going
  4 → 9 → 6; its round-3 headline blocker is fabricated and costs about an hour to disprove. At
  20:43 a Codex task is cancelled by hand. At 22:37 the bounded-review plan is approved and #418
  opens.
- **5 Sep** — #418 merges at 05:13 after four rounds. cc-harness #40 lands the bounded rules and the
  freeze; #41 edits a frozen rule 79 minutes later. The merge-gate evaluation, the gate-slimming PR
  #419 and the shared-scripts PR #42 run under the new rule; both reach round three and stop.

## What went wrong

### The unbounded review loop

PR #410 (paging and search in the SetDigger Crate Dig tab) went through twelve adversarial rounds.
Three of the branch's seven defects came from its own fixes. The session behind it produced 2,360
assistant messages, 963 Bash calls, 60 subagent calls, 65 merge-gate runs, 156 test-suite runs and
90 builds for roughly six pull requests. PR #415's rounds diverged (4, then 9, then 6 blockers) and
its session wrote: *"the hook has been working since round 2 — what consumed the last several hours
is proving it works."*

The rule said "Repeat until GO" and nothing else. Sessions used a fresh reviewer every round, so
each round re-derived the diff and found new things instead of converging. Every finding, including
MINOR and forward-looking ones, became a fix commit that reopened a round. The orchestrator wrote
negative controls and reproduced findings by hand, on the most expensive model, instead of one
triage line per finding.

### Review found real defects too

#396 had two rounds and four MAJORs, one found only on the recheck. #406 had five rounds, six
defects in a one-audio-owner race, and ten deliberate negative controls. #404's six rounds found six
real reporting defects, including a stage that conflated an unavailable temp directory with zero.

The loop is not worthless. Independent review adds signal on cancellation, ownership and
observability semantics that deterministic gates do not cover. The fix had to bound the loop, not
remove it. Nothing here justifies twelve rounds.

### Codex job status was not job liveness

A foreground `codex-companion.mjs task` killed by the 120-second Bash timeout left the record at
`running` with a dead PID while the app-server turn kept editing files with nobody tracking it. The
plugin's status command filters by session id, so a job dispatched from another session or into a
worktree showed an empty table while alive. A `queued` job whose worker died stayed `queued`
forever. During this retrospective's own evidence collection `setup --json` reported `ready:false`
with "Shared Codex broker is busy"; it was `ready:true` again an hour later.

The wrapper was mistaken for the job, and session-scoped listing for global truth. Guidance was
written before reading the plugin's runtime code: a proposed `setsid` wrapper was unnecessary
because background workers are already detached, and would have made things worse by creating
workers nobody records.

Six commits over three days followed: an integrity rule for `unknown`/`orphaned`, a PID-bridge wait
script that wakes once instead of polling, a cross-session jobs lister, a broker lister, a dispatch
wrapper that verifies placement, and written cancellation criteria. Three job records still read
`running` on disk at collection time; the protocol correctly requires PID and log inspection rather
than trusting them.

### The sandbox cannot build the product

Codex tasks in StemLab cannot run `swift build` or the test runner even with the sandbox disabled
and the SwiftPM cache made writable. Swift's macro plugin host runs under `sandbox-exec`, and nested
Seatbelt inside Codex's sandbox fails with "Operation not permitted". Every `@State` and
`@Observable` site errors out.

Code Codex hands back is therefore unverified and in practice does not compile first time. Every fix
round becomes at least two round trips: Codex writes, the orchestrator builds outside the sandbox,
the error list goes back on the same thread. This amplified the review loops. It is a structural
limitation, not a rule problem, and it is unchanged.

### The review route contradicted its own control boundary

The rule instructed agents to run `/codex:adversarial-review`, but the plugin marks that command
`disable-model-invocation: true`. A peer session correctly refused a Bash workaround. The stand-in
Claude reviewer returned three MAJOR NO-GOs on a branch. Separately, a note asserted that the Codex
stop-time review gate was enabled in every main checkout; measuring it the next day showed
`reviewGateEnabled:false`.

Routing prose and plugin behaviour were never reconciled, and per-workspace state was generalised as
global. Stacked passes — two Codex reviews for the `code-review-high` acknowledgement, plus branch
review, plus code-quality, plus the assumed stop gate — each produced deltas that reopened the
others. The settlement is one review pass per branch, Stage 2 wins, "check, never assume". The route
now rests on an inference about the plugin's task contract rather than a first-class review
subcommand, and is documented as such.

### Verification that could not fail

Bash 3.2 resets `$?` before the EXIT trap fires, so an aborting selftest could report green; fixed on
3 September in the hook, Codex and merge selftests. A #412 session noted *"the gates were all green
through every one of these; only the real bundle showed it."* Open StemLab bead `sl-en6e` records a
large-diff merge gate under-firing path stages through SIGPIPE under `pipefail`. A watcher in the
#410 session gave a false green because zsh does not word-split unquoted variables.

Status was read through pipes and traps rather than captured at the source, and instruments
themselves were under-tested. This class has not disappeared. It is why every new guard this week
was proven red by a source mutation before being reported green.

### Two attribution policies, both in force

The owner's global instructions forbid any agent, vendor or model identity in commits, including
`Co-authored-by` trailers. The Claude Code harness injects its own instruction to end every commit
with such a trailer. Three commits on cc-harness #42 carried it; the round-3 reviewer flagged them
as a BLOCKER.

The root cause was in the harness, not in one prompt. The commit agent's template emitted
`Co-Authored-By: <co_author>` unconditionally, and four projects had `co_author` set to Claude in
their Agent Config. Several commits already on cc-harness `main` carry the trailer. The owner chose
to fix the root rather than rewrite history: `co_author` is now `(none)` in all four projects, the
trailer and the "Generated with" pull-request footer are gone from the commit agent, and the agent
greps the unpushed commits for agent trailers before pushing (cc-harness #43, SetDigger #779,
setdigger-mixid #60, setdigger-newsletter #32). #42 squash-merged with a clean body, so its trailers
never reached `main`.

### Collateral

| Area | Evidence |
|---|---|
| Rules | Twelve commits between 31 Aug and 5 Sep changed live global rules or scripts: 692 lines for the dispatch protocol alone, 494 for the bounded-loop instrumentation. Three of the week's sessions were about the pipeline rather than the product. |
| Peers | Top sessions sent 29, 20, 17, 15 and 14 peer messages; 109 of 134 in one day. Content was delegation and debate, not resource notices. |
| Gates | 65 merge-gate runs, 258 test-runner runs and 182 builds in the baseline window, against a documented target of one qualifying run plus one dev run per pull request. Six parallel UI-gate agents once opened real windows on the desktop simultaneously. |
| Local state | A #392 verification step that reset UserDefaults deleted real local app state. Five computer-use attempts on #382 were interrupted over ten minutes. Each worktree gate re-downloads 640 MB of model weights (`sl-cepx`, open). A worktree produced a false red when a machine-local symlink was missing. |

## Why it happened

- **The loop had no floor.** `rules/branch-completion-review.md` step 5: "Repeat until GO." No cap,
  no escalation path, no convergence test. A rule that cannot be violated cannot stop anything.
- **Fresh reviewer per round ratchets.** The memory governing *plan* reviews said "fresh reviewer
  each round, repeat until convergence". It leaked into code review. A reviewer without the prior
  rounds' findings re-derives them and finds adjacent ones; blocker counts go up, not down.
- **Every finding became a commit.** MINOR, NIT, forward-looking and test-hardening findings were
  fixed on the branch under review. Each fix reopened a round, and fixes introduced three of #410's
  seven defects.
- **The orchestrator did implementation-grade work.** Negative controls, mutation harnesses and hand
  reproductions ran inline on the most expensive model — exactly the work the budget rule says is a
  Codex task, with the orchestrator emitting one triage line per finding.
- **Stacked passes.** Two Codex reviews, an adversarial review, code-quality and an assumed
  stop-time gate each generated deltas for the others to review.
- **Targets without an instrument.** The gate rule had targets for runs per pull request since
  24 August. Nothing counted them, so nothing could fail.

Underneath all six is one habit: rules were edited in response to live incidents, globally, in the
middle of the incident. Some of those edits were themselves wrong — the `setsid` guidance, the
stop-gate claim, the user-typed review route — and had to be corrected the next day.

## What we changed

| Phase | Change | Where | Status |
|---|---|---|---|
| 0 · instrument | `loop-report.sh` counts review rounds, gate runs, merge-gate invocations, peer messages, assistant messages and subagent calls per transcript, with a selftest whose counters are proven able to read non-zero. Baseline recorded in `docs/reference/loop-baseline-2026-09.md`. | cc-harness #40 | merged |
| 1 · bound | Round budget 3. Rounds 2 and 3 resume the same reviewer thread. After round 3 with open blockers the orchestrator stops and escalates: merge with disclosure, grant more budget, or shelve. A fourth round exists only after the owner's words in chat, quoted in the acknowledgement. Triage per finding: FIX (blocker or major, inside acceptance, reproduced), BEAD (everything else), UNVERIFIED (one Codex attempt, then dropped or beaded). Fixes are one Codex task per round. Status line every round. | cc-harness #40 | merged |
| 2 · enforce | The `branch-review` acknowledgement must carry `rounds= verdict= open_blockers= classes=`; the gate FAILs on rounds above three or NO-GO without `user_decision=`. `review-round.sh` is the only sanctioned way to dispatch a round: it owns the counter, refuses a fourth round without `--user-approved`, and resumes the recorded reviewer thread. `runs.log` records every gate run so re-runs on an already-passed tree are visible. | StemLab #418 | merged |
| 3 · collapse | One review pass per branch; `code-review-high` satisfied by a branch-review acknowledgement. Peer messages bounded at three per peer per session beyond resource notices; a peer is never a reviewer or a worker. Model-routing gains the row: finding triage stays in Claude, the fix, reproduction and negative control go to Codex. | cc-harness #40 | merged |
| 4 · freeze | No rule edits for 14 days unless a loop-report metric shows the edit is needed. Scripts may change. A scheduled read-only review fires 19 Sep. | `rule-histories.md` | **breached same day** |
| gate eval | The merge gate evaluated against its own ledger: keep it, slim it, do not port it whole. Acknowledgements are checked first so a missing one costs a second instead of a full build; the last-summary is sha/tree stamped; every run appends to `runs.log`. Six gate bugs triaged. | StemLab #419 | merged |
| generalise | Only the bounded-review check is lifted into cc-harness as project-agnostic scripts: `review-round.sh` with state under the git common dir, `--collect`/`--adopt`, and `review-ack-check.sh` any project's gate can call. Selftests wired into `verify.sh`. | cc-harness #42 | merged |
| attribution | `co_author` is `(none)` in every project; the commit agent no longer emits an agent trailer or the generated-with footer, and checks unpushed commits before pushing. | cc-harness #43 + 3 project PRs | merged |

The status line is the cheapest part and the one that anchors everything else. Every round prints
the issue's acceptance criteria as the goal, so the definition of done cannot drift into the
reviewer's last finding:

```
GOAL: <bead acceptance> | ROUND 3/3 | OPEN BLOCKERS k | NEXT: <one action>
```

And the acknowledgement the gate parses:

```
branch-review  rounds=4 verdict=NO-GO open_blockers=1 classes=3 user_decision="Split it, merge the rest, bead the lock"
```

## Results so far

| PR | Rounds | Outcome | What the sample shows |
|---|---:|---|---|
| StemLab #418 | 4 | merged, 6.6 h open | The bounded-review change itself exhausted its own budget at NO-GO. The orchestrator escalated as designed; the owner authorised a fourth round, which returned GO. The cap worked as a stop. It did not make the review converge faster. |
| StemLab #419 | 4 | split; slimming merged, lock beaded | The UI-lock design ratcheted: four findings, then a reclaim race, then an unrecoverable guard, then a simplification to an atomic-rename election, each proven by source mutation. The owner-authorised fourth round found the simplification had reintroduced round 1's race: `mkdir` publishes the lock before its owner pid, so a contender paused in that window can be reclaimed as stale. A real finding, and a fix that undid an earlier fix. The branch was split: the slimming merged on a gate PASS, the lock returns under `sl-uqn9` with the selftest written first. |
| cc-harness #42 | 3 | merged after a root-cause fix | Rounds 1 and 2 found real defects in the new scripts: the first version required a thread id at dispatch time, so a background job launched and ran *uncounted*, the exact failure the script exists to prevent. The `--collect` parser expected `Final output:` while real logs write `[ts] Final output`, so it never matched a real log until a captured sample replaced the hand-written fixture. Round 3 blocked on commit attribution, which was fixed at its root rather than by rewriting history. |

Session counters over the two-day window, against the plan's targets:

| Metric | Baseline | This session | Target | Read |
|---|---:|---:|---:|---|
| Review rounds per branch | up to 12 | 4 / 4 / 3 | ≤ 3 | Two over, both by the owner's decision, recorded in the acknowledgement and the bead. |
| Merge-gate invocations | 65 / session | 45 | ≤ 2 / PR | Most are `--selftest` runs from mutation proofs while editing the gate itself, which the counter does not separate. Qualifying runs: 16 across three pull requests. Still above target. |
| Peer messages | 29 / session | 1 | ≤ 6 | Peer messaging was disabled for this session, so this is a floor, not evidence the bound holds under load. |
| Assistant messages per PR | ~400 | 430 / 3 PRs | ≤ 150 | Roughly 143 each if split evenly, but the gate evaluation and this retrospective are in the count. Not a clean measurement. |
| Feature PR open→merge | 49–74 h | 6.6 h (#418) | ≤ 12 h | One sample. |
| Rule edits during freeze | 12 in 6 days | 1 | 0 | cc-harness #41, 24 lines in a frozen rule, merged 79 minutes after the freeze without citing a metric. |

**What did not work.** The cap has not made a review converge in fewer rounds; it has made the loop
stop and hand the decision to a person. All three sample pull requests hit the cap, and two needed
the owner. The enforcement scripts shipped with defects that the rule's own reviewer found only
partially — source mutation and a real captured log found the rest. The freeze did not hold on its
first day. The commit agent had been attributing every commit to Claude for weeks, against the
owner's own policy, and nobody noticed until a reviewer blocked on it. Gate A (five merged pull
requests within targets) has one clean sample and it missed on rounds.

**What did work.** Nothing ran to round twelve. Every escalation went to the owner with options
instead of another round, and the last one ended in a split rather than a fifth round. Every guard
added this week has a negative control that was actually watched going red. The instrument exists
and its numbers are the ones in this document. The merge gate was evaluated from its ledger rather
than from opinion, and the verdict was to keep it — a judgement the gate then earned on its way out,
failing a merge run in one second on a missing acknowledgement before any build ran.

## Still open

| Item | Bead |
|---|---|
| Machine-global UI-gate lock with atomic owner publication, selftest first | `sl-uqn9` |
| StemLab's gate still carries its own copy of the acknowledgement predicate; the `classes=` field format differs between it and the shared script | `sl-65pe` |
| Large-diff merge gate under-fires path stages through SIGPIPE under `pipefail` | `sl-en6e` |
| `review-round.sh`'s delayed-thread path has no negative control | `cch-g81` |
| `--collect` does not extract bold-bullet findings | `cch-aif` |
| Worktree prune can remove an unmerged branch | `sl-m3eb` |
| 640 MB of model weights re-downloaded per worktree gate | `sl-cepx` |
| Codex cannot build Swift in its sandbox | structural, no bead |
| Gates A, B and C unmeasured: five merged pull requests, five sessions, and ten pull requests' worth of post-merge escapes before anyone widens the round budget | — |

The 19 September read-only review is scheduled and closes the deferred freeze bead. Until then, a
rule edit must cite the metric it moves.

## Learnings

- **A loop needs a counter, not a sentence.** "Repeat until GO" cannot fail. "Round 4 refused
  without the owner's quoted words" can, and did, three times this week.
- **The tracker issue is the stop condition.** The moment a reviewer's last finding replaces the
  acceptance criteria as the definition of done, the branch belongs to the reviewer. Print the goal
  every round.
- **Resume the reviewer.** A fresh reviewer per round is a ratchet. Same thread, prior findings
  attached, and a calibration block that says to call GO plainly and not manufacture severity.
- **Triage is one line; fixing is a task.** The orchestrator's output per finding is FIX, BEAD or
  UNVERIFIED. The reproduction, the fix and the negative control are Codex work, once per round,
  with the whole list.
- **Read the runtime before writing the rule.** Three of the week's rule edits were wrong because
  they described plugin behaviour from assumption. The wrapper is not the job; the sandbox is not
  the machine; the slash command is not callable.
- **Prove the instrument against a real sample.** The collect parser passed its hand-written fixture
  and never matched a real log. A guard that has not been watched going red is decoration.
- **Do not edit global rules during the incident.** Twelve live commits in six days, several
  correcting each other. The freeze is the response, and its first-day breach measures how strong
  the habit is.
- **Keep the gate; make it fail fast.** The ledger shows the gate and the reviews found real
  defects. What was wasteful was paying the full gate on every fix and checking acknowledgements
  last.
- **A cap stops a loop; it does not fix convergence.** Three pull requests stopped at the cap and
  each still needed a person. The next lever is the reviewer's calibration and the triage
  discipline, not a bigger budget.
- **When two instruction sources disagree, fix the source, not the instance.** The attribution
  blocker was three commits; the cause was one template and four config values.

## What this entry cannot establish

No token or dollar totals: the counts here are transcript occurrence counts and ledger rows, not
billing data. No causal claim that the delegation rate produced useful work. No complete mapping of
every pull request to its review rounds — the acknowledgement ledger is sha-keyed and several rows
cannot be joined to a PR number. Ledger claims that a reviewer was "fresh" or that a negative
control ran are assertions cited here, not replayed. One fabricated blocker is documented on #410;
whether others were fabricated is unknown.
