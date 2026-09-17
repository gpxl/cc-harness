---
paths:
  - "**/.claude/skills/**"
  - "**/.claude/rules/**"
  - "**/.github/**"
  - "**/*PULL_REQUEST*"
  - "**/src/**"
  - "**/app/**"
  - "**/apps/**"
  - "**/packages/**"
  - "**/lib/**"
  - "**/Sources/**"
  - "**/scripts/**"
  - "**/rules/**"
---
# Branch Completion Review (Adversarial Go/No-Go)

One review stage — **mandatory whenever the trigger below fires** — sits between "the branch is functionally complete" and "a PR may
be opened" — and it runs on the branches whose *risk class* earns it, not on the branches that
happen to be large:

```
functionally complete (features done, QA passed, quality gates green)
  → (optional) refactor pass — /simplify over the branch's own diff, author's discretion
  → ADVERSARIAL REVIEW (independent top-tier agent, veto power, VERDICT: GO / NO-GO)
       ...if the branch touches lifetime · persistence · check-or-policy integrity ·
         trusted external surface · real-time
  → PR body drafting / approval flow (per project rules)
  → PR
```

Green gates and passing QA qualify a branch as *working*; this stage qualifies it as *finished*.
The author's own checks verify what the author thought about — this stage catches what the author
didn't. (Both stages originally earned their place on one branch in one day; that incident is in
`~/projects/cc-harness/docs/reference/rule-histories.md`. What happened to each of them since —
Stage 2 vindicated, Stage 1 demoted — is measured below.)

**A hands-on pass is not a substitute for this, and this is not a substitute for a hands-on pass.**
Where a project has one (exercising the built artifact by hand), it consistently finds a different
defect class: focus that never lands, a control that ignores `isEnabled`, a store writing to a
suite that does not exist, a placeholder clipped by its own trailing count. No static reviewer and
no scanner sees those. Keep both; they do not overlap.

## Trigger — does this apply at all?

Run this **first**, and state the answer either way. The trigger is the **risk class of what the
branch touches**, not how many lines it changed.

**Classify by what the branch's code *does*, not by which files it edits.** The single most
expensive miss in the evidence below was an *omission*: a new export path simply never called its
record-writer, so the diff never opened the store and a file-list reading said "pure UI → skip".
A path that *should* write, read back, migrate, tear down or unsubscribe is in its class even when
the diff contains no line from that layer.

