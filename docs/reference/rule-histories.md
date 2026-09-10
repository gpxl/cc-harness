# Rule Histories (maintainer reference)

Incidents and measurements that motivated each rule in `rules/`. This directory is
**not symlinked into `~/.claude/`** — nothing here is loaded into any session. It exists
so the evidence behind a rule survives without costing context tokens on every turn.

Previously these lived as `<!-- HISTORY -->` blocks inside the rule files themselves.
HTML comments are still tokens: they were moved here rather than commented out.

---

## branch-discipline

Committing to `main` and rewinding it afterwards is recoverable on a local checkout, but:

1. It leaves a window where the commit is on `main`. If a push happens — by the user, an
   editor's auto-push, a hook, or an agent that didn't read the no-direct-push rule — the
   commit lands on remote `main`. Some projects gate releases off `main`; an accidental
   push can trigger CI/CD.
2. The rewind needs `git branch -f main origin/main` (or a reset) — a destructive op the
   user must authorize each time.
3. Branch creation costs nothing. Doing it up front removes the whole class of problem.

---

## verification-integrity

### The pipe incident (2026-07-16, AudioWebsite)

`pnpm verify 2>&1 | tail -40` was run twice on a PR and reported exit 0 both times. Lint
was in fact failing with 3 TypeScript `ts(2352)` strict-mode errors. The errors surfaced
only because a separate `code-quality` agent independently re-ran lint and returned FAIL,
contradicting the orchestrator's own "verify passed" claim. Two green runs, zero signal —
and the green had already been written into a PR description as evidence.

The pipe was added for a reasonable reason (verify output is thousands of lines and needs
trimming). That's the trap: the mistake looks like good hygiene.

### Believe the contradicting evidence

In the incident above the sub-agent was right and the orchestrator was wrong; treating the
agent's FAIL as noise would have shipped the errors. Two examples of the corollary from the
same session, both initially looking like "my change broke it":

| Symptom | Actual cause | How it was settled |
|---------|--------------|--------------------|
| `apps/admin build` red in a fresh worktree | gitignored `.env.local` absent — env gap, not code | Copied env in → exit 0 |
| Cloudflare Pages check red on an untouched app | CF-side internal error at asset-publish; build itself compiled | Fetched build log; retry passed the identical commit |

### Why "instruments" earned a section (2026-08-10, AudioWebsite)

In a single session four instruments were built or extended and every one had the same defect:

| Instrument | Reported | Could not distinguish |
|---|---|---|
| External-id linking RPC counters | `external_id_set: 36` | "already correct" vs "no evidence present" — a three-way branch counted two outcomes, so `seen − unlinked − skipped` never reconciled against `set + conflicts` |
| Monitor stall check | `STALLED` after a restart | a stalled child vs a child two minutes old — it timed the *outage*, not the child |
| Monitor gate detector | `0 gates` | no gates vs grepping the wrong file (the marker went to per-item logs, not the aggregate; 7 gated items sat on disk unseen) |
| Monitor gate all-clear | `GATE CLEARED` | not gated vs **not fetching** — it fired during a backoff, when nothing could have been gated |

Each was written by someone who had just been careful about verification integrity in the
production code. The observability *around* the work got the sloppiness the work was spared.

The curly-apostrophe detail in the rule is from the same session: a detector had to match
`you’re`, not `you're`, because that is what the upstream service actually emits.

---

## branch-completion-review

Both stages earned their place on the same branch, on the same day (2026-08-06, AudioWebsite,
`feat/slide-in-demo-cta` — two CMS-managed marketing features built by parallel
clone-the-sibling authoring):

1. **Refactor pass:** clone-the-sibling authoring left **8 duplication sites** — cloned
   fetch functions, cloned path-condition logic plus the type shape it operates on, cloned
   storage getters/setters, cloned close-button JSX, repeated GROQ field groups, repeated
   schema field triplets. A single `refactor(...)` commit collapsed all of them. None of it
   was visible to lint, typecheck, or QA — invisible to every existing gate precisely
   because it *worked*.
2. **Adversarial review:** after ALL gates were green — code-quality passes, two browser-QA
   rounds, the refactor pass itself — an independent adversarial agent still found a
   code-confirmed **BLOCKER**: a root-layout-mounted exit-intent detector whose armed
   listener survived client-side navigations, so it could burn its once-per-session token
   invisibly on an excluded page and then pop its modal with no trigger on the next
   eligible page. It sat exactly in a gap an interrupted QA run had left, and the
   orchestrating session, having written the code, read right past it. The same review
   caught an undisclosed behavior change to live third-party script gating buried in a
   feature commit, and a CMS-trust hole in a "never co-occur" invariant. Verdict: NO-GO.
   One fix commit later, a re-review traced every original failure scenario against the new
   code and returned GO.

Stage 1's note about self-reported line counts comes from the same branch: an implementing
agent claimed −100 lines where the actual commit was +23.

