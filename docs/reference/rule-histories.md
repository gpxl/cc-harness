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
