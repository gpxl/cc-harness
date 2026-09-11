# Codex integration and unbounded review loops

**Period:** 29 August – 5 September 2026 · **Repos:** AudioApp (a native macOS/Swift audio app), cc-harness · **Published:** 2026-09-05

This is the first entry in the series, so there is no previous follow-through section. Evidence
comes from 30 AudioApp pull requests, 277 rows in the merge-gate acknowledgement ledger,
`docs/reference/rule-histories.md`, the appendix, targeted transcript searches, and
`loop-report.sh` / `routing-report.sh` runs on 5 September.

## Summary

| | |
|---:|---|
| **12** | review rounds on AudioApp PR #8, 22 commits, 19 of them fixes |
| **65** | merge-gate invocations in one session, against a target of 2 per pull request |
| **12** | commits to live, globally shared rules and scripts in six days |
| **3** | round cap now enforced by the merge gate; a fourth round needs the owner's words in the acknowledgement |
| **3 of 3** | pull requests under the new rule reached the cap and stopped; every round past it has the owner's words attached |

Two changes collided: implementation and review moved to OpenAI Codex behind a Claude
orchestrator, while adversarial review was allowed to run "until GO". We repeatedly misread the
plugin's job model: status is not liveness, the sandbox cannot build Swift, and review commands are
user-typed only. Meanwhile, the review rule had no round budget, started with a fresh reviewer each
time, and turned every finding into a fix commit. The result was AudioApp PR #8's twelve rounds, one
2,360-message session, and three sessions spent on the pipeline instead of the product.

We responded with an instrument that counts rounds, gate runs, and messages per pull request; a
three-round review cap with same-reviewer resume and fix/bead/unverified triage; and enforcement in
AudioApp's merge gate and shared cc-harness scripts. Early results are mixed. All three pull
requests reached the cap. One merged after the owner authorized a fourth round, one was split so a
contested component could be rebuilt separately, and one merged after a root-cause fix elsewhere.
The enforcement scripts introduced two defects, and a documentation PR breached the fourteen-day
rule freeze within eighty minutes.

## The setup

Several deliberate choices made this week unusual and widened the blast radius of mistakes.

| Moving part | What it is | Why it matters here |
|---|---|---|
| **cc-harness** | One repository holding the global Claude Code instructions and rules. `~/.claude/CLAUDE.md`, `~/.claude/rules` and `~/.claude/scripts` are symlinks into it. | A rule commit changes every project's behaviour at once, live. There is no staging. Incident rationale lives in `docs/reference/rule-histories.md`, which is never loaded into context. |
| **Codex-first routing** | Claude is the orchestrator: decide, delegate, verify, gate, commit. Implementation, debugging and review go to OpenAI models through the `openai-codex` plugin (1.0.6, codex-cli 0.147.0). The budget rule: spend the OpenAI allowance first, Claude tokens are the reserve. | Every review round, fix and negative control is a Codex job with its own status model, sandbox and thread. Misreading any of those is a workflow incident, not a tooling nit. |
| **Adversarial branch review** | A read-only reviewer is dispatched when a diff hits one of five risk classes: lifetime/cancellation, persistence, integrity of a check or the policy behind it, trusted external surface, real-time audio. It returns GO or NO-GO with BLOCKER/MAJOR/MINOR findings. | Until 4 September the rule's step 5 read "Repeat until GO". |
| **AudioApp merge gate** | No server-side CI. `scripts/merge-gate.sh` runs build, tests, a signed bundle plus launch smoke, path-triggered scanners, and checks a ledger of manual-step acknowledgements keyed by commit sha. Only `MERGE GATE RESULT: PASS` authorises a merge. | The acknowledgement ledger is the only durable record of review rounds, which is how we can count them at all. It is also where the cap is enforced. |
| **Worktrees and peer sessions** | Several Claude sessions run against the same repository at once, each in its own git worktree, and can message each other. | Peer messaging turned into engineering debate and delegation. Worktrees isolate git state but not machine state, window-server locks or caches. |
| **beads (`bd`)** | A local issue tracker. Every task has acceptance criteria meant to define when work stops. | The loops began when review findings replaced those criteria as the definition of done. |
| **Verification-integrity rules** | Exit codes never read through a pipe; every new guard proven by mutating the source and watching the test go red; instruments must distinguish healthy from not looking. | This discipline caught most of the week's defects, including defects in the fix itself. |

