# Bounded review scripts

`scripts/review-round.sh <base>` dispatches one read-only branch review. It records the accepted
reviewer's job, thread, and round count. Ordinary review stops after three rounds; a fourth or
later round requires the user's exact words. Add `--bead <id>` to include `bd show` acceptance
criteria. Add `--dry-run` to inspect the next round without dispatching or changing state.

State is local to the repository and independent of the project:

| Path | Contents |
|---|---|
| `$(git rev-parse --git-common-dir)/review-rounds/<branch-slug>` | Round counter |
| `<branch-slug>.job` | Launched job ID |
| `<branch-slug>.thread` | Reviewer `threadId` |

The thread comes from the job's JSON record beside the dispatch log, so the job still counts when
its thread is acquired asynchronously. Starting with round two, prior findings come from adjacent
`<branch-slug>-r<N>-findings.md` files.

`--collect <job-id> [--round <k>]` extracts final BLOCKER, MAJOR, MINOR, NIT, and VERDICT lines
from a job log into that round's findings file. It adds a `Dispositions:` stub and is idempotent.
`--adopt <round> <job-id>` recovers an uncounted launch by recording its nondecreasing round, job,
and reviewer thread from the job record.

`scripts/review-ack-check.sh '<ack note>'` validates these portable acknowledgement fields:
`rounds=`, `verdict=`, `open_blockers=`, `user_decision=`, and `classes=`. A project gate can call it
directly, for example `scripts/review-ack-check.sh "$branch_review_ack"`; a nonzero result makes its
gate fail. It rejects missing fields, more than three rounds (unless its max is explicitly raised),
and NO-GO or open blockers without a user decision.

cc-harness acceptance covers only these scripts, selftests, and docs. AudioApp's separate
`scripts/merge-gate.sh` migration is tracked by AudioApp bead `aa-65pe`; it is out of scope here.
