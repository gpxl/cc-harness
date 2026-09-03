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

### The pipe incident (2026-07-16, SetDigger)

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

### Why "instruments" earned a section (2026-08-10, SetDigger/mixid)

In a single session four instruments were built or extended and every one had the same defect:

| Instrument | Reported | Could not distinguish |
|---|---|---|
| Adoption RPC counters | `isrc_set: 36` | "already correct" vs "no evidence present" — a three-way branch counted two outcomes, so `seen − unlinked − skipped` never reconciled against `set + conflicts` |
| Monitor stall check | `STALLED` after a restart | a stalled child vs a child two minutes old — it timed the *outage*, not the child |
| Monitor gate detector | `0 gates` | no gates vs grepping the wrong file (the marker went to per-item logs, not the aggregate; 7 gated items sat on disk unseen) |
| Monitor gate all-clear | `GATE CLEARED` | not gated vs **not fetching** — it fired during a backoff, when nothing could have been gated |

Each was written by someone who had just been careful about verification integrity in the
production code. The observability *around* the work got the sloppiness the work was spared.

The curly-apostrophe detail in the rule is from the same session: a detector had to match
`you’re`, not `you're`, because that is what the upstream service actually emits.

---

## branch-completion-review

Both stages earned their place on the same branch, on the same day (2026-08-06, SetDigger,
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

**2026-09-03 — pipeline cost review (rudderstack marketing monorepo).** The project asked whether
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

---

## agent-isolation

On 2026-08-10 (SetDigger) collision happened twice in one day:

- **Phase `tj7b.5`** — a second session had already implemented and shipped the SetDigger
  half (RPC + migration + admin hook) while this one was working elsewhere. Discovered only
  by reading the tracker's own notes *after* picking the phase up, and only because those
  notes happened to be thorough.
- **Phase `tj7b.6`** — two sessions built the same design six minutes apart: the same pure
  module (in two different packages) and **the same script filename**, both uncommitted.
  Discovered by accident, when a `PreToolUse` branch guard refused a write and the follow-up
  inspection showed a `+` marker in `git worktree list`.

Neither was caught by a rule. Both were caught by luck. Hence the preflight, and hence
"read the tracker item's NOTES, not just its status" — `tj7b.5` was "open" and half-shipped
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

On 2026-07-20 (StemLab), six parallel worktree agents each independently ran the project's
UI gates (`uitest.sh`, `check-clipping.sh`, `archive-ux.sh`, `bundle.sh --verify`, and
`swift run App --measure/--audit/--scenario` harness modes). Every one of those pops real
windows via the window server. Six agents × several gate runs each = the user's desktop
continuously flickering with app windows opening and closing — disruptive enough that the
user stopped the run to ask what was wrong. The same project had already merged a fix for
uitest scenario spillover from *engine contention* between overlapping harness runs, so
concurrency here risks flaky results, not just annoyance.

---

## peer-session-coordination

On 2026-08-22 (StemLab) two interactive sessions were driving the same repo: one finishing PR #334
(Arrange interactions, in a worktree) and one running PR #336 (extracting `DesignSystem` into its own
SwiftPM target, in the main checkout). The #334 session found the collision on its own — it measured
that all ten of its `Sources/StemLabApp/` files were in #336's diff, including an `AXID.swift` that
#336 deletes by rename — and then **offered to route the information to the peer through the user**
("tell me which session is Lite and I'll pass it the overlap table"). The peer messaged first anyway,
and the two settled ordering, the `package`-visibility change to the relocated hunk, and who held the
window server in two exchanges that cost the user nothing.

Nothing broke, which is the point: the failure mode is not a corrupted tree but a user turned into a
message bus between agents that could have asked each other. Everything the #334 session needed to
know — that #336 was mid-`clipping` and owned the window server, that `AXID` was being raised to
`package` and a bare `static let` would fail one file away from its cause, that #336 was closer to a
green gate and should merge first — was known only to the peer, and none of it was in the user's head.

The `package` detail is worth stating precisely, because the peer corrected the first write-up of it
and the correction is the more useful lesson. It was not knowledge one session happened to hold and
the other lacked. The peer had assumed a `package struct` with `package` members would synthesize a
`package` memberwise init; it does not — the synthesized init stays `internal` — and it only found
that out by building a throwaway package to test it, which is why its branch carries 36 hand-written
`package init`s. So the asymmetry a peer can resolve is usually not *"they know more"* but
**"they have already paid for the experiment"**: an hour of someone else's measurement, available for
the cost of a message. That is a far more common condition than superior knowledge, and it is the one
worth asking about.