## Timeline

- **29–30 Aug** — AudioApp ships PR #1–#4. The ledger already shows one four-round review that
  found two real defects, while feature pull requests take 49–74 hours from open to merge.
- **31 Aug – 1 Sep** — The Codex job-status integrity rule lands, followed by a commit for the
  missing `queued` state. The dispatch, wait, and broker protocol follows after a foreground
  timeout kills a worker while its app-server turn keeps editing files. Another repository's
  session reads `running` as live for 25 minutes before learning that no job exists.
- **2 Sep** — AudioApp PR #6 merges after six review rounds with a fresh, no-context Codex reviewer each
  round. A note claims the Codex stop-time review gate is on in every main checkout.
- **3 Sep** — The review route changes three times: the rule points at a user-typed-only
  slash command, a peer refuses a Bash workaround, a Claude reviewer stands in and returns three
  MAJOR NO-GOs, and the route settles on read-only `/codex:rescue`. The stop-gate claim is measured
  and found false. A selftest fix lands because bash 3.2 resets `$?` before the EXIT trap, so an
  aborting selftest could look green. AudioApp PR #7 merges after five rounds and six defects.
- **4 Sep** — AudioApp PR #8 opens at 06:44 and merges at 17:05 after twelve rounds and 22
  commits. Its session records 65 merge-gate invocations. AudioApp PR #10 reaches four rounds with
  blocker counts of 4 → 9 → 6; its headline round-3 blocker is fabricated and takes about an hour
  to disprove. A Codex task is cancelled by hand at 20:43. The bounded-review plan is approved at
  22:37, and AudioApp PR #11 opens.
- **5 Sep** — AudioApp PR #11 merges at 05:13 after four rounds. cc-harness #40 lands the bounded
  rules and freeze; #41 edits a frozen rule 79 minutes later. The merge-gate evaluation,
  gate-slimming AudioApp PR #12, and shared-scripts PR #42 run under the new rule. Both PRs reach
  round three and stop.

## What went wrong

### The unbounded review loop

AudioApp PR #8, which added paging and search to a paginated browse tab, went through twelve
adversarial rounds. Its fixes introduced three of the branch's seven defects. Across roughly six
pull requests, the session produced 2,360 assistant messages, 963 Bash calls, 60 subagent calls, 65
merge-gate runs, 156 test-suite runs, and 90 builds. AudioApp PR #10's rounds diverged—4, then 9,
then 6 blockers—and its session wrote: *"the hook has been working since round 2 — what consumed
the last several hours is proving it works."*

The rule said only "Repeat until GO." Each fresh reviewer re-derived the diff and found new issues
instead of converging. Every finding, including MINOR and forward-looking ones, became a fix commit
and opened another round. On the most expensive model, the orchestrator wrote negative controls and
reproduced findings by hand instead of giving one triage line per finding.

### Review found real defects too

AudioApp PR #5 had two rounds and four MAJORs, one found only on recheck. AudioApp PR #7 had five
rounds, six defects in a one-audio-owner race, and ten deliberate negative controls. AudioApp PR
#6's six rounds found six real reporting defects, including a stage that treated an unavailable
temp directory as zero.

Independent review still adds signal on cancellation, ownership, and observability semantics that
deterministic gates miss. The right response was to bound it, not remove it. Nothing here supports
twelve rounds.

### Codex job status was not job liveness

A 120-second Bash timeout killed a foreground `codex-companion.mjs task`, leaving its record at
`running` with a dead PID while the app-server turn continued editing untracked. The plugin's
status command filters by session id, so a live job dispatched from another session or worktree
appeared as an empty table. A `queued` job whose worker died stayed `queued` forever. During this
retrospective's evidence collection, `setup --json` reported `ready:false` with "Shared Codex
broker is busy"; an hour later it returned `ready:true`.

We mistook the wrapper for the job and a session-scoped listing for global truth. Guidance preceded
inspection of the plugin's runtime code. A proposed `setsid` wrapper was unnecessary because
background workers were already detached; it would have created unrecorded workers.

