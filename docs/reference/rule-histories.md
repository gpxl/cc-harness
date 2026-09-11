# Rule Histories (maintainer reference)

Incidents and measurements behind the rules in `rules/`. This directory is not symlinked
into `~/.claude/`, so sessions do not load it. It keeps the evidence without adding to every
session's context.

These histories once lived in `<!-- HISTORY -->` blocks inside the rule files. HTML comments
still consume tokens, so the histories moved here.

---

## branch-discipline

An accidental commit to `main` can be repaired locally, but the repair carries avoidable risk:

1. Until the rewind, the user, an editor's auto-push, a hook, or an agent can push the commit
   to remote `main`. Projects that release from `main` may then start CI/CD.
2. Rewinding requires `git branch -f main origin/main` or a reset, both destructive operations
   that need user authorization.
3. Creating the branch first is effectively free and prevents both problems.

---

## verification-integrity

### The pipe incident (2026-07-16, AudioWebsite)

`pnpm verify 2>&1 | tail -40` reported exit 0 twice on one PR, although lint had three
TypeScript `ts(2352)` strict-mode errors. A separate `code-quality` agent reran lint and
returned FAIL, contradicting the orchestrator's "verify passed" claim. The false green had
already been cited in the PR description.

The pipe was meant to trim thousands of output lines. That reasonable cleanup hid the real
exit status.

### Believe the contradicting evidence

The sub-agent was right and the orchestrator was wrong. Ignoring the contradiction would have
shipped the errors. The same session produced two failures that initially looked code-related
but were not:

| Symptom | Actual cause | How it was settled |
|---------|--------------|--------------------|
| `apps/admin build` red in a fresh worktree | gitignored `.env.local` absent — env gap, not code | Copied env in → exit 0 |
| Cloudflare Pages check red on an untouched app | CF-side internal error at asset-publish; build itself compiled | Fetched build log; retry passed the identical commit |

### Why "instruments" earned a section (2026-08-10, AudioWebsite)

One session built or extended four instruments. Each failed to distinguish two materially
different states:

| Instrument | Reported | Could not distinguish |
|---|---|---|
| External-id linking RPC counters | `external_id_set: 36` | "already correct" vs "no evidence present" — a three-way branch counted two outcomes, so `seen − unlinked − skipped` never reconciled against `set + conflicts` |
| Monitor stall check | `STALLED` after a restart | a stalled child vs a child two minutes old — it timed the *outage*, not the child |
| Monitor gate detector | `0 gates` | no gates vs grepping the wrong file (the marker went to per-item logs, not the aggregate; 7 gated items sat on disk unseen) |
| Monitor gate all-clear | `GATE CLEARED` | not gated vs **not fetching** — it fired during a backoff, when nothing could have been gated |

Production verification had been careful; its surrounding observability had not.

The rule's curly-apostrophe example also comes from this session: the upstream service emits
`you’re`, not `you're`, so the detector had to match it exactly.

---

## branch-completion-review

Both stages came from the same branch on 2026-08-06: AudioWebsite
`feat/slide-in-demo-cta`, where parallel agents built two CMS-managed marketing features by
cloning sibling implementations.

1. **Refactor pass:** the branch contained **8 duplication sites** — cloned
   fetch functions, cloned path-condition logic plus the type shape it operates on, cloned
   storage getters/setters, cloned close-button JSX, repeated GROQ field groups, repeated
   schema field triplets. A single `refactor(...)` commit collapsed all of them. None of it
   appeared in lint, typecheck, or QA because the duplicated code worked.
2. **Adversarial review:** after every gate was green — code-quality passes, two browser-QA
   rounds, the refactor pass itself — an independent adversarial agent still found a
   code-confirmed **BLOCKER**: a root-layout-mounted exit-intent detector whose armed
   listener survived client-side navigations, so it could burn its once-per-session token
   invisibly on an excluded page and then pop its modal with no trigger on the next
   eligible page. An interrupted QA run had left that gap, and the authoring session read
   past its own mistake. The same review
   caught an undisclosed behavior change to live third-party script gating buried in a
   feature commit, and a CMS-trust hole in a "never co-occur" invariant. Verdict: NO-GO.
   One fix commit later, a re-review traced every original failure scenario against the new
   code and returned GO.

Stage 1's note about self-reported line counts comes from the same branch: an implementing
agent claimed −100 lines where the actual commit was +23.

**2026-09-03 — pipeline cost review (WebAppMonoRepo, a client marketing monorepo).** The review
asked three questions: were code-quality and adversarial review redundant, should their order
change, and should adversarial review move ahead of the task? Its conclusions became § Cost and
ordering:

- **Not redundant.** There, code-quality was lint + typecheck on Haiku; the adversary's founding
  BLOCKER (above) was an omission after every gate was green. Different defect classes.
- **Order stays.** Deterministic gates before a model read is fail-fast, and a NO-GO costs the
  same number of adversary runs wherever the commit sits.
- **Plan-stage review is a complement.** It catches scope/approach on schema and shared-component
  tasks and cannot see the omission class.