| The branch touches | Stage 2 |
|---|---|
| **1. Lifetime, ordering, cancellation or concurrency** — task and subscription lifetimes, listener/observer registration that outlives a navigation or a view, SSR/hydration boundaries, actor hops, teardown and cleanup order, anything that can interleave | **runs** |
| **2. Persistence, serialisation or a data format** — what gets written, read back, versioned or migrated | **runs** |
| **3. Integrity of a check, or of the policy behind one** — gates, harnesses, tests, CI config, **and the rule/trigger/policy that decides whether any of them run, including this file** | **runs** |
| **4. A trusted external surface** — invariants that hold only while CMS/config/content behaves, third-party script or integration gating, feature flags | **runs** |
| **5. Real-time or hardware-adjacent code** — audio render paths (`Sources/Mixer`, `Sources/Recording` or equivalent), device I/O | **runs** (alongside the project's own audio-review policy) |
| None of the above — UI, copy, docs or config that changes **no gate, policy or trigger** | **skip**, stated in one line |

`Branch completion review: skipped (no lifetime/persistence/check-integrity/external-surface/realtime surface).`

### A first-pass filter for class 1

Mechanical aid, not an oracle — **any hit means class 1 runs**; zero hits means look again by hand,
because an omission leaves no line to match. Extend the pattern per language.

```bash
git diff -U0 origin/<integration>...HEAD | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
  | grep -nE '\bTask\b|\basync\b|\bawait\b|\bcancel|\bactor\b|DispatchQueue|@MainActor|addEventListener|useEffect|AbortController|unsubscribe|deinit'
```

`-U0` plus the `^[+-]` filter keeps it to **added and removed lines** — without them, unchanged
context counts and a UI-only commit reports 53 hits. `\bactor\b` is anchored on purpose: unanchored
`actor` matches `factory` and `refactor`, and fired on a prose line in the first draft of this rule.

Classes 2, 3 and 4 have no comparable one-liner; check them by path and intent —
class 2: `Codable|JSONEncoder|UserDefaults|migrat|schema|\.json|storage`, plus any new path that
*should* persist. Class 3: `scripts/**`, `.github/**`, `**/*test*`, `**/*gate*`, `**/.claude/rules/**`.
Class 4 is the hardest to self-classify because it is about *trust assumptions* rather than code
shape — look for CMS schema/content files, `*.config.*`, feature-flag modules, and third-party
`<Script>`/embed/SDK sites, then ask which invariant holds only while that external thing behaves.

A silent skip is not a skip; say it.

**The trigger must be machine-checked wherever a project has a gate to hang it on.** This is not
advisory, and it is the half of this rule that decides whether the other half helps at all. A
project with a merge gate MUST add a stage that computes the classes from the diff and FAILs until
an ack is recorded (reuse the existing ack infrastructure — it already does sha-anchoring and
invalidation). Where there is genuinely no gate, the trigger answer goes in the PR body, and a
stated skip is a **claim the PR's reviewer may reject**, not a decision the author closes.

Why it is mandatory: the previous trigger was diff size, and the stage still ran on only **10 of
39 eligible branches (26%)** — branches of 1,345 to 7,465 lines that plainly cleared a numeric
threshold and were skipped anyway. Diff size did not cause that; living in prose did. A number is
the *easiest* possible trigger to comply with, so narrowing the scope to risk classes — a judgement
call, made by the author, the party this rule exists to second-guess — can only lower coverage
further unless something mechanical asks the question. Narrowing scope and leaving the check
advisory is the one combination that makes this change a net loss.

### Why these classes

Measured over 43 PRs on one project (AudioApp, a native macOS/Swift audio app, 2026-08-17 → 08-24; 39 cleared the old size gate).

**Every BLOCKER, and every MAJOR the audit classified, that Stage 2 *produced* in the window came
from one of these surfaces.** That wording is deliberate and the limit matters: Stage 2 ran on 10 of 39 eligible
branches, so this describes **the reviewed quarter**, not the population. The other 29 branches
contribute no findings *by construction*, and "that branch produced no BLOCKER" is not a
measurement when nothing looked — `verification-integrity.md` §"Instruments must distinguish
healthy from not looking" applies to this table as much as to anything else.

What keeps the classes standing despite the sampling problem is a second, independent set: the
same window's **9 post-merge escapes**, found by gates and users rather than by Stage 2, fall in
classes 1 and 3 (a `requestStop()` with zero call sites — cancellation; three uitest regressions —
check integrity). Consistent, but consistency is not a second sample. Treat the classes as
well-evidenced for correctness-critical surfaces and **provisional at the edges** — if escapes rise
above this window's baseline of 9 post-merge escapes over 43 PRs, widen the classes before
touching anything else.

| Finding | Class |
|---|---|
| `disconnect()` cancelled asynchronously then emptied the queue synchronously — a half-written export folder that looks finished in Finder, plus a stale handle that would later delete the *wrong* track's folder | 1 lifetime/ordering |
| A validation run in `Task.detached` (which does not inherit cancellation) landed the first job's late verdict on the second job's row | 1 lifetime/ordering |
| An export path bypassed its own record-writer, so the index was never written — dig a crate, quit, come back empty. Had been live on `main` for two days | 2 persistence |
| Provenance was never populated in production: three navigation links dead for 100% of real exports (MAJOR, not BLOCKER) | 2 persistence |
| A stored loop range was clamped at load before the tempo arrived, silently narrowing it | 2 persistence |
| A target was in the gate's *trigger* list but not in the scanner's own target list — the stage fired, scanned zero files, and printed PASS. Four such gates, including one that had never built the second app product at all | 3 check integrity |

**Classes 1 and 4 additionally carry the founding incident** — a different project and a different
stack, which is the point: this rule is global and the 43-PR window is one Swift app. From
`docs/reference/rule-histories.md` §branch-completion-review (2026-08-06, AudioWebsite, a CMS-backed marketing web app,
`feat/slide-in-demo-cta`):

| Finding | Class |
|---|---|
| An exit-intent listener registered in the root layout survived client-side navigations, firing the modal on pages that never opted in (the BLOCKER) | 1 lifetime |
| A live third-party script's gating was changed with no disclosure in the branch inventory | 4 external surface |
| A "these two never co-occur" invariant held only while the CMS kept behaving — nothing enforced it | 4 external surface |

That branch read as *pure UI and copy* under any size- or path-based trigger, which is exactly how
it reached review unclassified. Under the five classes it now triggers three ways: CMS-managed
content (4), a root-layout listener outliving navigation (1), and a once-per-session storage token
(2). Class 4 is the class that closes that gap — do not delete it for want of a row in the AudioApp
table, because its evidence is here, not there.

The counter-evidence, which is why the trigger is not simply "everything": roughly **40% of Stage
2's findings by count were doc/comment minors**, and the pure-UI and pure-copy branches it did
review yielded no BLOCKER — while the project's hands-on pass found 7 real user-facing defects on
those same surfaces in four days. The two reviews have different yields on different surfaces.
Narrowing this trigger buys back the budget that makes running it on 100% of the branches that
*do* owe it affordable, which is the trade — not a saving.

## Stage 1 — Refactor review (no longer a mandatory stage)

**Demoted 2026-08-24.** State the reason precisely, because the obvious phrasing is a category
error: over the same 43-PR window Stage 1 had **zero measured correctness yield**, and its
**maintainability yield was not measured at all**. It is defined by its own step 4 as a
*zero-behaviour-change* pass — judging it by defects-found asks it for something it was never
designed to produce, and four days cannot see the horizon on which duplication becomes divergent
clones. What the window does show is a cost: on one branch the pass **injected** a defect, swapping
a passing text run for a captioned badge measuring 3.03:1 in dark — a WCAG 1.4.3 AA failure on the
appearance that product ships by default, caught by the hands-on HIG checklist and by nothing else.

So it stops being a gate, but not a coin flip. **Run it when the branch was authored by fan-out or
clone-the-sibling** (`parallel-authoring.md`) — that is where its one demonstrated yield came from,
8 duplication sites on the founding branch. Otherwise it is `/simplify`-grade work at the author's
discretion, over the branch's own diff, with no mandatory separate commit. Either way, if the pass
changes anything rendered it re-enters the project's hands-on UI review, since that is what caught
the only defect it has been shown to produce.

Note the standing tension, deliberately left visible: `parallel-authoring.md` is always-loaded and
actively *encourages* the clone-the-sibling authoring that manufactures this debt. If a project
leans on fan-out, the trigger above will fire often, and that is correct.

### Method (when you run it)

| Step | Detail |
|------|--------|
| 1. Scope | `git diff origin/<integration>...HEAD` only. Pre-existing code is out of bounds — never "improve" files the branch didn't introduce or touch, however tempting. |
| 2. Hunt | Duplicated functions/JSX blocks (especially from clone-the-sibling authoring), duplicated type shapes, repeated schema field groups, repeated query fragments, copy-pasted try/catch shells → extract to shared utils/elements/helpers. Also: dead params, unused exports, altitude cleanups. `/simplify` covers this hunt where available; a purpose-briefed subagent works equally. |
| 3. Judge | Not all duplication merits extraction: leave apart things with genuinely different semantics (e.g. a delay-timer hook vs an event-detector hook), and skip any unification that would change behavior of published/live content. Two consumers with identical logic over an identical shape = extract; two consumers with coincidentally similar code = leave. |
| 4. Verify | Zero-behavior-change proof, falsifiable (`verification-integrity.md`): exported names, storage keys, emitted query strings, schema deep-equality (invoke `hidden`-style callbacks, don't just compare shapes) — each check paired with a negative control that fails on a mutated input. Then the project's standard gates. |
| 5. Land | Prefer a separate `refactor(...)` commit so reviewers can diff it independently — no longer mandatory, since the pass itself no longer is. |
| 6. Report | Line/file counts come from the **actual commit** (`git show --stat`), never from an implementing agent's self-report — they have diverged in practice. |

## Stage 2 — Adversarial review

An independent agent reviews the full branch diff with **veto power**. Its report must end with
exactly one of `VERDICT: GO` or `VERDICT: NO-GO`.

### Before round 1: the author's own pass

`scripts/review-round.sh <base> --self-check` dispatches one read-only task that works the five risk
classes over the author's own diff with the same acceptance criteria and evidence the reviewer will
get, and lists every finding it expects an adversary to raise. It spends **no** round: it writes no
counter, no scope stamp and no reviewer thread, and it is refused once round 1 has been dispatched.
`--collect <job-id> --round 0` records it as `<slug>-r0-self-review.md`, which every later round's
prompt inlines — so the reviewer re-checks those claims and targets what the self-check did not cover, and
its absence is stated rather than silent.

Why it exists: first deliveries reach round 1 with no adversarial pass at all, and round 1 then
spends itself on defects the author could have found. Measured 2026-09-16 — one repo's R1 returned
five MAJORs including a concurrency test that could not fail; another's returned four, every one of
them the "this check cannot go red" class. Triage the r0 findings exactly like a round's
(FIX/BEAD/UNVERIFIED) and let the fixes land before dispatching round 1.

### Setting it up

It runs under a **three-round budget** per branch — not per commit, not per fix.

| Aspect | Requirement |
|--------|-------------|
| Model | **Codex, via `/codex:rescue` read-only, with the Stage 2 prompt rows below and the Output contract as the task text.** Foreground (`--wait`) for a small, bounded diff; otherwise `--background`, and the verdict comes back through the harness's own bridge — `codex-wait.sh` plus the job's `logFile` (`codex-dispatch-protocol.md`) — because `/codex:status` and `/codex:result` are user-typed only. For R2/R3, use `--resume-last` only when the newest plugin state job record's `threadId` matches R1's recorded reviewer thread; otherwise start a fresh reviewer with R1's findings, dispositions, and fix commit SHA (cch-9o4). **What this route rests on, stated exactly:** (i) the plugin's agent contract (`skills/codex-cli-runtime`, line 24) says to omit `--write` when the user "only wants review, diagnosis, or research without edits" — a flag rule that presupposes review-shaped `task` requests, not a routing instruction; its routing line (18: "diagnosis, planning, research, and explicit fix requests") does not list review; (ii) `task` is not one of the subcommands the contract bars (`review`, `adversarial-review`, `status`, `result`, `cancel`), and it runs the caller's own prompt rather than re-entering the flagged review template; (iii) a user decision on 2026-09-03. An inference the user chose to stand behind, not a documented instruction — and the rule says so because a citation that survives being checked is the only kind worth loading. `/codex:adversarial-review` stays user-typed only (`disable-model-invocation: true`) and an agent never calls `codex.sh review` / `codex.sh adversarial-review`; when the user is present they may type the slash command, and either route discharges the stage. Claude fallback, only on a stated Codex `ready: false` / login failure: the Claude subagent, Opus by default, Fable for architecture-class diffs (new abstractions, cross-service contracts, data-model changes). Measured 2026-09-03: that fallback produced two NO-GOs with real MAJORs on this rule's own branch, so it is a fallback on cost, not on quality. Cross-vendor parity with a Codex-authored branch is assumed, not verified. |
| Access | Read-only: no edits, no commits. It MAY run read-only commands and write scratch scripts to the session scratchpad. |
| Prompt: input | **Hand it the diff and the recorded gate results** (`git diff origin/<integration>...HEAD`, plus the `VERIFY RESULT:` / `CODE QUALITY RESULT:` lines per `pipeline-contract.md`) rather than making it re-explore the repo or re-run gates. Add the bead's acceptance criteria, branch inventory (commits, features, requirements as given), and the project's known gotchas; the reviewer labels out-of-scope findings itself. |
| Prompt: evidence status | Label prior verification honestly — what was gate-verified, what was browser-QA'd, and **what was never covered** (interrupted runs, env-blocked checks). Tell it to weight attention toward the gaps. Per `verification-integrity.md`: don't instruct it to trust your results; let it contradict you. |
| Prompt: attack surface | Seed a minimum checklist **that names the same surfaces the trigger does** — the reviewer must not be sent hunting for classes the trigger guarantees it is never summoned for. Per class: **1** listener/observer lifetimes across client navigations, state that outlives rendering, SSR/hydration, teardown order, cancellation inheritance; **2** what is written vs read back, versioning and migration, and paths that *should* persist but don't; **3** whether each check could actually go red; **4** invariants that hold only while CMS/config/content behaves, third-party gating, flags; **5** render-thread and device-I/O hazards. Plus, always: refactor behavior-drift, a11y, perf, tracking shapes, and "anything that contradicts the commit messages" — and invite angles beyond the list. |
| Prompt: honesty | A clean branch gets `GO` with a short confirmed-checks list — manufactured findings are as much a failure as missed ones. |
| Prompt: R2+ calibration | **Partly machine-checked since 2026-09-17** — `review-round-selftest.sh` asserts on the dispatched prompt that the classification line, the anti-manufacture sentence and the POLISH cap are sent, and that the sentence is withheld at R1. The `dig_deeper_nudge` clause below is **not** checked: the nudge lives in the prompting skill, not in `review-round.sh`, so nothing here can observe whether it was omitted. Treat that clause as a contract on the human or agent assembling the prompt. The checked half exists because for four branches this row was mandated and the script sent none of it: R1 and R2 alike got a bare classify-and-ship line, so every reviewer carried the dig-deeper posture and none carried the sentence restraining it. A contract nothing checks is a contract that silently stops being sent. From R2 omit the prompting skill's `dig_deeper_nudge`. Classify each finding **DECISION-CHANGING** or **POLISH**; report DECISION-CHANGING first. **"If you believe this branch is good enough to ship, say so plainly and early. Do not manufacture severity to seem rigorous."** |
| Output | Findings ranked BLOCKER/MAJOR/MINOR/NIT, each with file:line, concrete failure scenario, and required fix — **at most 3 POLISH findings, with the count stated when there are more** (DECISION-CHANGING is never capped; measured 2026-09-17, 37 of 59 findings across four branches were MINOR/NIT and every open backlog item was review-spawned, so an unbounded polish list is backlog nobody reads) — **plus a closing coverage map**: `COVERAGE:` followed by `traced=` (files and mechanisms actually read) and `not-traced=` (skipped, and why). `review-round.sh --collect` extracts it into the findings file, and the next round's prompt spends its budget on the recorded gaps after re-tracing prior findings. Measured 2026-09-16: round 3 of the 6-round branch found five defects in files unchanged since round 2, and round 5's finding had been present since round 2 — each fresh reviewer sampled a different third of the diff and nothing carried the gaps forward. A report with no map is recorded as `COVERAGE: (none recorded)`, so "nothing was skipped" and "nobody said" stay different answers. |

### The NO-GO loop

**Round budget: 3, per reviewed scope.** Not per branch: a branch that grows a feature between
rounds is not on its second look at the same code, it is on its first look at different code.
`review-round.sh` stamps the scope at R1 (the acceptance text plus every commit subject that is not
`fix`/`test`/`docs`/`chore`) and refuses the next round when that stamp moves, until
`--scope-changed "<what changed>"` declares it; the prior rounds are then archived and the counter
restarts. Restating what done means for the enlarged branch is the point of that declaration, but
the script cannot check that you did — it only requires the flag and a non-empty reason. The two
halves of the stamp are recorded separately, so the refusal names which one moved; when only the
acceptance *wording* changed and no scope-changing commit was added, `--acceptance-reworded "<why>"`
accepts the new text and **keeps** the counter, because the same code is being judged by the same
criteria in different words and a typo fix must not buy three more rounds. The stamp
reads commit *subjects*, so amending a commit's body or its diff moves nothing; declare a scope
change yourself when the code grew under an unchanged subject. Prefer one tracker item per PR — the 6-round branch measured on
2026-09-16 carried six, and its reviewed diff went 856 → 6,685 → 9,339 lines while the counter
climbed as though nothing had changed (rounds per branch then ran at a median of 3 against a target
of ≤2, which is the metric this edit moves).

**A round is never dispatched blind.** R1 is review. The script refuses to dispatch without
acceptance criteria, and refuses round N while any round k<N has no recorded findings file — both
were silent placeholders until 2026-09-16, and both rendered on every round of the 6-round branch.
Hand it the recorded gate lines with `--evidence-file`; when there are none the prompt says so
rather than printing a bare negative.

**R2/R3 are usually fresh reviewers, and that is a plugin limit, not a choice.** The Codex plugin
resumes only the *newest* tracked thread in a workspace, so the fix task between rounds takes the
slot (openai-codex 1.0.6 `executeTaskRun`; measured 6 of 6 rounds fresh). Give a fresh reviewer R1's
findings with each `FIX`/`BEAD`/`UNVERIFIED` disposition and the fix commit SHA, and tell it to
re-trace those scenarios first (cch-9o4). The findings file, not the thread, is the continuity
mechanism — `docs/reference/review-round-scripts.md` has the detail. Print every round:
`GOAL: <acceptance> | ROUND n/3 | OPEN BLOCKERS k | NEXT: <one action>`.

After R3 with open BLOCKERs, the orchestrator **STOPS** and escalates one paragraph to the user: merge with disclosure, authorize more budget, or shelve. R4 exists only after the user's explicit words in chat, quoted in the ack note.

### The acknowledgement is what a merge gate can read

The ack note is not only for the transcript. Write it into the pull-request body as one line:

```
REVIEW ACK: rounds=<n> verdict=<GO|NO-GO> open_blockers=<n> classes=<1-5 list> user_decision="<the owner's words>"
```

`scripts/review-ack-check.sh` validates it, and `scripts/trusted-pr-merge.sh` refuses to merge a
pull request that changes a check or the policy behind it without one it accepts, re-checking
after the candidate gate so a body edited mid-run buys nothing. `user_decision=` is required
whenever the verdict is NO-GO or blockers are open, which is how "merge with disclosure" stays a
decision someone actually made rather than a sentence in a summary. Until this was wired up the
merge rested on the orchestrator's own report of its own review, which is the same shape of
evidence this rule refuses everywhere else.

### Requesting rounds beyond the budget

Every request to exceed the regular three-round budget, or to extend an already approved
exception, **must include a convergence assessment before asking for approval**. More review is
not justified merely because the latest verdict is NO-GO. Keep the assessment concise and tie it
to the recorded findings, dispositions, fix commits, and verification results:

| Include | Required evaluation |
|---|---|
| Trajectory | Summarize each completed round's decision-changing findings: resolved with evidence, still open, newly discovered, or reopened. Track the same findings across rounds; a rename or severity change is not a new defect or a resolution. |
| Convergence judgment | State **converging**, **stalled/circular**, **diverging**, or **insufficient evidence**, and explain why. Falling counts alone do not prove progress: separate verified fixes and narrowing uncertainty from repeated disputes, contradictory requests, scope growth, and regressions introduced by fixes. Identify missing evidence rather than inferring progress. |
| Reason for an exception | Name the remaining decision-changing issue and what has changed that makes another round useful: a reproduced failure, a verified fix awaiting confirmation, new evidence, or a resolved requirement. Explain what the next round can establish that prior rounds could not. |
| Bounded proposal | Recommend continue, merge with disclosed risk, or shelve. If requesting continuation, specify the number of extra rounds, their exact scope, the expected exit evidence, and a stop condition. Default to one extra round; any larger request needs a reason. |

When rounds are stalled, circular, or diverging, recommend stopping the repeated review loop
unless there is a concrete change in evidence or approach that justifies a bounded exception.
For example, resolve a disputed requirement before asking another reviewer to revisit it.
Never treat elapsed effort, a new reviewer, or “one more pass” alone as evidence of convergence.
Further review still requires explicit user approval; a positive convergence assessment is not
authorization. Approval covers only the stated extension, not unlimited rounds. At its limit,
stop and provide an updated assessment before requesting another extension. Preserve the
assessment with the review record alongside the user's quoted decision.

| Triage line — one per finding | Action |
|---|---|
| **FIX** | On this branch only for a BLOCKER/MAJOR inside the bead's acceptance criteria with a reproduced failure — by the reviewer or by one Codex verification task, never by hand. |
| **BEAD** | Everything else: MINOR, NIT, forward-looking, test-hardening, out-of-scope MAJOR, or pre-existing. Never make a fix commit for these on the branch. |
| **UNVERIFIED** | A claimed red the reviewer could have executed and did not: one Codex verification attempt, then drop or bead. The fabricated BLOCKER on AudioApp PR #10 (2026-09-04) is the standing counterexample. |

Fixes are **one Codex task per round** carrying the full finding list, built from
`templates/review-fix-round.md`; negative controls are part of that task's contract, not orchestrator
work. That template exists because the fix round is where the loop is manufactured: on the branch
measured 2026-09-16, round 3's fix built a mechanism, rounds 4 and 5 each found a *different* defect
inside it, one fix shipped with a test pinning the behaviour its finding called wrong, and round 6
returned GO in one minute once it asked whether the mechanism should be restructured instead of
patched a third time. So the template makes three things mandatory — the findings verbatim, a
**siblings** sweep for the same failure class across the whole branch diff, and the **structural**
question once one mechanism has been patched twice — and it forbids telling the fixer how much
review budget is left, since the fixer can neither see nor spend it and answers the pressure by
widening its own scope; `scripts/fix-prompt-check.sh <prompt-file>` checks a written prompt for that
phrasing and names the offending line, so the ban is gated rather than remembered. A FIX task goes through the normal pipeline: code-quality gate (or `verify_cmd` when `quality_gate_pattern` is `(none)`) → commit agent (one `fix(...)` commit). R2/R3 re-run the same adversary to re-trace reproduced failures and check fix regressions; only `GO`, or the user decision above, proceeds to PR-body drafting.

### Skip conditions

**The risk-class trigger at the top is the only one.** A branch touching none of the five classes
skips, in one stated line. A branch touching any of them runs Stage 2, **at any diff size** — a
four-line change to a teardown path is exactly the shape of the findings above, and the largest
single miss in the evidence was a path that never called the writer it should have.

## Cost and ordering

Settled 2026-09-03 after a project asked whether this stage and the code-quality gate were
redundant, whether to reorder them, or to move the adversary in front of the task
(`docs/reference/rule-histories.md` §branch-completion-review). The answers are rules, not
preferences:

| Question | Answer |
|---|---|
| Redundant with code-quality / verify? | **No.** Those are lint, typecheck, tests — deterministic. This stage's one founding BLOCKER was an *omission* after every gate was green. Different defect classes; neither replaces the other. |
| Order | **Deterministic gates → commit → adversary → PR body.** Cheap, falsifiable checks before an expensive model read is fail-fast, and a NO-GO costs the same number of adversary runs wherever the commit sits. Committing first also makes the reviewed diff exactly `origin/<integration>...HEAD`. |
| Adversary before the task starts? | **A complement, never a substitute.** A plan-stage pass (`/grill-me`) catches scope and approach on design-decision tasks — schema changes, shared-component restyles, new abstractions. It cannot see the omission class, because there is no code yet. Author's discretion, and it does not discharge this stage. |
| How many rounds? | **Three, then the user decides with a convergence assessment and a bounded extension proposal** — see “Requesting rounds beyond the budget” above. Measured 2026-09-04: 12-round and 4-round chains, blockers diverging 4→9→6. See the retrospective appendix, `docs/retrospectives/2026-09-05-codex-integration-and-review-loops.md`. |
| How many review passes per branch? | **One.** The Codex stop-time review gate (`/codex:setup --enable-review-gate`), `/codex:review`, and this stage overlap almost entirely — **assessed, not measured**: the stop-gate has one recorded catch (a reap-while-running bug) and reviews at the stop that introduced a defect rather than at branch end, so the overlap is a judgment call. What is not a judgment call is precedence: **when this stage's trigger fires, Stage 2 runs and is never the pass that gets dropped.** The stop-gate is a per-workspace setting while the trigger is per-branch, so a repo whose branches can trigger Stage 2 leaves the stop-gate off permanently and states so; a repo whose branches never trigger it may keep the stop-gate as its one pass. |
| Where does the real waste hide? | In project files that **restate** this rule instead of referencing it — they freeze the version they copied. Project files carry parameters only: which surfaces are class 1/4 *there*, the gate commands, the stated-skip line. See `claude-md-project-templates.md` § Referencing global rules. |

## Relationship to other rules

- `verification-integrity.md` — Stage 1's zero-behavior proof needs negative controls; Stage 2's reviewer is the second opinion you believe first.
- `parallel-authoring.md` — fan-out / clone-the-sibling authoring is the expected *source* of the refactor pass's findings, and is now its trigger (above) rather than a background justification for a standing stage.
- `agent-enforcement.md` / `agent-purpose-statements.md` — NO-GO fixes go through code-quality (or `verify_cmd` when the pattern is `(none)`) → commit (the adversary never edits), and its prompt is a purpose statement with teeth. Project-level PR-approval rules run *after* GO.
