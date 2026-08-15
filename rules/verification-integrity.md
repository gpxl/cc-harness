# Verification Integrity

A gate you report as green is a claim you make to the user; this rule is about making sure that claim could actually have been false. The failure mode is not "the check didn't run" — it's "the check ran, could never have failed, and got reported as evidence." A skipped check is visibly missing; a fake green is invisibly wrong.

## Never read an exit code through a pipe

A pipeline's exit status is the status of the **last** command, so each of these reports success no matter what the real command did:

```bash
pnpm verify 2>&1 | tail -40     # $? is tail's status. Always 0. Always.
pnpm test | grep -E "fail"      # $? is grep's status
npm run build | head -20        # $? is head's status
```

Same for any background/async runner whose command ends in a pipe — the harness's "completed (exit code 0)" then reports the pipe's status, not the work's.

<!-- HISTORY (hidden from context, kept for maintainers):

### Why this rule exists

On 2026-07-16 (SetDigger), `pnpm verify 2>&1 | tail -40` was run twice on a PR and reported exit 0 both times. Lint was in fact failing with 3 TypeScript `ts(2352)` strict-mode errors. The errors surfaced only because a separate `code-quality` agent independently re-ran lint and returned FAIL, contradicting the orchestrator's own "verify passed" claim. Two green runs, zero signal, and the green had already been written into a PR description as evidence.

The pipe was added for a completely reasonable reason — `pnpm verify` output is thousands of lines and needs trimming. That's the trap: the mistake looks like good hygiene.

-->

### How to apply

Redirect to a file, capture the status on its own, then filter the file:

```bash
pnpm verify > /tmp/verify.log 2>&1; echo "REAL_EXIT=$?"
grep -E "errors|Test Files|ELIFECYCLE|Failed" /tmp/verify.log | head -20
```

When a pipe is genuinely unavoidable:

| Mechanism | Effect | Shell |
|-----------|--------|-------|
| `set -o pipefail` | Pipeline returns the rightmost non-zero status | bash **and** zsh |
| `${PIPESTATUS[0]}` | First command's status (0-indexed) | **bash only** |
| `${pipestatus[1]}` | First command's status (1-indexed) | **zsh only** |

Mind the shell: `PIPESTATUS` is a bash-ism — in zsh it is **unset**, so `${PIPESTATUS[0]}` expands to empty and reads as "not non-zero" in a conditional (another silent false green); zsh spells it `$pipestatus`, indexed from 1. The Bash tool inherits the login shell (zsh on macOS), so prefer `pipefail`:

```bash
set -o pipefail
(exit 3) | tail -1        # with pipefail set: $? == 3   (without it: 0)
```

`pipefail` cuts the other way — it reports the **rightmost** non-zero status, so a filter that legitimately exits non-zero (`grep` matching nothing on a passing run, `head` exiting 141 on SIGPIPE) yields a false **red**. Hence redirect-to-a-file is primary and `pipefail` the fallback: the filter's status never touches the gate's. Never report a gate as passing on an exit code that came through a pipe — re-run it clean.

## A green must be falsifiable

Before reporting any check as evidence, ask: **if the thing I'm claiming were broken right now, would this check have failed?** If you can't answer yes, the check is decoration.

- **Mocked tests that ignore their arguments.** A stub whose `select`/`eq`/`limit` are `vi.fn(() => builder)` returns canned data regardless of the query. Assert the arguments — columns, filters, limits — not just the mapped output.
- **Prove the guard bites.** For a test that pins a load-bearing constraint (a `.limit()` bounding egress, an `!inner` scoping a join), mutate the source, watch that test fail, restore. Seconds of work, and it converts "the test passes" into "the test catches this".
- **Fixtures that coincide with the expected value.** If the fixture holds exactly N rows and the cap is also N, rendering N proves nothing. Say so, and point at what does prove it.

## When evidence contradicts you, believe the evidence

If a sub-agent, a linter, or CI reports a failure that contradicts your own "it passed", **assume they are right until you have re-checked without the flawed step.**