**2026-09-03 — pipeline cost review (WebAppMonoRepo, a client marketing monorepo).** The project asked whether
code-quality and the adversary were redundant, whether to reorder them, or to move the adversary
in front of the task. Each answer became a line in § Cost and ordering:

- **Not redundant.** There, code-quality was lint + typecheck on Haiku; the adversary's founding
  BLOCKER (above) was an omission after every gate was green. Different defect classes.
- **Order stays.** Deterministic gates before a model read is fail-fast, and a NO-GO costs the
  same number of adversary runs wherever the commit sits.
- **Plan-stage review is a complement.** It catches scope/approach on schema and shared-component
  tasks and cannot see the omission class.
- **The spend was elsewhere**, in four places: (a) the project's `CLAUDE.local.md` had *restated*
  this rule on 2026-08-06 and never picked up the 08-24 demotion — both stages still read
  "mandatory" locally a month later; project files now reference and carry parameters only
  (`claude-md-project-templates.md`). (b) Three review passes could stack per branch — the Codex
  stop-gate, `/codex:review`, and this stage. (c) The Model row said Opus/Fable while
  `global/CLAUDE.md` routing said `/codex:adversarial-review` — the rule contradicted the table it
  sits under. (d) The code-quality agent was being invoked by reflex in a repo with
  `quality_gate_pattern: (none)`, where `agents/commit.md` Step 2 already skips its gate — a Haiku
  agent wrapping two shell commands. `verify_cmd` → `VERIFY RESULT:` is the whole gate there.
- **Measured while checking (b):** `codex.sh setup --json` in that repo's main checkout reported
  `reviewGateEnabled: false`, contradicting the 09-02 "on in every main checkout" note in
  `global/CLAUDE.md`. The note now says to check, not assume.
- **(e) Same day, the first branch under the rewritten rule (WEB-2800) parked at the adversary.**
  The settled route is read-only `/codex:rescue` with the Stage 2 contract: an inference from the
  plugin contract that the user chose to stand behind, not a documented routing instruction. Read a
  command's frontmatter and the plugin's agent contract before naming it in a rule; when the harness
  refuses something, use the plugin's sanctioned route or ask the user, never a different tool.
- **(f) Merge gate false red in worktrees**: `scripts/install-symmetry-selftest.sh` failed at
  `origin/main` too, with a bare `FAIL` and no reason — `scripts/git-snapshot` is a gitignored
  machine-local symlink that a fresh worktree never has, and the test's `readlink` on it returned
  1 silently. The selftest now names the missing link and how to recreate it; proven both ways
  (FAIL-with-reason without the link, PASS with it).

---

## agent-isolation

On 2026-08-10 (AudioWebsite) collision happened twice in one day:

- **Phase `aw-tj7b.5`** — a second session had already implemented and shipped the AudioWebsite
  half (RPC + migration + admin hook) while this one was working elsewhere. Discovered only
  by reading the tracker's own notes *after* picking the phase up, and only because those
  notes happened to be thorough.
- **Phase `aw-tj7b.6`** — two sessions built the same design six minutes apart: the same pure
  module (in two different packages) and **the same script filename**, both uncommitted.
  Discovered by accident, when a `PreToolUse` branch guard refused a write and the follow-up
  inspection showed a `+` marker in `git worktree list`.

Neither was caught by a rule. Both were caught by luck. Hence the preflight, and hence
"read the tracker item's NOTES, not just its status" — `aw-tj7b.5` was "open" and half-shipped
at the same time.

---

## parallel-authoring

The naive approach to N independent work items is sequential: item 1 end to end (author →
gate → commit → PR), then item 2. When each must pass an expensive shared gate, that is N
expensive gate runs, and sequential authoring leaves most available parallelism unused.

Measured on a real run (CMS phases 9d–9h, May 2026): five workflow-skill beads, each a new
skill file plus two eval scenarios. Five parallel authoring agents and one consolidated
`eval/run.sh all` replaced five sequential ~60-min gate runs — roughly 3–6 h saved — and
avoided compounding a known eval-pool flake by running the heavy gate once instead of five
times.

---

## windowed-gate-serialization

On 2026-07-20 (AudioApp), six parallel worktree agents each independently ran the project's
UI gates (`uitest.sh`, `check-clipping.sh`, `archive-ux.sh`, `bundle.sh --verify`, and
`swift run App --measure/--audit/--scenario` harness modes). Every one of those pops real
windows via the window server. Six agents × several gate runs each = the user's desktop
continuously flickering with app windows opening and closing — disruptive enough that the
user stopped the run to ask what was wrong. The same project had already merged a fix for
uitest scenario spillover from *engine contention* between overlapping harness runs, so
concurrency here risks flaky results, not just annoyance.

---

## peer-session-coordination

