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

Measured over 43 PRs on one project (StemLab, 2026-08-17 → 08-24; 39 cleared the old size gate).

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
`docs/reference/rule-histories.md` §branch-completion-review (2026-08-06, SetDigger
`feat/slide-in-demo-cta`):

| Finding | Class |
|---|---|
| An exit-intent listener registered in the root layout survived client-side navigations, firing the modal on pages that never opted in (the BLOCKER) | 1 lifetime |
| A live third-party script's gating was changed with no disclosure in the branch inventory | 4 external surface |
| A "these two never co-occur" invariant held only while the CMS kept behaving — nothing enforced it | 4 external surface |

That branch read as *pure UI and copy* under any size- or path-based trigger, which is exactly how
it reached review unclassified. Under the five classes it now triggers three ways: CMS-managed
content (4), a root-layout listener outliving navigation (1), and a once-per-session storage token
(2). Class 4 is the class that closes that gap — do not delete it for want of a row in the StemLab
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

### Setting it up

It runs **once** per branch (plus one re-review per NO-GO loop) — not per commit, not per fix.

| Aspect | Requirement |
|--------|-------------|
| Model | **The Claude subagent — Opus by default,** Fable only for architecture-class diffs (new abstractions, cross-service contracts, data-model changes) — invoked through the Agent tool. The reviewer must be at least as capable as the author, rarely more expensive than it. `/codex:adversarial-review` is the Codex equivalent and **user-typed only**: it carries `disable-model-invocation: true`, and the harness refuses the Skill route with "do not replicate this skill's workflow by other means" — so an agent does not call `codex.sh adversarial-review` through Bash either. Either route discharges this stage; the Codex one is available only when the user is present to type it. When they are not, the agent runs the Claude subagent rather than parking. (2026-09-03: for a few hours this row first named the slash command, which parked a branch, then named the companion command, which was a bypass — see rule-histories (e).) |
| Access | Read-only: no edits, no commits. It MAY run read-only commands and write scratch scripts to the session scratchpad. |
| Prompt: input | **Hand it the diff and the recorded gate results** (`git diff origin/<integration>...HEAD`, plus the `VERIFY RESULT:` / `CODE QUALITY RESULT:` lines per `pipeline-contract.md`) rather than making it re-explore the repo or re-run gates. Add the branch inventory (commits, features, requirements as given) and the project's known gotchas. |
| Prompt: evidence status | Label prior verification honestly — what was gate-verified, what was browser-QA'd, and **what was never covered** (interrupted runs, env-blocked checks). Tell it to weight attention toward the gaps. Per `verification-integrity.md`: don't instruct it to trust your results; let it contradict you. |
| Prompt: attack surface | Seed a minimum checklist **that names the same surfaces the trigger does** — the reviewer must not be sent hunting for classes the trigger guarantees it is never summoned for. Per class: **1** listener/observer lifetimes across client navigations, state that outlives rendering, SSR/hydration, teardown order, cancellation inheritance; **2** what is written vs read back, versioning and migration, and paths that *should* persist but don't; **3** whether each check could actually go red; **4** invariants that hold only while CMS/config/content behaves, third-party gating, flags; **5** render-thread and device-I/O hazards. Plus, always: refactor behavior-drift, a11y, perf, tracking shapes, and "anything that contradicts the commit messages" — and invite angles beyond the list. |
| Prompt: honesty | A clean branch gets `GO` with a short confirmed-checks list — manufactured findings are as much a failure as missed ones. |
| Output | Findings ranked BLOCKER/MAJOR/MINOR/NIT, each with file:line, concrete failure scenario, and required fix. |

### The NO-GO loop

1. Triage each finding: **fix in code**, or — for judgment calls the project owner controls (e.g. CMS-trust tradeoffs) — **resolve by explicit disclosure** in the PR body for sign-off. Disclosure is a legitimate resolution; silent acceptance is not.
2. Findings needing external evidence (e.g. "scan live data for affected patterns") get that evidence gathered, not argued away.
3. Fixes go through the normal pipeline: code-quality gate → commit agent (own `fix(...)` commit).
4. **Re-run the same adversary** (retained context) to re-trace its own original failure scenarios against the new code AND hunt for regressions the fixes introduced.
5. Repeat until `GO`. Only then does the branch proceed to PR-body drafting.

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
| How many review passes per branch? | **One.** The Codex stop-time review gate (`/codex:setup --enable-review-gate`), `/codex:review`, and this stage overlap almost entirely, and the stop-gate also reviews stops where the tree did not change. A repo picks one and states which. Where this stage's trigger applies, the stop-gate is off in that workspace. |
| Where does the real waste hide? | In project files that **restate** this rule instead of referencing it — they freeze the version they copied. Project files carry parameters only: which surfaces are class 1/4 *there*, the gate commands, the stated-skip line. See `claude-md-project-templates.md` § Referencing global rules. |

## Relationship to other rules

- `verification-integrity.md` — Stage 1's zero-behavior proof needs negative controls; Stage 2's reviewer is the second opinion you believe first.
- `parallel-authoring.md` — fan-out / clone-the-sibling authoring is the expected *source* of the refactor pass's findings, and is now its trigger (above) rather than a background justification for a standing stage.
- `agent-enforcement.md` / `agent-purpose-statements.md` — NO-GO fixes go through code-quality → commit (the adversary never edits), and its prompt is a purpose statement with teeth. Project-level PR-approval rules run *after* GO.