Corollary: a failure somewhere your change couldn't plausibly reach (a different app, an untouched package) is data, not noise. Don't wave it away as unrelated *or* assume it's yours — get the actual log and find the real cause.

<!-- HISTORY (hidden from context, kept for maintainers):

In the 2026-07-16 pipe incident above the agent was right and the orchestrator was wrong; treating the agent's FAIL as noise would have shipped the errors.

Two real examples of the corollary, from the same session, both initially looking like "my change broke it":

| Symptom | Actual cause | How it was settled |
|---------|--------------|--------------------|
| `apps/admin build` red in a fresh worktree | gitignored `.env.local` absent — env gap, not code | Copied env in → exit 0 |
| Cloudflare Pages check red on an untouched app | CF-side internal error at asset-publish; build itself compiled | Fetched build log; retry passed the identical commit |

Both were diagnosed by reading the real log and capturing a real exit code — the same discipline as the rest of this rule.

-->

## Instruments must distinguish "healthy" from "not looking"

Everything above concerns *gates*. The same disease infects *instruments* — monitors, health checks, dashboards, the counters a long-running job returns — and there it is worse, because you consult an instrument **precisely when you are not watching**.

> **If the thing I am measuring had stopped entirely, would this instrument look any different from healthy?**

If the answer is no, the instrument is reporting *unknown* dressed up as *good*.

<!-- HISTORY (hidden from context, kept for maintainers):

### Why this earned its own section

On 2026-08-10 (SetDigger/mixid), across a single session, four instruments were
built or extended and every one of them had this defect:

| Instrument | Reported | Could not distinguish |
|---|---|---|
| Adoption RPC counters | `isrc_set: 36` | "already correct" vs "no evidence present" — the three-way branch counted two outcomes and left the third silent, so `seen − unlinked − skipped` never reconciled against `set + conflicts` |
| Monitor stall check | `STALLED` after a restart | a stalled child vs a child two minutes old — it timed the *outage*, not the child |
| Monitor gate detector | `0 gates` | no gates vs grepping the wrong file (the marker was written to per-item logs, not the aggregate log; 7 gated items sat on disk unseen) |
| Monitor gate all-clear | `GATE CLEARED` | not gated vs **not fetching** — it fired during a backoff, when nothing could possibly have been gated |

Each was written by someone who had just been careful about verification
integrity in the production code. The observability *around* the work got the
sloppiness the work itself was spared — which is backwards.

The curly-apostrophe detail in "How to apply" below is from the same session: a
detector had to match `you’re`, not `you're`, because that is what the upstream
service actually emits.

-->

### How to apply

- **Gate every "all clear" on evidence of activity.** "No errors in 5 minutes" means nothing if nothing ran; require a positive signal (a live worker, a completed unit of work) and prefer `unknown` over `ok` when the subject is idle.
- **Measure from the right epoch.** "Nothing completed in 25 minutes" is a stall only if the worker has *been up* that long; after a restart, a timer anchored to the last success measures the outage.
- **Confirm the signal reaches the place you are reading.** Grepping an aggregate log for a marker a child writes to its own log finds zero forever, and zero looks like good news. Verify detectors against a **real captured sample**, never a hand-written fixture — real output contains things you would not think to type (a *curly* apostrophe, say).
- **Make counter buckets reconcile.** Three outcomes in a loop means three counters; when `total` can't be recomputed from the parts, `0` is ambiguous between "nothing to do" and "nothing was seen".
- **Give every instrument a negative control.** Arrange the bad condition and confirm it reports before trusting it — the same mutation discipline this rule asks of gates.

## Relationship to other rules

- `testing-guidelines.md` — Q1–Q8 is test quality; this rule is whether the apparatus around those tests reports the truth.
- `agent-enforcement.md` — the commit agent's `CODE QUALITY RESULT: PASS` gate is only meaningful if the status was read correctly.
- `agent-purpose-statements.md` / `agent-isolation.md` — a delegated re-run is a genuine second opinion; a preflight that cannot see a concurrent session reports health for the same reason a quiet monitor does.
