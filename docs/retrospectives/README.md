# Engineering retrospectives

A periodic, evidence-first account of how this development system actually behaved: what went
wrong, what it cost, what we changed, and whether the change worked. One entry per period, dated,
never edited after publication except to append a follow-through note.

These are **narrative over a period**. They are not the same as
[`../reference/rule-histories.md`](../reference/rule-histories.md), which is per-rule incident
forensics and answers "why does this rule say that". A retrospective answers "what happened to us,
and what did we do about it". Link between them rather than restating either.

## Index

| Date | Entry | Period | Headline | Shareable |
|---|---|---|---|---|
| 2026-09-05 | [Codex integration and unbounded review loops](2026-09-05-codex-integration-and-review-loops.md) | 29 Aug – 5 Sep 2026 | A PR reached 12 adversarial review rounds; review is now capped at 3 with mechanical enforcement | [artifact](https://claude.ai/code/artifact/90a4771d-cb2d-4d73-9e7f-63ec43b1dc5d) |

The markdown file in this directory is canonical. The artifact is a rendering of the same content
for people who will not open the repo; when the two disagree, the file wins. Record the artifact
URL in the index so the next author republishes to it rather than creating a second one.

## Cadence

| Trigger | When |
|---|---|
| Scheduled | Monthly, on the first working day. Even a quiet month gets an entry: "nothing notable, here are the counters" is a finding. |
| Incident | Any single failure that costs more than a working day, or any change to how work is reviewed, gated, or routed. |
| Follow-through | Every entry reports on the previous entry's open items before it introduces anything new. An entry that skips this is incomplete. |

The scheduled trigger is wired: `~/.claude/scheduled-tasks/monthly-engineering-retrospective/` fires on the first of each month at 09:00 and points back at this file. It is machine-local, so a fresh machine has the series but not the reminder — recreate the task there.

## How to produce one

1. **Gather the measured half first.** `bash scripts/retro-evidence.sh --since <date> --repo <owner/name> --acks <checkout>/.build/merge-gate/acks --out /tmp/dossier.md`. It emits merged PRs with open→merge hours, parsed `branch-review` acknowledgements, the loop and routing counters, this repo's rule and script churn, and a fixed list of what it cannot show. Never start from recollection: a sentence of the form "we used to…" or "that took hours" is a claim about a commit or a ledger row, so name it (`rules/verification-integrity.md` § A regression claim needs a baseline).
2. **Read the qualitative sources.** `docs/reference/rule-histories.md` for the reasoning behind each rule change in the window, the beads closed and opened, and targeted transcript searches for the moments the counters point at. Search transcripts, do not read them whole.
3. **Write the narrative.** Structure below. Delegate drafting to Codex with the dossier as input if the window is large; the orchestrator's job is the judgement, not the prose.
4. **Publish both.** Commit the markdown through the normal branch → commit agent → gate → merge path, and republish the artifact to the URL in the index.
5. **Turn open items into beads** before you finish, and record their ids in the entry. An open item with no bead is a wish.

## Structure

Sections, in this order. Adapt the names, keep the jobs.

| Section | Its job |
|---|---|
| Summary | The period in one paragraph plus the four or five numbers that carry it. A reader who stops here should know what happened and what changed. |
| The setup | Only the parts of our environment a competent outsider could not guess, and only where they explain a failure. Written fresh each time; do not link and assume. |
| Timeline | Dated, terse, one line per event that mattered. |
| What went wrong | Grouped by mechanism, not by date. Each block: what happened, why, what it cost (measured, or explicitly unmeasured), what the response was. |
| Why it happened | Root causes, each tied to a file or a policy that has since changed. |
| What we changed | One row per change with where it landed and its status. Include the changes that did not hold. |
| Results so far | Every sample from the period, against the targets. Mark the misses. |
| Still open | With bead ids. |
| Learnings | Transferable statements, not a restatement of the changes. |

## The honesty rules

These exist because a retrospective is the one document with a standing incentive to flatter its
author, who is usually also the system under review.

- **Report the failures of the fix, not only of the thing it fixed.** If the new rule was breached,
  say when and by which commit. If the enforcement script shipped with defects, name them.
- **Include other people's efforts and their results**, including work that regressed or was
  abandoned. An entry that only contains the author's successes is not a retrospective.
- **Separate measured from asserted.** A ledger note claiming a negative control ran is an
  assertion until replayed. Say which you are relying on.
- **Never let a target that was missed appear as met.** If a number is not comparable, print it and
  say why it is not comparable, rather than omitting it.
- **No causal claim without a mechanism.** "Rounds fell after the cap" is a coincidence until you
  can point at the round that was refused.
- **Name what the evidence cannot establish.** The dossier's "Not measured" section goes into the
  entry, edited for the period, not dropped.
