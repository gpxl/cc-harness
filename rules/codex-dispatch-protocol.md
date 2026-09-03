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
- **Check it isn't already running** (`codex-jobs.sh --active`) before launching; never a second copy.
- **Verify placement immediately**: `codex.sh status --json --cwd <ws>` must list the job as
  `queued`/`running` with `workspaceRoot` == the intended directory and a live pid. Anything
  rooted elsewhere: `codex.sh cancel <id> --cwd <that root>`, then re-dispatch. Half of
  "Claude can't find the job" is "the job is running somewhere else".
| Dispatch wrapper | `scripts/codex-dispatch.sh` performs the duplicate check, background launch, placement verification, and prints the PID-bridge wait command. |

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

Cancel when any of: the log's mtime is >15 min old while `running`; the runaway signature (the
same command re-run ≥3 times, a verification sweep whose scope grows or restarts, a job waiting
on something already finished); the wall cap hit twice. Order:

1. `codex.sh cancel <id> --cwd <ws>` — interrupts the app-server turn, then kills the worker tree.
2. Then orphaned sandbox children: `codex-brokers.sh` gives the workspace's app-server pid;
   `pgrep -P <that pid>` lists its children; confirm each with `lsof -a -p <pid> -d cwd` and kill
   **only PIDs whose cwd is that job's workspace**, by explicit PID.
3. **Never `pkill -f <pattern>` / `pgrep -f`** — the pattern self-matches (it has killed our own shell).

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

## 6. Host-side build mailbox

Codex's workspace-write sandbox cannot run this repository's Swift build reliably: `swiftc` macro
plugin hosts use `sandbox-exec`, and that nested Seatbelt execution fails. A host operator can run
`scripts/codex-mailbox.sh start --workspace <workspace>` outside the sandbox; the runner accepts
only build requests written to `<workspace>/.codex-mailbox/` and writes the real compiler result
back there. It is for `swift build` and `scripts/test.sh`, not for arbitrary host commands.

The harness kills one foreground shell command at roughly **28 seconds**. A mailbox build can take
longer, so a Codex turn must request once and poll in **separate short commands**. Never use one
long `sleep`, a foreground `wait`, or a loop intended to outlast that command limit. Use this exact
shape (run the second block again as a new command until it prints the response):

```bash
# Request one allowlisted build. This is one short command.
workspace=/absolute/path/to/workspace
mailbox="$workspace/.codex-mailbox"
id="build-$(date +%s)-$$"
node -e 'process.stdout.write(JSON.stringify({ task: "build" }) + "\n")' \
  > "$mailbox/req-$id.json"
printf '%s\n' "$id" > "$mailbox/current-build-id"

# Poll in a NEW short command each time (the sleep is deliberately bounded).
workspace=/absolute/path/to/workspace
mailbox="$workspace/.codex-mailbox"
id=$(cat "$mailbox/current-build-id")
response="$mailbox/resp-$id.json"
if [ -f "$response" ]; then
  node -e 'const fs = require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")))' "$response"
else
  sleep 5
fi
```

The response is atomically renamed from `resp-<id>.json.tmp`, so a poller never reads a
half-written JSON document. Its `log` field names the complete output file and `tail` is a compact
copy for the turn. The security boundary is intentional and narrow: requests carry a **task name
only**; the host script rejects malformed or unallowlisted names before lookup and maps accepted
names through its fixed `build → swift build`, `test → scripts/test.sh` table. Request content is
never evaluated as shell code. `CODEX_MAILBOX_TASKS` exists only as a hermetic selftest hook.

## 7. Housekeeping

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
