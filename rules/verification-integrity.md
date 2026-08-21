# Verification Integrity

A gate you report as green is a claim you make to the user; this rule is about making sure that claim could actually have been false. The failure mode is not "the check didn't run" — it's "the check ran, could never have failed, and got reported as evidence." A skipped check is visibly missing; a fake green is invisibly wrong.

## Never read an exit code through a pipe

A pipeline's exit status is the status of the **last** command, so each of these reports success no matter what the real command did:

```bash
pnpm verify 2>&1 | tail -40     # $? is tail's status. Always 0. Always.
pnpm test | grep -E "fail"      # $? is grep's status
npm run build | head -20        # $? is head's status
```

Same for any background/async runner whose command ends in a pipe — the harness's "completed (exit code 0)" then reports the pipe's status, not the work's. (This shipped 3 real lint errors past two "green" runs; see `~/projects/cc-harness/docs/reference/rule-histories.md`.)

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

Mind the shell: `PIPESTATUS` is a bash-ism — in zsh it is **unset**, so `${PIPESTATUS[0]}` expands to empty and reads as "not non-zero" in a conditional (another silent false green); zsh spells it `$pipestatus`, indexed from 1. The Bash tool inherits the login shell (zsh on macOS), so prefer `pipefail`. But `pipefail` cuts the other way — it reports the **rightmost** non-zero status, so a filter that legitimately exits non-zero (`grep` matching nothing, `head` exiting 141 on SIGPIPE) yields a false **red**. Hence redirect-to-a-file is primary and `pipefail` the fallback: the filter's status never touches the gate's. Never report a gate as passing on an exit code that came through a pipe — re-run it clean.

## A green must be falsifiable

Before reporting any check as evidence, ask: **if the thing I'm claiming were broken right now, would this check have failed?** If you can't answer yes, the check is decoration.

- **Mocked tests that ignore their arguments.** A stub whose `select`/`eq`/`limit` are `vi.fn(() => builder)` returns canned data regardless of the query. Assert the arguments — columns, filters, limits — not just the mapped output.
- **Prove the guard bites.** For a test that pins a load-bearing constraint (a `.limit()` bounding egress, an `!inner` scoping a join), mutate the source, watch that test fail, restore. Seconds of work, and it converts "the test passes" into "the test catches this".
- **Fixtures that coincide with the expected value.** If the fixture holds exactly N rows and the cap is also N, rendering N proves nothing. Say so, and point at what does prove it.

## When evidence contradicts you, believe the evidence

If a sub-agent, a linter, or CI reports a failure that contradicts your own "it passed", **assume they are right until you have re-checked without the flawed step.**

Corollary: a failure somewhere your change couldn't plausibly reach (a different app, an untouched package) is data, not noise. Don't wave it away as unrelated *or* assume it's yours — get the actual log and find the real cause.

## Instruments must distinguish "healthy" from "not looking"

Everything above concerns *gates*. The same disease infects *instruments* — monitors, health checks, dashboards, the counters a long-running job returns — and there it is worse, because you consult an instrument **precisely when you are not watching**.

> **If the thing I am measuring had stopped entirely, would this instrument look any different from healthy?**

If the answer is no, the instrument is reporting *unknown* dressed up as *good*. So: gate every "all clear" on positive evidence of activity (prefer `unknown` over `ok` when the subject is idle); anchor timers to the right epoch (after a restart, a timer on last-success measures the outage, not a stall); confirm the signal actually reaches the log you grep (a marker written to a child's own log is zero forever, and zero looks like good news — verify detectors against a real captured sample, never a hand-written fixture); make counter buckets reconcile, so `0` can't mean both "nothing to do" and "nothing was seen"; and give every instrument a negative control before trusting it.

## A regression claim needs a baseline you can point at

The rule above asks whether a green could have been red. This one asks the mirror question about
the past: **before claiming a change removes, regresses, or loses a capability, establish what was
there — mechanically.**

> **Am I comparing against the shipped product, or against my own recollection of this session?**

Recollection is not a baseline. Code you wrote earlier in the same effort is *not* product history,
and scaffolding is the easiest thing in the world to mistake for it: you built it, you saw it work,
it is the freshest version in your head. On 2026-08-21 an interim five-control row — written hours
earlier, never in a comp, never requested, live under a day — was removed as part of shipping the
real design. Its removal was then escalated to the design authority as a P2 regression, "the phone
lost these controls". The controls had in fact been desktop-only since a PR months prior. One
command would have said so:

```bash
git log origin/main --oneline -- <path>          # when did this actually appear?
git show "$(git merge-base HEAD origin/main)":<path> | grep -n <feature>
```

### How to apply

- **Any sentence of the form "this used to…" / "yesterday it…" / "we lost…" is a claim about a
  commit.** Name the commit, or don't make the claim.
- **Escalating costs more than checking.** A regression report consumes someone else's attention and
  frames the discussion around a loss. The baseline check is one command; get it wrong and every
  answer downstream is answering the wrong question.
- **Distinguish the three states** a capability can be in: shipped and removed (a real regression),
  never shipped (a feature request), and *scaffolding you removed yourself* (not an event). The
  third is the one that masquerades as the first.
- The blast-radius habit in `agent-enforcement.md` is the same instinct pointed forward — there you
  enumerate what a deletion breaks; here you enumerate what a change actually had.

## Relationship to other rules

- `pipeline-contract.md` — the gate runs once and is recorded; this rule is why that recorded exit code must be real.
- `testing-guidelines.md` — Q1–Q8 is test quality; this rule is whether the apparatus around those tests reports the truth.
- `agent-enforcement.md` — the commit agent's `CODE QUALITY RESULT: PASS` gate is only meaningful if the status was read correctly.
- `testing-guidelines.md` — the Session Close Protocol asks whether the work is done; a regression claim is a statement about what *was* done, and needs the same standard of proof.