On 2026-08-22 (AudioApp), sessions for AudioApp PR #A (a canvas-editing surface) and AudioApp PR #B
(a shared UI target) found that their `Sources/AudioApp/` diffs overlapped. The first offered to route
the information through the user; the peer messaged first, and they settled ordering, `package`
visibility, and window-server ownership in two exchanges. That is the failure to avoid: turning the
user into a message bus between agents that can ask each other.

The peer had already tested an important detail: a `package struct` with `package` members does not
synthesize a `package` memberwise init — the synthesized init stays `internal` — which is why its
branch carried 36 hand-written `package init`s. The useful asymmetry is usually not *"they know more"*
but **"they have already paid for the experiment"**: someone else's measurement is available for the
cost of a message. The exchange also caught a gate gap: `ui_review_gate_pattern` naming
`Sources/AudioApp/` would silently miss the new sibling target.

---

### Revision, 2026-08-22 — scope by shared resource

The same-day rule said to coordinate automatically *in project*. A census of 134 peer messages over
45 days (109 that day) found 37 cross-directory messages, all AudioApp ↔ AudioWebsite/AudioWebsiteMedia.
The five kinds show why the boundary is what is shared, not a session directory:

- **~22 machine-resource handoffs:** valid window-server, CPU, and Swift-toolchain notices; host-01
  waited 49 minutes for a one-minute `pnpm verify` because a queue did not release it automatically.
- **7 cc-harness collision-check messages:** a user-requested check found a real rule defect and a
  live-ruleset symlink; a premature merge approval was withdrawn.
- **5 same-repo collisions that looked cross-project:** an `audio-website/` session worked the
  AudioWebsiteMedia checkout under a live AudioWebsiteMedia session; the worked repo, not cwd, matters.
- **2 cross-repo file landings:** user-directed, unanswered, and safely defaulted to a worktree.
- **6 open-ended engineering discussions:** off-charter debate, median ~2,300 chars, never surfaced.

Hence tiers by what is shared (repo → full protocol; machine → resource notices only; shared dependency
→ one collision check), a short-message bound, and "prefer a mechanism to a message." The machine tier
exists because a per-project lock cannot reach another repo.

---

## computer-control-release

These tools are structurally different from ordinary file/shell tools: they take over
something the user owns and would otherwise be using — their screen, their simulator
window, their logged-in browser. Existing tool-level instructions cover the *first* half
(attach early, as soon as it's useful) but say little about handing it back. Left
unaddressed, the default failure mode is an agent that opens a live surface for a
legitimate reason early in a task, then works through several unrelated steps — edits,
builds, reads — with that surface still attached, because nothing in the loop ever prompted
it to close.

This is the single-agent, single-surface analogue of `windowed-gate-serialization.md`
(N *parallel* agents flooding the desktop at once): duration instead of concurrency, same
underlying resource.

---

## codex-dispatch-protocol

Externally supplied advice (2026-09-01, from a long-running collaboration-heavy session on the
same plugin), each item checked against plugin 1.0.6 source before it became a rule:

- **Wrapper ≠ job.** `enqueueBackgroundTask` spawns `task-worker` with `detached: true` +
  `unref()`; `runForegroundCommand` runs `runTrackedJob` in the calling process, so a harness
  timeout on the Bash call kills the worker while the app-server turn (under the detached broker)
  keeps running. Record then reads `running` with a dead pid → `unknown/orphaned` on next status.
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
- **setsid (2026-09-02).** Advice: wrappers should `setsid` long-running Codex sessions so a killed
  wrapper does not take the session with it. Measured with a 5 s Bash timeout: the harness kills the
  call's process group (`sleep 90 &` died), while a Node `detached: true` child (pgid == pid, ppid 1)
  survived. `spawnDetachedTaskWorker` and `spawnBrokerProcess` both pass `detached: true`, so the
  advice is already implemented for `--background`; only a foreground task is exposed, and the rule
  routes long work to `--background` rather than adding a wrapper that would orphan a tracked worker.

---

## bounded-review-loops (2026-09-05)

AudioApp review→fix→review chains escaped any usable budget: PR #8 reached 12 rounds, 22 commits,
and 19 `fix(` commits; PR #10 reached four rounds with BLOCKER counts 4→9→6, including one
fabricated finding. One session (`5f8ebb39`) produced 2,360 assistant messages, 65 merge-gate
invocations, and 60 Agent calls; peer traffic reached 29, 20, and 17 messages per session.

The change adds `loop-report.sh`, a hermetic counter test, a measured baseline, a three-round Stage 2
budget with same-reviewer resume and user-only extension, per-finding fix/bead/unverified triage,
and peer-message bounds. The rule freezes for 14 days after this lands: no rule edit unless a
`loop-report` metric shows it is needed; a rule PR cites the metric it moves.
On 2026-09-05, `cch-9o4` recorded that `--resume-last` can resume an intervening fix thread, so later rounds conditionally resume and otherwise receive a controlled R1 handoff.
