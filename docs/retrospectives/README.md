# Engineering retrospectives

These retrospectives record how the development system behaved: what failed, what it cost, what
changed, and whether the change worked. Each period gets one dated entry. After publication, an
entry changes only to add a follow-through note.

Retrospectives tell the story of a period: what happened and what we did about it.
[`../reference/rule-histories.md`](../reference/rule-histories.md) instead explains why each rule
says what it says. Link the two rather than repeating either one.

## Index

| Date | Entry | Period | Headline | Shareable |
|---|---|---|---|---|
| 2026-09-05 | [Codex integration and unbounded review loops](2026-09-05-codex-integration-and-review-loops.md) | 29 Aug – 5 Sep 2026 | A PR reached 12 adversarial review rounds; review is now capped at 3 with mechanical enforcement | — |

The markdown file in this directory is canonical. A shareable rendering may be published for
readers outside the repository, but the file wins if they differ. Record the rendering's URL in
the index so later authors update it instead of creating a duplicate. Republish after every edit:
a stale rendering of a scrubbed entry is a leak the repository cannot detect
(`../../rules/public-surface-hygiene.md`).

## Cadence

| Trigger | When |
|---|---|
| Scheduled | Monthly, on the first working day. Quiet months still get an entry; "nothing notable, here are the counters" is a finding. |
| Incident | Any single failure that costs more than a working day, or any change to how work is reviewed, gated, or routed. |
| Follow-through | Every entry reports on the previous entry's open items before introducing anything new. Without that section, the entry is incomplete. |

The scheduled trigger at `~/.claude/scheduled-tasks/monthly-engineering-retrospective/` runs on the
first of each month at 09:00 and points to this file. It is machine-local. A new machine has the
series but not the reminder, so recreate the task there.

## How to produce one

1. Gather evidence first with `bash scripts/retro-evidence.sh --since <date> --repo <owner/name> --acks <checkout>/.build/merge-gate/acks --out /tmp/dossier.md`. It lists merged PRs with open→merge hours, parsed `branch-review` acknowledgements, loop and routing counters, this repository's rule and script churn, and a fixed list of what it cannot show. Do not begin from memory. "We used to…" and "that took hours" are claims about a commit or ledger row; identify the evidence (`rules/verification-integrity.md` § A regression claim needs a baseline).
2. Read the qualitative sources: `docs/reference/rule-histories.md` for the reasoning behind rule changes in the period, beads opened and closed, and targeted transcript searches where the counters point. Search transcripts; do not read them whole.
3. Write the narrative using the structure below. For a large period, delegate the draft to Codex with the dossier as input; the orchestrator remains responsible for judgment.
4. Publish both versions. Commit markdown through the normal branch → commit agent → gate → merge path, then republish the artifact at the URL in the index.
5. Turn every open item into a bead and record its ID so it does not disappear after publication.

## Structure

Use these sections in order. You may rename them, but preserve their purpose.

| Section | Its job |
|---|---|
| Summary | One paragraph plus the four or five numbers that carry the period. A reader who stops here should know what happened and what changed. |
| The setup | Only the parts of our environment a competent outsider could not guess, and only where they explain a failure. Written fresh each time; do not link and assume. |
| Timeline | Dated, terse, one line per event that mattered. |
| What went wrong | Grouped by mechanism, not date. Each block covers what happened, why, the measured or explicitly unmeasured cost, and the response. |
| Why it happened | Root causes, each tied to a file or a policy that has since changed. |
| What we changed | One row per change with where it landed and its status. Include the changes that did not hold. |
| Results so far | Every sample from the period, against the targets. Mark the misses. |
| Still open | Open work, with bead IDs. |
| Learnings | Transferable statements, not a restatement of the changes. |

## The honesty rules

The author is usually part of the system under review, which makes candor a requirement:

- Report failures of the fix as well as failures of the original system. If a new rule was broken,
  name the commit and date. If an enforcement script shipped with defects, name them.
- Include other people's work and its results, including regressions and abandoned efforts. A
  record containing only the author's successes is not a retrospective.
- Separate measurements from assertions. A ledger note saying a negative control ran remains an
  assertion until replayed; state which kind of evidence you use.
- Present missed targets plainly. If figures are not comparable, show them and explain why.
- Tie causal claims to a mechanism. "Rounds fell after the cap" is only a coincidence
  until you can identify the round the cap refused.
- Write for publication from the first draft. Keep real project, client, and ticket names out, even
  temporarily. Apply the purpose-based pseudonym from the private mapping while writing
  (`../../rules/public-surface-hygiene.md`). Otherwise removal requires rewriting history.
- State what the evidence cannot establish. Adapt the dossier's "Not measured" section to the
  period; do not drop it.
