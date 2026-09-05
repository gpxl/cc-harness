# Bounded review scripts

`scripts/review-round.sh <base>` dispatches one read-only branch review. It records the accepted
reviewer job thread and its round count, limits ordinary review to three rounds, and requires the
user's explicit words for round four or later. Add `--bead <id>` to include `bd show` acceptance
criteria, and `--dry-run` to inspect the next round without dispatching or changing state.

Its state is repository-local but project-agnostic: `$(git rev-parse --git-common-dir)/review-rounds/
<branch-slug>` stores the counter, `<branch-slug>.job` stores the launched job ID, and
`<branch-slug>.thread` stores the reviewer `threadId`. The thread comes from the job's JSON record
next to the dispatch log, so a job is counted even if its thread is acquired asynchronously. Prior
findings are read from adjacent `<branch-slug>-r<N>-findings.md` files starting with round two.

`--collect <job-id> [--round <k>]` extracts final BLOCKER/MAJOR/MINOR/NIT/VERDICT lines from a job log
into that round's findings file, adds a `Dispositions:` stub, and is idempotent.
`--adopt <round> <job-id>` recovers an uncounted launch by recording its nondecreasing round, job,
and reviewer thread from the job record.

`scripts/review-ack-check.sh '<ack note>'` validates the portable acknowledgement fields:
`rounds=`, `verdict=`, `open_blockers=`, `user_decision=`, and `classes=`. A project gate can call it
directly, for example `scripts/review-ack-check.sh "$branch_review_ack"`; a nonzero result makes its
gate fail. It rejects missing fields, more than three rounds (unless its max is explicitly raised),
and NO-GO or open blockers without a user decision.

cc-harness acceptance covers only these scripts, selftests, and docs; StemLab's separate
`scripts/merge-gate.sh` migration is tracked by StemLab bead `sl-65pe` and is out of scope here.
