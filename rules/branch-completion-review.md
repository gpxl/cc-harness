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
# Branch Completion Review (Refactor Pass + Adversarial Go/No-Go)

Two **mandatory** review stages sit between "the branch is functionally complete" and "a PR
may be opened", in this order:

```
functionally complete (features done, QA passed, quality gates green)
  → 1. REFACTOR REVIEW   (dedupe & simplify the branch's own diff; separate refactor commit)
  → 2. ADVERSARIAL REVIEW (independent top-tier agent, veto power, VERDICT: GO / NO-GO)
  → PR body drafting / approval flow (per project rules)
  → PR
```

Green gates and passing QA qualify a branch as *working*; these stages qualify it as
*finished*. The author's own checks verify what the author thought about — these stages catch
what the author didn't. (Both stages earned their place on one branch in one day; the incident
is in `~/projects/cc-harness/docs/reference/rule-histories.md`.)

## Size gate — do these stages apply at all?

Run this **first**, and state the answer either way:

```bash
git diff --shortstat origin/<integration>...HEAD
git diff --name-only origin/<integration>...HEAD | grep -vE '(test|spec)' | wc -l
```

| Branch diff | Stages |
|---|---|
| ≥200 changed lines **or** ≥5 non-test files | Both stages run |
| Below both thresholds | **Skip both.** One line: `Branch completion review: skipped (<N> lines, <M> non-test files — below threshold).` |

A silent skip is not a skip; say it. Only a diff that clears the threshold justifies the cost.

**The size gate above is the only skip condition.** For any branch that clears it, both
stages are mandatory — neither is optional, and "the gates are green" is not a substitute
(green gates prove the branch *works*; these stages decide it is *finished*).

## Stage 1 — Refactor review

| Step | Detail |
|------|--------|
| 1. Scope | `git diff origin/<integration>...HEAD` only. Pre-existing code is out of bounds — never "improve" files the branch didn't introduce or touch, however tempting. |
| 2. Hunt | Duplicated functions/JSX blocks (especially from clone-the-sibling authoring), duplicated type shapes, repeated schema field groups, repeated query fragments, copy-pasted try/catch shells → extract to shared utils/elements/helpers. Also: dead params, unused exports, altitude cleanups. `/simplify` covers this hunt where available; a purpose-briefed subagent works equally. |
| 3. Judge | Not all duplication merits extraction: leave apart things with genuinely different semantics (e.g. a delay-timer hook vs an event-detector hook), and skip any unification that would change behavior of published/live content. Two consumers with identical logic over an identical shape = extract; two consumers with coincidentally similar code = leave. |
| 4. Verify | Zero-behavior-change proof, falsifiable (`verification-integrity.md`): exported names, storage keys, emitted query strings, schema deep-equality (invoke `hidden`-style callbacks, don't just compare shapes) — each check paired with a negative control that fails on a mutated input. Then the project's standard gates. |
| 5. Land | A separate `refactor(...)` commit (never folded into feature commits) so reviewers can diff it independently. |
| 6. Report | Line/file counts come from the **actual commit** (`git show --stat`), never from an implementing agent's self-report — they have diverged in practice. |

## Stage 2 — Adversarial review

An independent agent reviews the full branch diff with **veto power**. Its report must end with
exactly one of `VERDICT: GO` or `VERDICT: NO-GO`.

### Setting it up

It runs **once** per branch (plus one re-review per NO-GO loop) — not per commit, not per fix.

| Aspect | Requirement |
|--------|-------------|
| Model | **Opus by default.** Fable only for architecture-class diffs (new abstractions, cross-service contracts, data-model changes). The reviewer must be at least as capable as the author — rarely more expensive than it. |
| Access | Read-only: no edits, no commits. It MAY run read-only commands and write scratch scripts to the session scratchpad. |
| Prompt: input | **Hand it the diff and the recorded gate results** (`git diff origin/<integration>...HEAD`, plus the `VERIFY RESULT:` / `CODE QUALITY RESULT:` lines per `pipeline-contract.md`) rather than making it re-explore the repo or re-run gates. Add the branch inventory (commits, features, requirements as given) and the project's known gotchas. |
| Prompt: evidence status | Label prior verification honestly — what was gate-verified, what was browser-QA'd, and **what was never covered** (interrupted runs, env-blocked checks). Tell it to weight attention toward the gaps. Per `verification-integrity.md`: don't instruct it to trust your results; let it contradict you. |
| Prompt: attack surface | Seed a minimum checklist (SSR/hydration, listener/observer lifetimes across client navs, state that outlives rendering, invariants under CMS/config edits, refactor behavior-drift, a11y, perf, tracking shapes, "anything that contradicts the commit messages") — and invite angles beyond it. |
| Prompt: honesty | A clean branch gets `GO` with a short confirmed-checks list — manufactured findings are as much a failure as missed ones. |
| Output | Findings ranked BLOCKER/MAJOR/MINOR/NIT, each with file:line, concrete failure scenario, and required fix. |

### The NO-GO loop

1. Triage each finding: **fix in code**, or — for judgment calls the project owner controls (e.g. CMS-trust tradeoffs) — **resolve by explicit disclosure** in the PR body for sign-off. Disclosure is a legitimate resolution; silent acceptance is not.
2. Findings needing external evidence (e.g. "scan live data for affected patterns") get that evidence gathered, not argued away.
3. Fixes go through the normal pipeline: code-quality gate → commit agent (own `fix(...)` commit).
4. **Re-run the same adversary** (retained context) to re-trace its own original failure scenarios against the new code AND hunt for regressions the fixes introduced.
5. Repeat until `GO`. Only then does the branch proceed to PR-body drafting.

### Skip conditions

**The size gate at the top is the only one.** Below it (which doc-only branches almost
always are): skip both stages, stated in one line, never silent. Above it: both stages are
mandatory, no exceptions.

## Relationship to other rules

- `verification-integrity.md` — Stage 1's zero-behavior proof needs negative controls; Stage 2's reviewer is the second opinion you believe first.
- `parallel-authoring.md` — fan-out / clone-the-sibling authoring is the expected *source* of Stage 1's findings.
- `agent-enforcement.md` / `agent-purpose-statements.md` — NO-GO fixes go through code-quality → commit (the adversary never edits), and its prompt is a purpose statement with teeth. Project-level PR-approval rules run *after* GO.
