# Verification Integrity

A gate you report as green is a claim you are making to the user. This rule is about making sure that claim can actually be false.

The failure mode is not "the check didn't run" — it's "the check ran, could never have failed, and got reported as evidence." That is worse than skipping it: skipping is visibly missing, a fake green is invisibly wrong.

## Never read an exit code through a pipe

A pipeline's exit status is the status of the **last** command. So:

```bash
pnpm verify 2>&1 | tail -40     # $? is tail's status. Always 0. Always.
pnpm test | grep -E "fail"      # $? is grep's status
npm run build | head -20        # $? is head's status
```

Every one of those reports success no matter what the real command did. The same applies to any background/async runner whose command ends in a pipe — the harness's "completed (exit code 0)" notification then reports the pipe's status, not the work's.

### Why this rule exists

On 2026-07-16 (SetDigger), `pnpm verify 2>&1 | tail -40` was run twice on a PR and reported exit 0 both times. Lint was in fact failing with 3 TypeScript `ts(2352)` strict-mode errors. The errors surfaced only because a separate `code-quality` agent independently re-ran lint and returned FAIL, contradicting the orchestrator's own "verify passed" claim. Two green runs, zero signal, and the green had already been written into a PR description as evidence.

The pipe was added for a completely reasonable reason — `pnpm verify` output is thousands of lines and needs trimming. That's the trap: the mistake looks like good hygiene.

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

Mind the shell. `PIPESTATUS` is a bash-ism: in zsh it is **unset**, so `${PIPESTATUS[0]}` silently expands to an empty string — which in a conditional reads as "not non-zero", i.e. another false green. (zsh's `[ "" -ne 0 ]` fails *silently*; bash at least complains.) zsh spells it `$pipestatus` and indexes from 1. Claude Code's Bash tool inherits the user's login shell — zsh on macOS by default — so prefer `pipefail`, which behaves identically in both:

```bash
set -o pipefail
(exit 3) | tail -1        # with pipefail set: $? == 3   (without it: 0)
```

`pipefail` cuts the other way too: it reports the **rightmost** non-zero status, so a filter that legitimately "fails" now poisons the pipeline. `pnpm test | grep -E "fail"` under `pipefail` exits 1 when the tests *passed* and grep simply matched nothing; `| head -2` can exit 141 on SIGPIPE. That's a false **red** — safer than a false green, but still noise. This is why redirect-to-a-file is the primary recommendation and `pipefail` is the fallback: the filter's status never touches the gate's.

Do not report a gate as passing on an exit code that came through a pipe. Re-run it clean first.

## A green must be falsifiable

Before reporting any check as evidence, ask: **if the thing I'm claiming were broken right now, would this check have failed?** If you can't answer yes, the check is decoration.

This generalizes past exit codes:

- **Mocked tests that ignore their arguments.** A Supabase/HTTP stub whose `select`/`eq`/`limit` are `vi.fn(() => builder)` returns canned data regardless of the query. The test passes whether or not the query is correct. Assert the arguments — the columns, the filters, the limits — not just the mapped output.
- **Prove the guard bites.** When a test exists to pin a load-bearing constraint (a `.limit()` that bounds egress, an `!inner` that scopes a join), mutate the source, watch that specific test fail, then restore. That takes seconds and converts "the test passes" into "the test catches this."
- **Fixtures that coincide with the expected value.** If the fixture happens to contain exactly N rows and the cap is also N, rendering N proves nothing. Say so, and point at whatever does prove it.

## When evidence contradicts you, believe the evidence

If a sub-agent, a linter, or CI reports a failure that contradicts your own "it passed" — **assume they are right until you have re-checked without the flawed step.** In the incident above the agent was right and the orchestrator was wrong; treating the agent's FAIL as noise would have shipped the errors.

Corollary: when a check fails somewhere your change couldn't plausibly reach (a different app, an untouched package), that mismatch is data. Do not wave it away as unrelated *or* assume it's yours — get the actual log and find the real cause. Two real examples from the same session, both initially looking like "my change broke it":

| Symptom | Actual cause | How it was settled |
|---------|--------------|--------------------|
| `apps/admin build` red in a fresh worktree | gitignored `.env.local` absent — env gap, not code | Copied env in → exit 0 |
| Cloudflare Pages check red on an untouched app | CF-side internal error at asset-publish; build itself compiled | Fetched build log; retry passed the identical commit |

Both were diagnosed by reading the real log and capturing a real exit code — the same discipline as the rest of this rule.

## Instruments must distinguish "healthy" from "not looking"

Everything above is about *gates* — checks that decide whether work proceeds. The
same disease infects *instruments*: monitors, health checks, dashboards, and the
counters a long-running job returns. A gate that cannot fail wastes a green. An
instrument that cannot fail is worse, because you consult it **precisely when
you are not watching**, and it will tell you things are fine while nothing is
happening at all.

The test is one question, and it is not the same question as for a gate:

> **If the thing I am measuring had stopped entirely, would this instrument look
> any different from healthy?**

If the answer is no, the instrument reports *unknown* and is dressed up as *good*.

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

### How to apply

- **Gate every "all clear" on evidence of activity.** "No errors in the last 5
  minutes" means nothing if nothing ran. Require the positive signal —
  a live worker, a completed unit of work — before concluding health. Prefer
  reporting `unknown` over `ok` when the subject is idle.
- **Measure from the right epoch.** "Nothing completed in 25 minutes" is a stall
  only if the worker has *been up* for 25 minutes. After any restart, an elapsed
  timer anchored to the last success is measuring the outage.
- **Confirm the signal reaches the place you are reading.** Grepping an
  aggregate log for a marker that a child writes to its own log finds zero,
  forever, and zero looks like good news. Verify the detector fires against a
  **real captured sample**, not a hand-written fixture — real output contains
  things you will not think to type. (One detector here had to match a *curly*
  apostrophe, because the upstream service emits `you’re`, not `you're`. A
  hand-written pattern would have missed every occurrence silently.)
- **Make counter buckets reconcile.** If a loop has three outcomes, count three.
  When `total` cannot be recomputed from the parts, a `0` is ambiguous between
  "nothing to do" and "nothing was seen" — and someone will read it as the
  former and close the task.
- **Give every instrument a negative control.** Before trusting it, arrange for
  the bad condition and confirm it reports. This is the same mutation discipline
  the rest of this rule asks of gates; it takes seconds and is the only thing
  that converts "the monitor is quiet" into "the monitor would have spoken".

## Relationship to other rules

- **`testing-guidelines.md`** — Q1–Q8 covers test *quality* (empty bodies, no assertions, tautologies). This rule covers whether the *verification apparatus* around those tests reports the truth. A Q3 mock-argument warning and a piped exit code are the same disease: a check that cannot fail.
- **`agent-enforcement.md`** — the commit agent gates on `CODE QUALITY RESULT: PASS`. That gate is only meaningful if the underlying command's status was read correctly.
- **`agent-purpose-statements.md`** — when you delegate verification, the agent's independent re-run is a genuine second opinion. Don't instruct it to trust your gate results; let it contradict you.
- **`agent-isolation.md`** — its collision preflight is the same idea applied to *people*: before starting, check whether the work is already underway. An instrument that cannot see a concurrent session reports "nobody is on this" for the same reason a quiet monitor reports health.
