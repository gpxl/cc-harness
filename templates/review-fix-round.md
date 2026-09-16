# Review fix-round template

The prompt an orchestrator hands to the **one implementation task per review round** that closes a
`VERDICT: NO-GO` (`rules/branch-completion-review.md` § The NO-GO loop). Fill every placeholder and
delete the guidance blockquotes; what is left is the whole prompt.

Three sections are mandatory — FINDINGS, SIBLINGS, STRUCTURE — because each one corresponds to a
measured way that fix rounds manufacture the next round. The evaluation is in
`docs/retrospectives/2026-09-05-codex-integration-and-review-loops.md` and the 2026-09-16 follow-up:
on one branch, round 3's fix built a mechanism, round 4 found a defect in it, round 5 found a
different defect in the same mechanism, and round 6 got a GO in one minute once it was finally asked
whether the mechanism should be restructured instead of patched again.

---

## Prompt

You are closing branch-review round `<n>` findings on `<branch>`. Worktree: `<absolute path>`.

### Context

> One paragraph: what the branch does, the mechanism the findings touch, and the product bar that
> makes a defect here matter. Name the files to read first. Do not summarise the findings here —
> they get their own section, verbatim.

### Acceptance criteria (verbatim)

> The branch's definition of done, copied from the tracker item or `REVIEW_ROUND_ACCEPTANCE`
> exactly as `review-round.sh` gave it to the reviewer. It is the boundary the Constraints section
> below refers to, so it has to actually appear in the prompt — a constraint that points at text
> the task was never shown is not a constraint.

```
<the acceptance criteria, verbatim>
```

### 1. FINDINGS

> The reviewer's findings **verbatim**, each with the orchestrator's disposition. Verbatim matters:
> a paraphrase loses the failure scenario, and the failure scenario is what the fix has to close.
> Keep `file:line` intact. Include only findings dispositioned FIX — a BEAD or UNVERIFIED finding is
> not this task's work, and listing it invites scope creep.

| # | Severity | Finding (verbatim) | Disposition |
|---|---|---|---|
| 1 | `BLOCKER` / `MAJOR` | `<the reviewer's own words, with file:line>` | FIX |

For each finding: write or strengthen the test **first**, prove it fails against the current
committed code, then fix. Report the mutation that proves each test can go red
(`~/.claude/rules/verification-integrity.md`).

**Check that no test you write pins the behaviour a finding calls wrong.** On the measured branch a
fix shipped with a test asserting the defective behaviour, so the next round found the defect still
there behind a green suite.

### 2. SIBLINGS

A finding is a sample, not a census. The reviewer read part of the diff under a time budget; it
reported the instance it saw.

For **each** finding, search the whole branch diff for the same failure class and fix every instance
you find. Report per finding:

- what you searched for (the pattern, the paths, the call sites)
- every instance found, fixed or deliberately left with a reason
- `searched, no other instance` when that is the answer — it is a real result, and saying it is how
  the next round knows not to look again

### 3. STRUCTURE

> Fill in when the same mechanism has now been changed in two or more rounds. Delete this section
> only when it genuinely does not apply.

`<mechanism>` has now been patched in rounds `<k>` and `<n>`. Before writing a third patch, say
whether it needs **restructuring** rather than another point fix, and if so propose the
restructuring concretely: what the new shape is, what it makes impossible, and what it costs.

That answer is more valuable than another point fix, and the owner has asked for it. A mechanism
that produces a defect every round is not unlucky; it is the finding.

### Constraints

- **No git.** Do not stage, commit, push, or rebase. Report the paths you changed and an intended
  commit subject; the supervisor commits through the normal pipeline.
- Run the project's own verification and read its exit code directly, never through a pipe.
- Stay inside the acceptance criteria quoted above. A defect you find outside them goes in your
  report as a candidate for the tracker, not into this commit.

---

## What this template forbids

**Never tell the implementation task how much review budget is left.** No "this is the last allowed
round", no "round 3 of 3", no countdown of any kind.

The round budget is the orchestrator's instrument for deciding when to stop and ask the owner. The
implementation task cannot see the budget, cannot spend it, and cannot influence it. Telling it the
budget is nearly gone does not make the fix more complete; it makes the task widen its own scope to
be safe, which is how a fix round grows into the thing the next round has to review. On the measured
branch the round-3 fix prompt carried exactly that sentence, and rounds 4 and 5 each found a fresh
defect inside what it produced.

---

## Worked example

> Invented subject. Substitute a purpose-based pseudonym for any real project
> (`~/.claude/rules/public-surface-hygiene.md`).

You are closing branch-review round 2 findings on `feat/cache-eviction`. Worktree:
`/tmp/example/worktree`.

**Context.** This branch adds a size-bounded in-memory cache in front of a slow catalogue lookup.
Entries are evicted when the byte budget is exceeded. The product bar: a stale entry served after
invalidation is a correctness bug, not a performance one. Read `src/cache/store.ts`,
`src/cache/eviction.ts` and their tests first.

**Acceptance criteria (verbatim)**

```
Entries are evicted when the byte budget is exceeded, and no entry is served after it has been
invalidated.
```

**1. FINDINGS**

| # | Severity | Finding (verbatim) | Disposition |
|---|---|---|---|
| 1 | MAJOR | `src/cache/eviction.ts:64` — eviction compares `entry.bytes` against the budget *after* inserting, so a single entry larger than the whole budget is stored and never evicted; the cache then serves it forever. Fix: reject or immediately evict an entry that cannot fit. | FIX |
| 2 | MAJOR | `src/cache/store.ts:120` — `invalidate(key)` deletes from the map but not from the eviction queue, so a re-inserted key is evicted on the stale queue entry's turn, dropping a live value. Fix: make the queue entry the single owner of liveness. | FIX |

**2. SIBLINGS**

Finding 1 is "a bound checked after the mutation it is meant to bound". Finding 2 is "two
structures track one liveness and can disagree". Search the branch diff for both shapes — every
other capacity check, and every other place a key exists in more than one structure.

**3. STRUCTURE**

The eviction queue has now been changed in rounds 1 and 2, both times because it holds liveness that
the map also holds. Say whether the queue should stop being a second source of truth — for example,
by storing a reference to the map entry and treating a missing entry as already evicted — rather
than taking a third patch.