Six commits followed in three days: an integrity rule for `unknown`/`orphaned`; a PID-bridge wait
script that wakes once instead of polling; cross-session job and broker listers; a dispatch wrapper
that verifies placement; and written cancellation criteria. Three on-disk records still read
`running` at collection time, so the protocol requires PID and log inspection rather than trust in
the record.

### The sandbox cannot build the product

AudioApp Codex tasks cannot run `swift build` or the test runner, even with the sandbox disabled and
the SwiftPM cache writable. Swift's macro plugin host runs under `sandbox-exec`; nested Seatbelt
inside Codex's sandbox fails with "Operation not permitted." Every `@State` and `@Observable` site
then errors.

Codex therefore hands back unverified code that, in practice, does not compile on the first try.
Each fix round takes at least two trips: Codex writes, the orchestrator builds outside the sandbox,
and the errors return to the same thread. This structural limitation amplified the loops and
remains unchanged.

### The review route contradicted its own control boundary

The rule told agents to run `/codex:adversarial-review`, but the plugin marks that command
`disable-model-invocation: true`. A peer correctly refused a Bash workaround, and the stand-in
Claude reviewer returned three MAJOR NO-GOs. Separately, a note claimed the Codex stop-time review
gate was enabled in every main checkout. Measurement the next day showed
`reviewGateEnabled:false`.

Routing prose and plugin behavior had drifted apart, while per-workspace state was generalized as
global. Two Codex reviews for `code-review-high`, branch review, code-quality, and the assumed stop
gate each produced deltas that reopened the others. The settlement is one review pass per branch:
Stage 2 wins, and state is checked rather than assumed. The route rests on an inference about the
plugin's task contract, not a first-class review subcommand, and is documented that way.

### Verification that could not fail

Bash 3.2 resets `$?` before the EXIT trap fires, so an aborting selftest could report green. The
hook, Codex, and merge selftests were fixed on 3 September. An AudioApp PR #9 session noted: *"the
gates were all green through every one of these; only the real bundle showed it."* Open AudioApp
bead `aa-en6e` records a large-diff merge gate under-firing path stages through SIGPIPE under
`pipefail`. A watcher in the AudioApp PR #8 session returned a false green because zsh does not
word-split unquoted variables.

Status was read through pipes and traps instead of captured at the source, and the instruments were
under-tested. This class of failure remains. Every new guard that week was therefore proven red by
a source mutation before it was reported green.

### Two attribution policies, both in force

The owner's global instructions forbid agent, vendor, or model identities in commits, including
`Co-authored-by` trailers. The Claude Code harness also injected an instruction requiring that
trailer. Three cc-harness #42 commits carried it, and the round-3 reviewer marked them BLOCKER.

