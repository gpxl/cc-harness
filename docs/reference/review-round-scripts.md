# Bounded review scripts

`scripts/review-round.sh <base>` dispatches one read-only branch review. It records the accepted
reviewer's job, thread, round count, and reviewed scope. Ordinary review stops after three rounds; a
fourth or later round requires the user's exact words. Add `--dry-run` to inspect the next round
without dispatching or changing state.

| Option | Effect |
|---|---|
| `--bead <id>` | Take the acceptance criteria from that tracker item's `ACCEPTANCE CRITERIA` section |
| `REVIEW_ROUND_ACCEPTANCE=...` | Supply the acceptance criteria directly, for a branch with no tracker item |
| `--evidence-file <path>` | Carry the `VERIFY RESULT:` / `CODE QUALITY RESULT:` lines from that file into the prompt |
| `--scope-changed "<words>"` | Declare that the branch grew, archiving the prior rounds and restarting the budget |
| `--acceptance-reworded "<words>"` | Declare that only the wording of the acceptance text changed — same commits, same criteria; the round counter is kept |
| `--user-approved "<words>"` | The owner's words authorising a round beyond three |

State is local to the repository and independent of the project:

| Path | Contents |
|---|---|
| `$(git rev-parse --git-common-dir)/review-rounds/<branch-slug>` | Round counter |
| `<branch-slug>.job` | Launched job ID |
| `<branch-slug>.thread` | Reviewer `threadId` |
| `<branch-slug>.scope` | Scope stamp of the reviewed branch |
| `<branch-slug>.scope-<hash>/` | A superseded scope's counter, thread, job and findings |

The thread comes from the job's JSON record beside the dispatch log, so the job still counts when
its thread is acquired asynchronously. Starting with round two, prior findings come from adjacent
`<branch-slug>-r<N>-findings.md` files.

## What the script refuses, and why

Measured 2026-09-16 on one branch's six rounds: rounds 2 to 5 were dispatched with an empty
acceptance section, the literal text `No prior findings file was recorded`, and no gate record,
while the reviewed diff grew from 856 to 9,339 lines. Every one of those was a silent placeholder,
so the script could not tell "I looked and there is nothing" from "I was never given anything"
(`~/.claude/rules/verification-integrity.md` § Instruments must distinguish healthy from not
looking). Each is now a refusal with a named remedy.

| Refusal | Remedy |
|---|---|
| No acceptance criteria resolved | `bd update <id> --acceptance=...`, a `--bead` that has them, or `REVIEW_ROUND_ACCEPTANCE=...` |
| Round `N` dispatched while round `k < N` has no findings file | `--collect <job-id> --round <k>`, or write that file by hand with each finding's disposition |
| The acceptance text changed but no scope-changing commit was added | Decide which it was: `--acceptance-reworded "<why>"` keeps the counter (same code, same criteria, different words), `--scope-changed "<what>"` restarts the budget (the definition of done really moved). The script refuses until you say which, because a typo fix must not buy three more rounds |
| The reviewed scope changed since the recorded round | Restate what done means for the enlarged branch, then `--scope-changed "<what changed>"` — the script requires the flag and a non-empty reason, and cannot check that the criteria really were restated |

The **scope stamp** is a digest of the acceptance text plus the branch's commit subjects excluding
`fix`, `test`, `docs` and `chore`. Those four land *because of* a round; anything else makes the next
round a first look at different code, which the per-branch counter used to charge against the old
budget. It reads subjects only, so amending a commit in place moves no stamp; declare the change
yourself when a branch grows under an unchanged subject. A declared scope change archives the previous rounds rather than deleting them.

Absent gate evidence is **not** a refusal — a branch can legitimately be reviewed before its gate
record exists — but the prompt then says so plainly and tells the reviewer to treat verification
claims in the diff as unverified.

## The reviewer thread cannot be resumed on demand

`rules/branch-completion-review.md` asks rounds 2 and 3 to resume the round-1 reviewer. The plugin
cannot generally do that, and the script no longer pretends otherwise.

In openai-codex 1.0.6, `scripts/codex-companion.mjs`'s `executeTaskRun` resolves a resume target
**only** through `resolveLatestTrackedTaskThread(workspaceRoot)`, behind `--resume-last`.
`runAppServerTurn` does accept a `resumeThreadId`, but no CLI path passes a caller-supplied one. So
resume works when the reviewer is still the newest tracked thread in the workspace, and fails the
moment anything else runs — and in a Codex-first workflow the fix task between rounds is exactly
that something else. Measured 2026-09-16: 6 of 6 rounds on one branch ran fresh for this reason.

The script still records the thread, because `codex resume <id>` works by hand and the record is
worth having. What changed is that a fresh round now prints why it is fresh, and the **prior findings
file is the continuity mechanism** — which is why dispatching over a hole in that record is refused
rather than papered over. Re-check this section against the plugin after an upgrade; if a
sanctioned resume-by-id ever appears, prefer it.

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
