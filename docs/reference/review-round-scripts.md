# Bounded review scripts

`scripts/review-round.sh <base>` dispatches one read-only branch review. It records the accepted
reviewer job thread and its round count, limits ordinary review to three rounds, and requires the
user's explicit words for round four or later. Add `--bead <id>` to include `bd show` acceptance
criteria, and `--dry-run` to inspect the next round without dispatching or changing state.

Its state is repository-local but project-agnostic: `$(git rev-parse --git-common-dir)/review-rounds/
<branch-slug>` stores the counter and `<branch-slug>.thread` stores the reviewer `threadId`. Prior
findings are read from adjacent `<branch-slug>-r<N>-findings.md` files starting with round two.

`scripts/review-ack-check.sh '<ack note>'` validates the portable acknowledgement fields:
`rounds=`, `verdict=`, `open_blockers=`, `user_decision=`, and `classes=`. A project gate can call it
directly, for example `scripts/review-ack-check.sh "$branch_review_ack"`; a nonzero result makes its
gate fail. It rejects missing fields, more than three rounds (unless its max is explicitly raised),
and NO-GO or open blockers without a user decision.

StemLab's `scripts/merge-gate.sh` should delegate its branch-review acknowledgement predicate to
this script in a follow-up StemLab bead. That migration is intentionally not part of cc-harness.
