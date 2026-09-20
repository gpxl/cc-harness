# Codex Dispatch Protocol

**The wrapper is not the job.** `codex-companion.mjs task --background` spawns a *detached*
`task-worker` node process and returns at once; a foreground run (`--wait`, or the rescue
subagent's default) *is* that worker, so when the harness kills the Bash call (120 s default
timeout) the record goes `running → unknown` while the Codex turn keeps executing on the shared
`app-server` under the broker, still editing files with nobody tracking it. Neither "my shell
returned" nor "my shell is still running" is job state. Verified against plugin 1.0.6 source;
status vocabulary and the `unknown`/`orphaned` handling are in `codex-job-status-integrity.md`.

## 1. Where the truth lives

State is **per workspace**: `$CLAUDE_PLUGIN_DATA/state/<basename>-<sha256(realpath)[:16]>/`
(fallback `$TMPDIR/codex-companion/…`), workspace = git root of the job's cwd. Inside:
`jobs/<id>.json` (`status`, `phase`, `pid`, `sessionId`, `workspaceRoot`, `logFile`,
`threadId`), `jobs/<id>.log`, and `broker.json` (the long-lived broker's pid/socket).
**Job liveness = `kill -0 <pid>` on the record's pid + the log file's mtime. Nothing else.**

Two blind spots in the companion's own `status`, both measured:

| Blind spot | Consequence | Rule |
|---|---|---|
| Filters jobs by `CODEX_COMPANION_SESSION_ID`; the store is keyed by `--cwd` | Another session's job, or one dispatched into a worktree, shows an **empty table** while alive | Check status only with the `--cwd` that dispatched, from the dispatching session; an empty table is not "done". Cross-session view: `~/.claude/scripts/codex-jobs.sh [--cwd <ws>] [--all-workspaces --active]` |
| Reconciles only `running` against the pid | A `queued` job whose worker died stays `queued` forever | `queued` older than ~2 min with a dead pid is orphaned |

## 2. Dispatch

- Pass `--cwd <intended workspace>` and `--json`; keep `jobId` and `logFile`. Cross-repo without
  `--cwd` is a sandbox refusal, not a reason to work inline.
- `--background` for anything that might outlive the Bash timeout. Foreground only for a small,
  bounded run whose value *is* its stdout (reviews). `--wait` belongs to the `/codex:rescue`
  command, not to `codex-companion.mjs task` — passing it there is a usage error and no job is
  ever recorded (stderr says so; capture it).
- **No extra `setsid` wrapper.** `--background` workers and brokers are spawned `detached: true`
  (own session, ppid 1) and survive a harness kill of the Bash call — measured 2026-09-02: the
  timeout SIGKILLs the call's process group; a plain child died, the detached one lived. The only
  path a harness kill reaches is a *foreground* task, and wrapping that in `setsid` would be worse
  (a detached worker whose completion nobody records). Long work → `--background`; the PID + log
  rule is what makes that safe.
- **Check it isn't already running** before launching; never a second copy. Use `scripts/codex-dispatch.sh`,
  or the **unfiltered** `codex-jobs.sh --json`: `--active` is the human-facing view and drops orphaned
  queued/running records, which are exactly the ones a second worker would double-apply partial work
  over (`codex-job-status-integrity.md` §4). It says so on stderr; the guard must not need to read that.
- **Verify placement immediately**: `codex.sh status --json --cwd <ws>` must list the job as
  `queued`/`running` with `workspaceRoot` == the intended directory and a live pid. Anything
  rooted elsewhere: `codex.sh cancel <id> --cwd <that root>`, then re-dispatch. Half of
  "Claude can't find the job" is "the job is running somewhere else".
| Dispatch wrapper | `scripts/codex-dispatch.sh` performs the duplicate check, background launch, placement verification, and prints the PID-bridge wait command. |

## 2a. Resume targets only the NEWEST thread

`--resume` resolves its target through `resolveLatestTrackedTaskThread`; nothing on the CLI path
passes a caller-supplied thread id. Re-verified against plugin **1.0.6**: `executeTaskRun` sets
`resumeThreadId` only under `request.resumeLast`, and while `runAppServerTurn` accepts a
`resumeThreadId` argument, no command line reaches it. So a fix task dispatched between two review
rounds takes the slot, and `--resume` on the next round resumes the FIX thread, not the reviewer's.

**"Newest" is also scoped, in two ways that decide what `--resume` can even see** (1.0.6,
`codex-companion.mjs`): `resolveLatestTrackedTaskThread` first passes the workspace's jobs through
`filterJobsForCurrentClaudeSession`, which keeps only records whose `sessionId` matches the current
Claude session — with **no** session id in the environment it falls back to *all* jobs, so the same
command resumes different threads depending on how it was launched. It then takes
`findLatestResumableTaskJob`: the newest record that is `jobClass === "task"`, carries a `threadId`,
and is **not** `queued`/`running`. An in-flight same-session task does not merely fail to match —
it makes `--resume` **fail**: `resolveLatestTrackedTaskThread` throws `Task <id> is still running.
Use /codex:status before continuing it.`, and `executeTaskRun` does not catch it, so the task is
lost rather than started fresh. A `--resume` that matches nothing fails the same way (`No previous
Codex task thread was found for this repository.`). A job from another session is invisible to the
search, and a non-task record is skipped. Record the thread id you intend to continue and compare it before resuming; do not infer
it from "the last thing I dispatched".

Consequences, both already wired: `review-round.sh` resumes only when the newest tracked thread is
the one it recorded, and otherwise dispatches a fresh reviewer and says so; the prior findings file,
not the thread, is what carries continuity (`branch-completion-review.md`). Do not build anything
that assumes a thread id can be named at dispatch until the plugin grows that flag.

## 3. Wait: a PID bridge, never polling

```bash
~/.claude/scripts/codex-wait.sh <job-id> --cwd <ws>     # Bash run_in_background: true
```

It re-reads the record every 60 s and exits on a terminal status (0 completed / 1 failed or
cancelled), on an orphan (2: pid gone while `running`/`queued`) or at the wall cap (3, default
180 min); the harness re-invokes you **exactly once** when it exits. Never a foreground sleep,
never repeated status calls in the transcript, never `status --wait` in the foreground (it dies
with the Bash timeout). On wake: 0 → check the deliverables on disk (§5); 1 → read the log;
2 → the integrity protocol in `codex-job-status-integrity.md`; 3 → §4 decides cancel or re-arm.

## 4. Cancellation criteria (written down so nobody hesitates)

Cancel a **live** job when any of: the log's mtime is >15 min old while `running`; the runaway
signature (the same command re-run ≥3 times, a verification sweep whose scope grows or restarts,
a job waiting on something already finished); the wall cap hit twice. Order:

1. `codex.sh cancel <id> --cwd <ws>` — interrupts the app-server turn, then kills the worker tree.
2. Then orphaned sandbox children: `codex-brokers.sh` gives the workspace's app-server pid;
   `pgrep -P <that pid>` lists its children; confirm each with `lsof -a -p <pid> -d cwd` and kill
   **only PIDs whose cwd is that job's workspace**, by explicit PID.
3. **Never `pkill -f <pattern>` / `pgrep -f`** — the pattern self-matches (it has killed our own shell).

### 4a. Cross-round runaway (no live job)

The signature above is about one job's liveness. A separate signature applies across **separate,
individually *completed* job records** for the same bead/PR: three consecutive dispatches above
the Build / implementation row — pinned to `gpt-6-astra` or higher — with no step back down to
`gpt-5.6-terra` and no new diagnostic input between rounds. The anchor is the tier, not the
trend: three rounds correctly held at `gpt-5.6-terra` is the compliant case, not a signature.
"New diagnostic input" means new evidence bearing on the root cause — a reproduction, a bisect,
an instrumented run — not the previous round's own findings carried forward as context, which a
fix round always does (`templates/review-fix-round.md`) and would otherwise make this signature
never fire. This is the cross-round form of the Model Routing "escalation is scoped to the round
that needed it" rule (`~/.claude/CLAUDE.md` § Equivalence table) — that rule asks the orchestrator
to catch the pattern before it starts; this entry is what to do once it didn't. The two conditions
are related but not identical, deliberately: the Mismatch protocol trigger there fires on framing
alone (three rounds still read as a fix), while cancelling a round here additionally wants
evidence the loop itself has stalled. Genuinely converging architecture work — new diagnostic
input each round — does not trip this signature even while pinned to `gpt-6-astra`, but it still
owes the Mismatch protocol's framing check at every round boundary.

There is no live worker to kill, so "cancel" means **stop dispatching further rounds and
re-scope** — drop back to the tier the work type actually calls for, or spend one round
explicitly on root-cause diagnosis before resuming fixes, rather than dispatching round N+1 at
the tier rounds 1..N already failed at. Candidate for machine-checking, with a caveat: `scripts/codex-dispatch.sh`
already runs a duplicate-job check before launch, and `scripts/codex-jobs.sh --json` already
enumerates job records with `request.model` — but that field is `null`, not absent, whenever
`--model` was left unset. Measured: 138 of 258 `task`-class records in this machine's
`codex-openai-codex` job store (53%; 219 of 358, 61%, across all this machine's job stores) carry
`request.model: null`, because leaving `--model` unset (the documented default path, `~/.claude/CLAUDE.md`
§ Equivalence table) inherits whatever `~/.codex/config.toml` sets — `gpt-6-astra` at the time of
this measurement, flipped to `gpt-5.6-terra` on 2026-09-20 (`cch-w50`, after the same job-store
data showed 69% of dispatches resolving to the architecture tier by unset-default alone, most of
it routine build/fix work) — so a naive `has(request, "model")` check misreads the single most
common way to dispatch as "no tier recorded", and a naive equality check misreads `null` as not a
tier string at all. A future checker must resolve `request.model: null` against **whatever the
config default was on that job's `createdAt`**, not the config's current value, or a historical
count will silently misattribute jobs dispatched under the old `gpt-6-astra` default to whatever
tier is live when the checker runs.
Not built here, but the next person hitting this should not have to re-derive either the idea or
the pitfall.

## 5. Prompt-side completion contracts

- Every prompt names its **exact deliverable paths**; "done" *is* those files existing. Claude
  checks the filesystem, not the summary. Ask for a findings *file*, not a narrative.
- **No git in Codex.** A worktree's `.git` lives outside the sandbox root and index locks are
  flaky: if Codex needs something recorded it STOPs and lists paths + intended subject; the
  supervisor commits via the commit agent.
- **Fetch-bearing jobs open with an egress proof** (`curl -sI https://api.github.com | head -1`)
  so a sandbox without DNS fails in seconds instead of producing second-hand claims for an hour.
- The verify gate stays with the orchestrator (`verification-integrity.md`); Codex's "tests pass"
  is a claim until the gate is run here.

## 6. Housekeeping

- Brokers and app-servers are long-lived. Sandbox settings in `~/.codex/config.toml` are read per
  thread (measured 2026-09-01: new `writable_roots` + `network_access` took effect on the next task
  with no restart). If a config edit does *not* take, or state looks ghostly: `codex-brokers.sh
  --restart-idle` (never kills a broker with a queued/running job); tell peer sessions sharing the
  workspace first (`peer-session-coordination.md`).
- `codex-brokers.sh --reap-stale` for brokers whose cwd is gone or under `$TMPDIR` (the plugin's
  own test suite leaves ~30 behind).
- Sandbox extension is `[sandbox_workspace_write] writable_roots = [...]` + `network_access`
  (key verified in codex-cli 0.147.0; `writeable_roots` is silently ignored).

This file is the AGENT-RULES file: it is always loaded, and any subagent or workflow that
dispatches Codex gets it by reference (`~/.claude/rules/codex-dispatch-protocol.md`) rather than
a paraphrase.
