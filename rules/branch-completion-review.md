# Branch Completion Review (Refactor Pass + Adversarial Go/No-Go)

Two mandatory review stages sit between "the branch is functionally complete" and "a PR may be
opened", in this order:

```
functionally complete (features done, QA passed, quality gates green)
  → 1. REFACTOR REVIEW   (dedupe & simplify the branch's own diff; separate refactor commit)
  → 2. ADVERSARIAL REVIEW (independent top-tier agent, veto power, VERDICT: GO / NO-GO)
  → PR body drafting / approval flow (per project rules)
  → PR
```

Neither stage is optional for a non-trivial branch. Green gates and passing QA qualify a branch as
*working*; these two stages qualify it as *finished*.

## Why this rule exists

Both stages earned their place on the same branch, on the same day (2026-08-06, SetDigger,
`feat/slide-in-demo-cta` — two CMS-managed marketing features built by parallel clone-the-sibling
authoring):

1. **Refactor pass:** clone-the-sibling authoring (fast, correct, the right way to build feature
   #2 from feature #1) left **8 duplication sites** — cloned fetch functions, cloned
   path-condition logic + the type shape it operates on, cloned storage getters/setters, cloned
   close-button JSX, repeated GROQ field groups, repeated schema field triplets. A single
   `refactor(...)` commit collapsed all of them. None of this was visible to lint, typecheck, or
   QA — it was invisible to every existing gate precisely because it *worked*.
2. **Adversarial review:** after ALL gates were green — code-quality passes, two browser-QA
   rounds, the refactor pass itself — an independent adversarial agent still found a
   code-confirmed **BLOCKER**: a root-layout-mounted exit-intent detector whose armed listener
   survived client-side navigations, so it could burn its once-per-session token invisibly on an
   excluded page and then pop its modal with no trigger on the next eligible page. It sat exactly
   in a gap that an interrupted QA run had left — and the orchestrating session, having written
   the code, read right past it. The same review also caught an **undisclosed behavior change to
   live third-party script gating** buried in a feature commit, and a CMS-trust hole in a
   "never co-occur" invariant. Verdict: NO-GO. One fix commit later, a re-review traced every
   original failure scenario against the new code and returned GO.

The pattern in both: the author's own checks verify what the author thought about. These stages
exist to catch what the author didn't.

## Stage 1 — Refactor review

| Step | Detail |
|------|--------|
| 1. Scope | `git diff origin/<integration>...HEAD` only. Pre-existing code is out of bounds — never "improve" files the branch didn't introduce or touch, however tempting. |
| 2. Hunt | Duplicated functions/JSX blocks (especially from clone-the-sibling authoring), duplicated type shapes, repeated schema field groups, repeated query fragments, copy-pasted try/catch shells → extract to shared utils/elements/helpers. Also: dead params, unused exports, altitude cleanups. `/simplify` covers this hunt where available; a purpose-briefed subagent works equally. |
| 3. Judge | Not all duplication merits extraction: leave apart things with genuinely different semantics (e.g. a delay-timer hook vs an event-detector hook), and skip any unification that would change behavior of published/live content. Two consumers with identical logic over an identical shape = extract; two consumers with coincidentally similar code = leave. |
| 4. Verify | Zero-behavior-change proof, falsifiable (`verification-integrity.md`): exported names, storage keys, emitted query strings, schema deep-equality (invoke `hidden`-style callbacks, don't just compare shapes) — each check paired with a negative control that fails on a mutated input. Then the project's standard gates. |
| 5. Land | A separate `refactor(...)` commit (never folded into feature commits) so reviewers can diff it independently. |
| 6. Report | Line/file counts come from the **actual commit** (`git show --stat`), never from an implementing agent's self-report — they diverged on the originating branch (claimed −100, actual +23). |

## Stage 2 — Adversarial review

An independent agent reviews the full branch diff with **veto power**. Its report must end with
exactly one of `VERDICT: GO` or `VERDICT: NO-GO`.

### Setting it up

| Aspect | Requirement |
|--------|-------------|
| Model | Highest reasoning tier available (per the model-routing table: Fable, falling back to Opus). The whole point is a reviewer at least as capable as the author. |
| Access | Read-only: no edits, no commits. It MAY run the project's quality gates and read-only commands, and write scratch scripts to the session scratchpad. |
| Prompt: context | Full branch inventory (commits, features, requirements as given by the client/user), the project's known gotchas, and the exact gate commands. |
| Prompt: evidence status | Label prior verification honestly — what was gate-verified, what was browser-QA'd, and **what was never covered** (interrupted runs, env-blocked checks). Tell it to weight attention toward the gaps. Per `verification-integrity.md`: don't instruct it to trust your results; let it contradict you. |
| Prompt: attack surface | Seed a minimum checklist (SSR/hydration, listener/observer lifetimes across client navs, state that outlives rendering, invariants under CMS/config edits, refactor behavior-drift, a11y, perf, tracking shapes, "anything that contradicts the commit messages") — and invite angles beyond it. |
| Prompt: honesty | A clean branch gets `GO` with a short confirmed-checks list — manufactured findings are as much a failure as missed ones. |
| Output | Findings ranked BLOCKER/MAJOR/MINOR/NIT, each with file:line, concrete failure scenario, and required fix. |

### The NO-GO loop

1. Triage each finding: **fix in code**, or — where the finding is a judgment call the project
   owner controls (e.g. CMS-trust tradeoffs) — **resolve by explicit disclosure** in the PR body
   for sign-off. Disclosure is a legitimate resolution; silent acceptance is not.
2. Findings that require external evidence (e.g. "scan live data for affected patterns") get that
   evidence gathered, not argued away.
3. Fixes go through the normal pipeline: code-quality gate → commit agent (own `fix(...)` commit).
4. **Re-run the same adversary** (retained context), instructing it to re-trace its own original
   failure scenarios against the new code AND hunt for regressions the fixes introduced.
5. Repeat until `GO`. Only then does the branch proceed to PR-body drafting.

### Skip conditions

Same as Stage 1: trivially small diffs (single-file fixes, doc-only changes) may skip either
stage — and the skip must be stated explicitly, never silent.

## Relationship to other rules

- **`verification-integrity.md`** — both stages are applications of it: Stage 1's zero-behavior
  proof must be falsifiable with negative controls; Stage 2's reviewer is the independent
  second opinion whose contradiction you believe first. When the adversary and the author
  disagree, re-check before dismissing.
- **`parallel-authoring.md`** — clone-the-sibling / fan-out authoring is the expected *source* of
  Stage 1's findings. Using that authoring strategy is correct; sweeping its residue afterward is
  the other half of the bargain.
- **`agent-enforcement.md`** — NO-GO fixes are ordinary source changes: code-quality gate, then
  the commit agent. The adversary itself never edits.
- **`agent-purpose-statements.md`** — the adversary's prompt is a purpose statement with teeth:
  it knows its output decides the PR, so it optimizes for decisive findings over coverage theater.
- **Project-level PR-approval rules** (where present) run *after* GO — this rule feeds them, it
  does not replace them.