The exchange also produced a finding neither session would have reached alone: the #334 session
noticed that once `DesignSystem` became a sibling target, the `ui_review_gate_pattern` naming
`Sources/StemLabApp/` would stop matching it, so the ui-review/clipping/uitest stages would silently
not fire on DS changes — a gate that cannot come back red. #336 had already closed it, and confirmed
a related one: the palette scanner's `^[[:space:]]*static let` token grep went to "cannot resolve
token" on all 72 pairings the moment the declarations became `package static let`.

---

### Revision, 2026-08-22 — scope by shared resource

The rule was written the same morning and the instruction behind it was "coordinate with other
agents *in project* automatically". By evening a review of every peer `SendMessage` on the machine
(134 peer-to-peer messages over 45 days; 109 of them that day) showed the traffic had spread well past
one repo: 37 messages crossed project directories, all stemlab ↔ setdigger/setdigger-mixid. Read in
full, they sorted into five kinds, and a "same project" restriction keyed on session directory would
have cut the wrong four:

- **~22 machine-resource handoffs** between different repos — window server, CPU, the Swift
  toolchain — which is the rule's own table being followed; the resource belongs to the Mac, not the
  repo. Gates held this way came back green first time. Cost: setdigger-01 held a one-minute
  `pnpm verify` for 49 minutes because it was told "wait until I message" — a queue would have
  released it the moment the other gate finished.
- **7 messages of a collision check on cc-harness** (user-requested) that found a real defect in the
  rule PR — the `global/CLAUDE.md` index line claimed a path-scoping the frontmatter did not have —
  and the fact that `~/.claude/rules` symlinks into the working tree, so merging swaps the ruleset
  under every live session. A peer's "go ahead and merge" was withdrawn on challenge.
- **5 messages on a same-repo collision that only looked cross-project**: a session started in
  `setdigger/` was working the mixid checkout and branched under a live mixid session. The repo
  being worked, not the session's cwd, is what "same project" has to mean.
- **2 messages landing files across repos** on the user's instruction — unanswered, defaulted to a
  worktree, zero disruption.
- **6 messages of open-ended engineering discussion** (mutation tests "aimed backwards", comments that
  rot), agent-initiated while the standing instruction was "merge it once the gate passes", median
  ~2,300 chars, never surfaced to the user. The only kind that strayed — and it would be equally
  off-charter between two sessions in one repo.

Hence the revision: tiers by what is shared (repo → full protocol; machine → resource notices only;
shared dependency → one collision check), a size bound (notice or question, not an essay), and
"prefer a mechanism to a message" — the per-project lock in `windowed-gate-serialization.md` does
not reach another repo, which is the whole reason the machine tier exists. Noise seen on the way:
questions fanned out to every peer because names say nothing about what a session holds; ~10
messages of re-introduction after a restart; one ping sent 12 times for 3 recipients (`name` and
`name [hash]` forms, two session ids); two empty messages.

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

## agent-enforcement

Even when the code-quality gate is exempt (e.g. doc changes), using the commit agent
ensures consistent commit formatting, proper branch workflow, and PR creation.

---

## agent-purpose-statements

A code-quality agent asked to "check this module" produces a full report. The same agent
told "this is a quick pre-merge check — just verify the happy path" focuses on what matters.

---

## claude-md-project-templates

Prompt for project owners writing a NEVER list:

| Category | Think about |
|----------|-------------|
| Testing | What should never be mocked? What tests must never be skipped? |
| Architecture | What boundaries exist? What import rules? What patterns are banned? |
| Dependencies | Which libraries are forbidden? What's the approved alternative? |
| Infrastructure | Which directories/configs are dangerous to modify? |
| Data | What DB operations need human approval? What's irreversible? |
| Releases | What gates exist before publish/deploy? |
| Secrets | What project-specific secret files beyond `.env`? |

Prompt for autonomy tiers:

| Tier | Think about |
|------|-------------|
| Autonomous | Which commands are safe? Which directories are freely editable? |
| Confirm first | What has moderate blast radius? What affects shared state? |
| Never | What's irreversible? What affects production? What costs money? |

---

## global CLAUDE.md — why the index format

Measured pass rates that motivated the required-elements list:

| Config | Pass Rate |
|--------|-----------|
| No docs / Skills | 53% |
| **AGENTS.md index** | **100%** |

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
  Measured: the stemlab store held eight completed jobs from session `5f8ebb39…`, all invisible
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
