# Codex Background-Job Status Integrity

A backgrounded `codex-companion.mjs task` (via `/codex:rescue --background`, or any direct
`task` invocation) reports one of seven states, not a binary done/not-done. Misreading `unknown`
as "still running" or as "probably fine" is the Codex-delegation version of the fake-green
`verification-integrity.md` warns about: a status that *looks* like an in-progress job but
is actually silent evidence loss.

## The seven outcomes

| Status | Phase | Meaning |
|---|---|---|
| `queued` | `queued` | The job record was created but the worker hasn't started running yet. Not yet cancelable-with-a-result, not yet a deliverable — same non-terminal treatment as `running` throughout the plugin (cancel hint shown, no result/review hint yet). |
| `running` | — | The worker PID is alive and the Codex transport has not reported a disconnect. |
| `completed` | `done` | Terminal — normal success. |
| `failed` | `failed` | Terminal — normal failure. |
| `cancelled` | — | Terminal — the job was cancelled. |
| `unknown` | `orphaned` | The worker process died or the Codex runtime connection was lost mid-job. **Not** success, **not** completion, **not** evidence the job is still executing. |
| *(no record)* | — | `/codex:status <job-id>` / `/codex:result <job-id>` errors `No job found for "<id>"` — the plugin's state store has no record of that job at all. A different failure mode from `unknown`: there the job existed and lost contact; here there is nothing to recover from the plugin. |

This is real, currently-shipping behavior in the installed plugin
(`scripts/codex-companion.mjs` sets `status: "queued"` at job creation;
`scripts/lib/job-control.mjs`'s `reconcileJobLiveness` sets `status: "unknown", phase:
"orphaned"` when the tracked PID is no longer alive; `scripts/lib/tracked-jobs.mjs` does the
same when the Codex transport itself reports a lost runtime), not a special mode you have to
opt into. Verify against the resolved plugin root
(`~/.claude/scripts/codex-plugin-root.sh`) if a future version changes this — don't assume the
vocabulary is stable across plugin upgrades without checking `scripts/lib/job-control.mjs` and
`scripts/lib/render.mjs` again.

## The protocol

1. **Record the job ID when you background it**, and poll with `/codex:status <job-id>`.
2. **Treat `unknown`/`orphaned` as an integrity incident**, not a pending result. Do not tell
   the user the task completed, do not infer what the result probably was, and do not silently
   kick off a duplicate task to "just redo it."
3. **Inspect before acting**: read the job's reported log path, run `git diff` and look at
   files on disk for partial work, and note the displayed Codex session ID (`threadId` —
   shown as `Resume in Codex: codex resume <threadId>` in `/codex:status` output).
4. **Use `codex resume <threadId>`** to inspect or continue the underlying Codex session when
   appropriate. Only launch a fresh replacement task after you've accounted for whatever
   partial disk changes the orphaned run left behind — an orphaned task may have already
   written files; starting a naive replacement can double-apply or conflict with them.
5. **`/codex:result <job-id>` on an `unknown` job is not a recovered result** — at best it
   surfaces that the final payload is missing. Don't present its output as if it were the
   task's actual deliverable.
6. **`queued` or `running` is not a deliverable.** Claim completion only once `/codex:status`
   (or `/codex:result`) reports an actual `completed` (or a terminal `failed`/`cancelled`)
   outcome — never report progress-in-flight, queued or running, as if the work were done.
7. **A missing job record (`No job found`) is a distinct case from `unknown`** — report it as
   such rather than folding it into the same "orphaned" language. It means the current plugin
   state store never had (or no longer has) this job's record, so the result can't be
   recovered through the plugin at all. Inspect disk/log artifacts directly before deciding
   whether to rerun the work.

## Why this matters here

Delegating implementation work to Codex is now the default (`## Model Routing` in this file),
and a growing share of that work runs `--background`. A background job you can't see finish is
exactly the situation `verification-integrity.md`'s "instruments must distinguish healthy from
not looking" principle describes: if the job's status can't tell you "the worker actually died"
from "everything is fine, just still going," it isn't an instrument you can trust — treat
`unknown` with the same suspicion you'd give a health check that can't fail.

## Relationship to other rules

- `verification-integrity.md` — the general instrument-integrity principle this specializes for
  Codex job status.
- Global `## Model Routing` → "Codex-first (default)" table — the delegation entry point this
  rule governs the follow-through for.