- **The spend was elsewhere**, in four places. (a) The project's `CLAUDE.local.md` restated the
  rule on 2026-08-06 and missed the 08-24 demotion, so both stages still appeared mandatory a
  month later. Project files now reference the rule and carry only parameters
  (`claude-md-project-templates.md`). (b) Three review passes could stack on one branch: the Codex
  stop-gate, `/codex:review`, and this stage. (c) The Model row named Opus/Fable while
  `global/CLAUDE.md` routed to `/codex:adversarial-review`; the rule contradicted its own table.
  (d) The code-quality agent ran by reflex in a repo with `quality_gate_pattern: (none)`, although
  `agents/commit.md` Step 2 already skipped that gate. It was a Haiku agent wrapping two shell
  commands; `verify_cmd` → `VERIFY RESULT:` was the whole gate.
- **Measured while checking (b):** `codex.sh setup --json` in that repo's main checkout reported
  `reviewGateEnabled: false`, contradicting the 09-02 "on in every main checkout" note in
  `global/CLAUDE.md`. The note now says to check, not assume.
- **(e) The same day, the first branch under the rewritten rule (WEB-2800) parked at the adversary.**
  The settled route is read-only `/codex:rescue` with the Stage 2 contract: an inference from the
  plugin contract that the user chose to stand behind, not a documented routing instruction. A rule
  must check command frontmatter and the plugin's agent contract before naming a route. If the
  harness refuses it, use a sanctioned route or ask the user.
- **(f) Merge gate false red in worktrees**: `scripts/install-symmetry-selftest.sh` failed at
  `origin/main` too, with a bare `FAIL` and no reason — `scripts/git-snapshot` is a gitignored
  machine-local symlink that a fresh worktree never has, and the test's `readlink` on it returned
  1 silently. The selftest now names the missing link and how to recreate it; proven both ways
  (FAIL-with-reason without the link, PASS with it).

---

## agent-isolation

AudioWebsite had two collisions on 2026-08-10:

- **Phase `aw-tj7b.5`** — another session had already implemented and shipped the AudioWebsite
  half (RPC + migration + admin hook). This surfaced only after the phase was picked up, when
  someone read the tracker's unusually thorough notes.
- **Phase `aw-tj7b.6`** — two sessions built the same design six minutes apart: the same pure
  module (in two different packages) and **the same script filename**, both uncommitted.
  A `PreToolUse` branch guard happened to refuse a write; inspection then found the `+` marker
  in `git worktree list`.

Rules caught neither collision. The preflight now requires reading a tracker's NOTES, not only
its status: `aw-tj7b.5` was both "open" and half-shipped.

---

## parallel-authoring

Running N independent items end to end in sequence produces N runs of an expensive shared gate
and leaves available parallelism idle.

Measured on a real run (CMS phases 9d–9h, May 2026): five workflow-skill beads, each a new
skill file plus two eval scenarios. Five parallel authoring agents and one consolidated
`eval/run.sh all` replaced five sequential ~60-min gate runs — roughly 3–6 h saved — and
avoided compounding a known eval-pool flake by running the heavy gate once instead of five
times.

---

## windowed-gate-serialization

On 2026-07-20, six AudioApp worktree agents independently ran the project's
UI gates (`uitest.sh`, `check-clipping.sh`, `archive-ux.sh`, `bundle.sh --verify`, and
`swift run App --measure/--audit/--scenario` harness modes). Every one of those pops real
windows via the window server. Six agents × several gate runs each left the desktop flickering
with windows until the user stopped the run to ask what was wrong. AudioApp had already fixed
uitest scenario spillover caused by engine contention between overlapping harness runs, so this
concurrency risks flaky results as well as disruption.

---

## peer-session-coordination

On 2026-08-22, sessions for AudioApp PR #A (a canvas-editing surface) and AudioApp PR #B
(a shared UI target) found overlapping `Sources/AudioApp/` diffs. One offered to route the issue
through the user, but the peer messaged directly. Two exchanges settled ordering, `package`
visibility, and window-server ownership. The user did not need to become a message bus.

The peer had already tested an important detail: a `package struct` with `package` members does not
synthesize a `package` memberwise init — the synthesized init stays `internal` — which is why its
branch carried 36 hand-written `package init`s. The useful asymmetry was not that the peer knew
more, but that it had already paid for the experiment. That measurement was available for the cost
of a message. The exchange also caught a gate gap: `ui_review_gate_pattern` naming
`Sources/AudioApp/` would silently miss the new sibling target.

---

### Revision, 2026-08-22 — scope by shared resource

The same-day rule said to coordinate automatically within a project. A census of 134 peer messages
over 45 days—109 on that day—found 37 cross-directory messages, all AudioApp ↔
AudioWebsite/AudioWebsiteMedia. The five categories showed that the right boundary is the shared
resource, not the session directory:

- **~22 machine-resource handoffs:** valid window-server, CPU, and Swift-toolchain notices; host-01
  waited 49 minutes for a one-minute `pnpm verify` because a queue did not release it automatically.
