---
paths:
  - "**/*.swift"
  - "**/*.xcodeproj/**"
  - "**/electron/**"
  - "**/ios/**"
  - "**/playwright*"
  - "**/scripts/visual-testing/**"
  - "**/.claude/skills/**"
---
# Windowed-Gate Serialization (Parallel Agents on GUI-App Projects)

When parallel agents work on a project whose verification gates open **real, visible application
windows** — a macOS window-server harness, an Electron app, a headed browser, a simulator, a
screenshot/measure mode — those windowed gates must NOT run concurrently. Parallelize the
authoring; serialize the windows.

Each agent is individually following the project's own gate checklist correctly; the failure is
emergent — correctness gates that are safe solo become a desktop-flooding, contention-prone swarm
in parallel. (Incident: `~/projects/cc-harness/docs/reference/rule-histories.md`.)

## The rule

Split the per-branch pipeline into two phases:

| Phase | Parallelism | What runs |
|-------|-------------|-----------|
| **A — Author (headless)** | Full fan-out, one agent per work item (per `parallel-authoring.md` / `agent-isolation.md`) | Implementation, unit tests via the project's bounded runner, **headless** scanners (lint, static design-system/audio-hazard scanners), commit, push, open PR |
| **B — Windowed gates (serialized)** | **One branch at a time**, a single gate-runner stream | Every gate that needs a window server / opens visible UI: UI-interaction harnesses, clipping/screenshot audits, UX-history archival (committed onto the branch as a follow-up), bundle + launch smoke, and the project's merge gate |

Authoring agents' prompts must **explicitly prohibit** the windowed commands by name — "run the
gates" is not enough, because each agent will dutifully run all of them. Name the banned scripts
and harness flags.

Nothing is lost by deferring: a project's merge gate re-runs the full applicable matrix at the
PR's HEAD anyway, so Phase B before merge produces the same green the inline run would have — 
without N-way window churn.

### Identifying a "windowed" gate

Ask: does this command need a window server / display, or does it create a visible window,
even off-screen-positioned? Typical tells: the project docs say "needs a window server";
screenshot/measure/audit/scenario modes; launch-smoke steps; anything driving synthesized UI
events. When unsure, treat it as windowed — the cost of serializing a headless gate is seconds;
the cost of parallelizing a windowed one is the user's desktop.

### Belt-and-braces: a machine-global lock

Prompts fail; locks don't. Wrap any windowed command in a machine-global mutex so a stray run
serializes instead of overlapping (per-checkout locks are NOT enough — parallel agents live in
separate worktrees with separate `.build`/state dirs):

```bash
LOCK=/tmp/<project>-uigate.lock
while ! mkdir "$LOCK" 2>/dev/null; do
  # stale-lock reclaim: holder PID dead => take over
  holder=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rmdir "$LOCK" 2>/dev/null || true; continue; fi
  sleep 15
done
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
<windowed command here>
```

Projects that adopt this pattern permanently should fold the lock into the gate scripts
themselves (the same funnel-everything-through-one-runner discipline as a bounded test runner),
so it holds for humans and agents alike.

## Sub-agent execution discipline

Background authoring agents strand themselves by launching the test suite as a background task and
stopping to "wait for the notification" — a wake-up that never reaches a sub-agent. In
authoring-agent prompts:

- Run the test suite **synchronously in the foreground** (bounded runners finish in seconds/minutes).
- Capture exit codes via redirect-to-file, never through a pipe (`verification-integrity.md`).
- Do not spawn nested sub-agents for gates the agent can run directly; do not wait on
  notifications from processes you backgrounded.

## Relationship to other rules

- **`parallel-authoring.md`** — fan out authors, fan in through one windowed-gate stream.
- **`agent-isolation.md`** — worktrees isolate git state, NOT the window server / screen / shared engines.
- **`peer-session-coordination.md`** — this lock is per-project (`/tmp/<project>-uigate.lock`) and the gate-runner stream assumes ONE orchestrator owns every agent. A peer session in another repo neither holds the lock nor sees it, so for that case telling it directly ("taking the window server for ~5 min", "it's free") is the only serialization — and it carries only what a lock can't. Where the lock reaches, take it and send nothing.
- **`verification-integrity.md`** — a Phase-A PR must state which gates were deferred; never describe a deferred gate as passed.