The conflict lived in the harness, not one prompt. The commit-agent template always emitted
`Co-Authored-By: <co_author>`, and four projects set `co_author` to Claude in Agent Config. Several
commits already on cc-harness `main` carry the trailer. The owner fixed the source instead of
rewriting history: all four projects now set `co_author` to `(none)`; the commit agent no longer
adds the trailer or "Generated with" PR footer; and it greps unpushed commits for agent trailers
before pushing (cc-harness #43, AudioWebsite PR #1, and three sibling projects). #42 squash-merged
with a clean body, so its trailers never reached `main`.

### Collateral

| Area | Evidence |
|---|---|
| Rules | Twelve commits between 31 Aug and 5 Sep changed live global rules or scripts: 692 lines for the dispatch protocol alone, 494 for the bounded-loop instrumentation. Three of the week's sessions were about the pipeline rather than the product. |
| Peers | Top sessions sent 29, 20, 17, 15 and 14 peer messages; 109 of 134 in one day. Content was delegation and debate, not resource notices. |
| Gates | 65 merge-gate runs, 258 test-runner runs and 182 builds in the baseline window, against a documented target of one qualifying run plus one dev run per pull request. Six parallel UI-gate agents once opened real windows on the desktop simultaneously. |
| Local state | An AudioApp PR #4 verification step that reset UserDefaults deleted real local app state. Five computer-use attempts on AudioApp PR #C were interrupted over ten minutes. Each worktree gate re-downloads 640 MB of model weights (`aa-cepx`, open). A worktree produced a false red when a machine-local symlink was missing. |

## Why it happened

- **No stopping rule.** Step 5 of `rules/branch-completion-review.md` said "Repeat until GO," with
  no cap, escalation path, or convergence test. A rule with no failure condition cannot stop a loop.
- **A fresh reviewer each round.** Guidance for *plan* reviews—"fresh reviewer each round, repeat
  until convergence"—leaked into code review. Without prior findings, each reviewer re-derived the
  diff and found adjacent issues, so blocker counts rose instead of converging.
- **A commit for every finding.** MINOR, NIT, forward-looking, and test-hardening findings were
  fixed on the reviewed branch. Each fix reopened review, and fixes introduced three of AudioApp
  PR #8's seven defects.
- **Implementation work in the orchestrator.** The most expensive model ran negative controls,
  mutation harnesses, and manual reproductions. The budget rule assigns that work to Codex and asks
  the orchestrator for one triage line per finding.
- **Stacked review passes.** Two Codex reviews, adversarial review, code-quality, and an assumed
  stop-time gate each created deltas for the others to review.
- **Targets without measurement.** The gate rule had set run targets per pull request on 24
  August, but nothing counted them, so nothing could fail.

All six share one habit: editing global rules in the middle of a live incident. Some edits—the
`setsid` guidance, stop-gate claim, and user-typed review route—were wrong and needed correction the
next day.

## What we changed

| Phase | Change | Where | Status |
|---|---|---|---|
| 0 · instrument | `loop-report.sh` counts review rounds, gate runs, merge-gate invocations, peer messages, assistant messages and subagent calls per transcript, with a selftest whose counters are proven able to read non-zero. Baseline recorded in the appendix below. | cc-harness #40 | merged |
| 1 · bound | Round budget 3. Rounds 2 and 3 resume the same reviewer thread. After round 3 with open blockers the orchestrator stops and escalates: merge with disclosure, grant more budget, or shelve. A fourth round exists only after the owner's words in chat, quoted in the acknowledgement. Triage per finding: FIX (blocker or major, inside acceptance, reproduced), BEAD (everything else), UNVERIFIED (one Codex attempt, then dropped or beaded). Fixes are one Codex task per round. Status line every round. | cc-harness #40 | merged |
| 2 · enforce | The `branch-review` acknowledgement must carry `rounds= verdict= open_blockers= classes=`; the gate FAILs on rounds above three or NO-GO without `user_decision=`. `review-round.sh` is the only sanctioned way to dispatch a round: it owns the counter, refuses a fourth round without `--user-approved`, and resumes the recorded reviewer thread. `runs.log` records every gate run so re-runs on an already-passed tree are visible. | AudioApp PR #11 | merged |
| 3 · collapse | One review pass per branch; `code-review-high` satisfied by a branch-review acknowledgement. Peer messages bounded at three per peer per session beyond resource notices; a peer is never a reviewer or a worker. Model-routing gains the row: finding triage stays in Claude, the fix, reproduction and negative control go to Codex. | cc-harness #40 | merged |
| 4 · freeze | No rule edits for 14 days unless a loop-report metric shows the edit is needed. Scripts may change. A scheduled read-only review fires 19 Sep. | `rule-histories.md` | **breached same day** |
| gate eval | The merge gate evaluated against its own ledger: keep it, slim it, do not port it whole. Acknowledgements are checked first so a missing one costs a second instead of a full build; the last-summary is sha/tree stamped; every run appends to `runs.log`. Six gate bugs triaged. | AudioApp PR #12 | merged |
| generalise | Only the bounded-review check is lifted into cc-harness as project-agnostic scripts: `review-round.sh` with state under the git common dir, `--collect`/`--adopt`, and `review-ack-check.sh` any project's gate can call. Selftests wired into `verify.sh`. | cc-harness #42 | merged |
| attribution | `co_author` is `(none)` in every project; the commit agent no longer emits an agent trailer or the generated-with footer, and checks unpushed commits before pushing. | cc-harness #43 + 3 project PRs | merged |

The status line anchors the process at little cost. Every round prints the issue's acceptance
criteria, keeping the definition of done from drifting to the reviewer's latest finding:

```
GOAL: <bead acceptance> | ROUND 3/3 | OPEN BLOCKERS k | NEXT: <one action>
```

The gate parses this acknowledgement:

```
branch-review  rounds=4 verdict=NO-GO open_blockers=1 classes=3 user_decision="Split it, merge the rest, bead the lock"
```

## Results so far

| PR | Rounds | Outcome | What the sample shows |
|---|---:|---|---|
| AudioApp PR #11 | 4 | merged, 6.6 h open | The bounded-review change itself exhausted its own budget at NO-GO. The orchestrator escalated as designed; the owner authorised a fourth round, which returned GO. The cap worked as a stop. It did not make the review converge faster. |
| AudioApp PR #12 | 4 | split; slimming merged, lock beaded | The UI-lock design ratcheted: four findings, then a reclaim race, then an unrecoverable guard, then a simplification to an atomic-rename election, each proven by source mutation. The owner-authorised fourth round found the simplification had reintroduced round 1's race: `mkdir` publishes the lock before its owner pid, so a contender paused in that window can be reclaimed as stale. A real finding, and a fix that undid an earlier fix. The branch was split: the slimming merged on a gate PASS, the lock returns under `aa-uqn9` with the selftest written first. |
| cc-harness #42 | 3 | merged after a root-cause fix | Rounds 1 and 2 found real defects in the new scripts: the first version required a thread id at dispatch time, so a background job launched and ran *uncounted*, the exact failure the script exists to prevent. The `--collect` parser expected `Final output:` while real logs write `[ts] Final output`, so it never matched a real log until a captured sample replaced the hand-written fixture. Round 3 blocked on commit attribution, which was fixed at its root rather than by rewriting history. |

Session counters over the two-day window, against the plan's targets:

| Metric | Baseline | This session | Target | Read |
|---|---:|---:|---:|---|
| Review rounds per branch | up to 12 | 4 / 4 / 3 | ≤ 3 | Two over, both by the owner's decision, recorded in the acknowledgement and the bead. |
| Merge-gate invocations | 65 / session | 45 | ≤ 2 / PR | Most are `--selftest` runs from mutation proofs while editing the gate itself, which the counter does not separate. Qualifying runs: 16 across three pull requests. Still above target. |
| Peer messages | 29 / session | 1 | ≤ 6 | Peer messaging was disabled for this session, so this is a floor, not evidence the bound holds under load. |
| Assistant messages per PR | ~400 | 430 / 3 PRs | ≤ 150 | Roughly 143 each if split evenly, but the gate evaluation and this retrospective are in the count. Not a clean measurement. |
| Feature PR open→merge | 49–74 h | 6.6 h (AudioApp PR #11) | ≤ 12 h | One sample. |
| Rule edits during freeze | 12 in 6 days | 1 | 0 | cc-harness #41, 24 lines in a frozen rule, merged 79 minutes after the freeze without citing a metric. |

**What did not work.** The cap stopped reviews but did not make them converge faster. All three
sample pull requests hit it, and two needed the owner. The rule's reviewer found only some defects
in the enforcement scripts; source mutation and a captured real log found the rest. The freeze
failed on its first day. For weeks, the commit agent attributed every commit to Claude against the
owner's policy, unnoticed until a reviewer blocked it. Gate A—five merged pull requests within
target—has one clean sample, which missed the round target.

**What did work.** Nothing reached round twelve. Each escalation gave the owner options instead of
starting another round; the last ended in a split rather than a fifth round. Every new guard has a
negative control that was observed going red. The instrument now provides the numbers in this
document. Evidence from the ledger supported keeping the merge gate, which then failed a merge run
in one second on a missing acknowledgement before any build began.

## Still open

| Item | Bead |
|---|---|
| Machine-global UI-gate lock with atomic owner publication, selftest first | `aa-uqn9` |
| AudioApp's gate still carries its own copy of the acknowledgement predicate; the `classes=` field format differs between it and the shared script | `aa-65pe` |
| Large-diff merge gate under-fires path stages through SIGPIPE under `pipefail` | `aa-en6e` |
| `review-round.sh`'s delayed-thread path has no negative control | `cch-g81` |
| `--collect` does not extract bold-bullet findings | `cch-aif` |
| Worktree prune can remove an unmerged branch | `aa-m3eb` |
| 640 MB of model weights re-downloaded per worktree gate | `aa-cepx` |
| Codex cannot build Swift in its sandbox | structural, no bead |
| Gates A, B and C unmeasured: five merged pull requests, five sessions, and ten pull requests' worth of post-merge escapes before anyone widens the round budget | — |

The 19 September read-only review is scheduled and closes the deferred freeze bead. Until then, a
rule edit must cite the metric it moves.

## Learnings

- **Count the loop.** "Repeat until GO" cannot fail. "Refuse round 4 without the owner's quoted
  words" can, and did three times that week.
- **Let the tracker define done.** If the latest review finding replaces the issue's acceptance
  criteria, the reviewer controls the branch. Print the goal each round.
- **Resume the reviewer.** A new reviewer each round creates a ratchet. Reuse the thread, attach
  prior findings, and ask the reviewer to call GO plainly rather than inflate severity.
- **Keep triage short; make fixing a task.** The orchestrator labels each finding FIX, BEAD, or
  UNVERIFIED. Codex handles the round's reproductions, fixes, and negative controls together.
- **Read runtime behavior before writing rules.** Three rule edits described assumptions rather
  than the plugin: the wrapper is not the job, the sandbox is not the machine, and the slash command
  is not callable.
- **Test instruments on real samples.** The collect parser passed a hand-written fixture but never
  matched a real log. A guard is not evidence until it has been seen going red.
- **Do not rewrite global rules mid-incident.** Twelve live commits landed in six days, several
  correcting one another. The freeze was the response; its first-day breach showed how entrenched
  the habit was.
- **Keep the gate, but fail fast.** The ledger shows that the gate and reviews found real defects.
  The waste came from paying the full gate on every fix and checking acknowledgements last.
- **A cap stops a loop; it does not create convergence.** Three pull requests stopped at the cap
  and still needed a person. The next levers are reviewer calibration and triage discipline, not a
  larger budget.
- **Fix conflicting instructions at their source.** Three commits carried the attribution
  blocker; one template and four configuration values caused it.

## What this entry cannot establish

This entry cannot provide token or dollar totals: its counts are transcript occurrences and ledger
rows, not billing data. It does not establish that the delegation rate caused useful work. It also
cannot map every pull request to its review rounds because the acknowledgement ledger is sha-keyed
and several rows cannot be joined to a PR number. Ledger claims that a reviewer was "fresh" or that
a negative control ran remain assertions; they were cited, not replayed. The sources disagree on
whether the fabricated blocker belonged to AudioApp PR #8 or PR #10, and the claim was not
replayed. Whether there were others is unknown.

## Appendix — baseline and targets

| Measure | Baseline |
|---|---|
| Review rounds per branch, AudioApp `.build/merge-gate/acks`, 08-30→09-04 | 1, 1, 2, 5, 6, 4, 2 |
| AudioApp PR #8 | session: 12 rounds; 22 commits; 19 `fix(` |
| AudioApp PR #10 | 4 rounds; blockers 4→9→6; one fabricated |
| Session `5f8ebb39` | 2,360 assistant messages; 963 Bash; 60 Agent; 65 `merge-gate` invocations; 156 `test.sh`; 90 `swift build` |
| Peer messages per session | 29, 20, 17, 15, 14 |
| Feature PR open→merge | AudioApp PR #2: 74h; AudioApp PR #4: 59h; AudioApp PR #3: 49h |
| Rule rewrites in this repo | 11 in 8 days |

| Target | Budget |
|---|---|
| Rounds | ≤2 typical; hard cap 3 |
| `fix(` after first review | ≤3 |
| `merge-gate` runs | ≤2 per PR |
| Peer messages | ≤6 per session |
| Assistant messages | ≤150 per merged PR |
| Feature PR | ≤12h |
| Post-merge escapes | not above ≈2 per 10 PRs |

| Gate | Measure | On fail |
|---|---|---|
| A — after the rule+gate land | Next 5 merged AudioApp PRs: rounds ≤3, `fix(` ≤3, gate runs ≤2, ack fields parse | Fix the instrument or the text; never raise the cap. |
| B | Next 5 sessions: peer messages ≤6, assistant messages/PR ≤150 | — |
| C | 10 PRs: escapes not above baseline | Widen the budget to 4 only on a bead proving a round ≥4 would have caught an escape. |