- **7 cc-harness collision-check messages:** a user-requested check found a real rule defect and a
  live-ruleset symlink; a premature merge approval was withdrawn.
- **5 same-repo collisions that looked cross-project:** an `audio-website/` session worked the
  AudioWebsiteMedia checkout under a live AudioWebsiteMedia session; the worked repo, not cwd, matters.
- **2 cross-repo file landings:** user-directed, unanswered, and safely defaulted to a worktree.
- **6 open-ended engineering discussions:** off-charter debate, median ~2,300 chars, never surfaced.

The rule now uses tiers: repo → full protocol; machine → resource notices only; shared dependency
→ one collision check. It also limits message length and prefers a mechanism to a message. The
machine tier exists because a per-project lock cannot reach another repo.

---

## computer-control-release

Computer-control tools take over something the user might otherwise be using: a screen,
simulator window, or logged-in browser. Tool instructions covered attaching early but said little
about handing control back. An agent could therefore open a surface for a valid reason and leave it
attached through unrelated edits, builds, and reading.

This is the single-agent analogue of `windowed-gate-serialization.md`: duration instead of
concurrency, but the same shared resource.

---

## codex-dispatch-protocol

The following advice arrived on 2026-09-01 from a long-running, collaboration-heavy session on the
same plugin. Each point was checked against plugin 1.0.6 source before entering the rule:

- **Wrapper ≠ job.** `enqueueBackgroundTask` spawns `task-worker` with `detached: true` +
  `unref()`; `runForegroundCommand` runs `runTrackedJob` in the calling process, so a harness
  timeout on the Bash call kills the worker while the app-server turn under the detached broker
  continues. The record then shows `running` with a dead pid → `unknown/orphaned` at the next status.
- **Status is per-session/per-workspace.** `resolveStateDir` keys on the git root of `--cwd`;
  `filterJobsForCurrentSession` drops jobs whose `sessionId` ≠ `CODEX_COMPANION_SESSION_ID`.
  Measured: the AudioApp store held eight completed jobs from session `5f8ebb39…`, all invisible
  to session `90ccab88…` in the same checkout.
- **`queued` never reconciles.** `reconcileJobLiveness` returns early unless `status === "running"`.
- **Stale brokers.** 30 `app-server-broker.mjs serve --cwd $TMPDIR/codex-plugin-test-*` pairs
  (plugin selftest residue) had been alive for 28 h. Killed by explicit PID.
- **Config key.** `strings` on codex-cli 0.147.0 finds `writable_roots` (31×), never
  `writeable_roots` — the advice's spelling would have been silently ignored.
- First live use of the protocol was the delegation that wrote its own helper scripts
  (job `task-mtj313h3-8xmdqg`, cc-harness): placement verified via `status --json --cwd`,
  waited via a background PID loop. First attempt of that loop died on zsh's read-only `status`
  variable — hence the scripts, so the loop is written once.
- **Sandbox probe.** After adding `writable_roots` + `network_access`, a task touched
  `~/Library/Caches/org.swift.swiftpm/...` and got `HTTP/2 200` from api.github.com on the *next*
  thread with no broker restart — config is read per thread. `swift build` still fails inside the
  sandbox: swiftc's macro plugin server needs nested `sandbox-exec` (`sandbox_apply: Operation not
  permitted`), independent of the module cache. Builds stay with the orchestrator.
- **setsid (2026-09-02).** The advice said wrappers should `setsid` long-running Codex sessions so a killed
  wrapper does not take the session with it. Measured with a 5 s Bash timeout: the harness kills the
  call's process group (`sleep 90 &` died), while a Node `detached: true` child (pgid == pid, ppid 1)
  survived. `spawnDetachedTaskWorker` and `spawnBrokerProcess` both pass `detached: true`, so the
  advice is already implemented for `--background`; only a foreground task is exposed, and the rule
  routes long work to `--background` rather than adding a wrapper that would orphan a tracked worker.

---

## bounded-review-loops (2026-09-05)

AudioApp review→fix→review chains had no usable budget. PR #8 reached 12 rounds, 22 commits,
and 19 `fix(` commits. PR #10 reached four rounds with BLOCKER counts 4→9→6. The sources disagree
about which PR contained the fabricated blocker, and that attribution was cited rather than
replayed. One session (`5f8ebb39`) produced 2,360 assistant messages, 65 merge-gate invocations,
and 60 Agent calls; peer traffic reached 29, 20, and 17 messages per session.

The response added `loop-report.sh`, a hermetic counter test, a measured baseline, a three-round
Stage 2 budget with same-reviewer resume and user-only extension, per-finding
fix/bead/unverified triage, and peer-message bounds. It also imposed a 14-day rule freeze through
19 September. Until then, a rule edit is allowed only when a `loop-report` metric shows the need,
and the change must cite that metric.

On 2026-09-05, `cch-9o4` recorded that `--resume-last` can resume an intervening fix thread.
Later rounds therefore resume conditionally; otherwise they receive a controlled R1 handoff.
