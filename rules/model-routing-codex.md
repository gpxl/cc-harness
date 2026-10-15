---
paths:
  - "**/*codex*"
  - "**/*codex*/**"
  - "**/review-round*"
  - "**/hooks/*model-routing*"
  - "**/hooks/vendors*"
---
# Model Routing — Codex-first mechanics

Split out of `~/.claude/CLAUDE.md` § Model Routing (cch-ypu) so it stops loading on every turn.
The core there — vendor switch, equivalence table, Mismatch protocol — still governs. **This file
applies only while vendor `openai` is enabled** (`bash ~/.claude/hooks/vendors.sh`); while it is
disabled none of it is a route, and the core's "route silently" rule wins. It is path-scoped, and a
Bash or `/codex:rescue` dispatch opens no matching file, so while `openai` is enabled Read it before
a session's first delegation.

## Core detail the CLAUDE.md summary compresses

- `scripts/codex.sh`'s exit 69 (vendor disabled) is passed through by `codex-dispatch.sh` and is
  distinct from its exit 3 "already running"; `status`/`result`/`cancel` still work for jobs
  already in flight while `openai` is disabled.
- Adding a vendor is one model column in `hooks/model-routing-table.sh`, one entry in the vendor
  arrays, and one line in `vendors.conf`.
- The Mismatch protocol, full text: whenever the work type changes — most commonly at plan
  approval (ExitPlanMode), and **at every round boundary in a multi-round Codex fix loop** (the
  three-consecutive-rounds-above-the-build-tier trigger below) — check both axes. (1) Is this
  Codex-delegable work about to be done inline anyway? (2) For the work that legitimately stays
  here, does the session / subagent model match the Claude column? On mismatch, STOP: delegate to
  Codex, ask the user to run `/model <correct-id>`, or spawn subagents with an explicit `model:`
  override. Never proceed inline on the wrong model after merely mentioning the mismatch (a
  one-line "you may want to switch" does not satisfy this rule), and never let a Codex fix loop
  carry a tier forward past that trigger without stopping to re-decide it.
- The effort columns differ because effort names do not buy the same thinking across models: on
  Claude Opus 5.5, `medium` matches or beats Claude Opus 5 at `high` on coding, and at any given
  level Opus 5.5 thinks more per turn, most of all at `xhigh`/`max` (Anthropic, *Prompting Claude
  Opus 5.5*, § Calibrate effort). To get less thinking, lower effort before adding prompt
  instructions — it works more reliably.

## Purpose and budget rule (full text)

Route work to the model that fits the task, and **prefer OpenAI models through the Codex
plugin over doing that work in Claude**. Claude's job is orchestration: decide, delegate,
verify, gate, commit. Applies to the **session model**, to **subagent `model:` overrides**
(Agent tool, Workflow `agent({model})`, `/loop`), and to the delegate-or-not decision
itself. Governs the model that *drives development* — separate from any project's eval/test
model (e.g. a repo's `EVAL_MODEL`, which decides how the agent-under-test runs; never
conflate them).

**The budget rule this exists to serve: spend the OpenAI allowance first; Claude tokens are
the reserve.** So the question at every step is not "could Claude do this?" — it is "is
there any reason this cannot be a Codex run?" Two kinds of Claude spend are in scope and
both count: work Claude *does*, and context Claude *holds* (every file read, grep result,
and pasted Codex output is re-sent on every subsequent turn — see § Keeping Claude's
context small).

## Codex-first (default)

Before a session's first background Codex dispatch or `codex-wait.sh`, Read `~/.claude/rules/codex-dispatch-protocol.md` (and `codex-job-status-integrity.md` on an `unknown`/`orphaned` status):
both are path-scoped, and a Bash or `/codex:rescue` dispatch opens no matching file.

| Step | How |
|------|-----|
| Check readiness | `~/.claude/scripts/codex.sh setup --json` → `"ready": true`; `~/.claude/scripts` is symlinked from this repo's `scripts/`. User-facing: `/codex:setup` |
| Delegate | `/codex:rescue [--model <slug>] [--effort <e>] <task>` — routes to the `codex:codex-rescue` subagent, which forwards exactly one `codex-companion.mjs task` call and returns its stdout verbatim |
| Long / open-ended | add `--background`; small and bounded → `--wait` (foreground) |
| Wait for a background job | **Not by polling.** `~/.claude/scripts/codex-wait.sh <job-id> --cwd <ws>` via Bash `run_in_background` — one wake when it exits. `/codex:status <job-id>` only on that wake; `unknown`/`orphaned` is an integrity incident (`codex-job-status-integrity.md`). Full protocol: `codex-dispatch-protocol.md` |
| Verify placement at dispatch | `codex.sh status --json --cwd <ws>` right after launch: `workspaceRoot` must be the intended dir and the pid alive; status is per-session and per-`--cwd`, so an empty table is not "done" |
| Follow-up on the same Codex thread | `--resume` — send only the delta instruction. New problem → `--fresh` |
| Read-only work — investigation, research, planning, codebase survey | say so explicitly; the subagent defaults to `--write`. `task` covers diagnosis/planning/research, not just fixes |
| Code review | `/codex:review` and `/codex:adversarial-review` are **user-typed only** (`disable-model-invocation: true`; the plugin's agent contract also bars its subagent from those subcommands, so an agent does not call `codex.sh review` / `codex.sh adversarial-review` via Bash). **The agent route for a review is `/codex:rescue` read-only** with the review contract in the task text (`branch-completion-review.md` Stage 2). That rests on an inference plus a user decision, not an explicit plugin instruction: the contract's `--write` rule presupposes review-shaped `task` requests, and `task` is not a barred subcommand. Background verdicts come back via `codex-wait.sh` + the job log, since `/codex:result` is user-typed only. Either route discharges the stage |
| Review on every stop | `/codex:setup --enable-review-gate` moves end-of-turn review to Codex permanently. It is per **workspace**, not global — **check, never assume**: `~/.claude/scripts/codex.sh setup --json` → `reviewGateEnabled` (the 2026-09-02 reading "on in every main checkout" was false for WebAppMonoRepo's main checkout on 2026-09-03; worktrees inherit the `false` default). It fires a Codex turn per Claude stop, including stops where the tree did not change — real spend, and it did catch a live reap-while-running bug — so leave it on where reviews earn their keep and `--disable-review-gate` where they don't. **Never stack it with the branch-completion adversary** (`branch-completion-review.md` § Cost and ordering): one review pass per branch — and **when the branch-completion trigger fires, Stage 2 wins**; the stop-gate is per-workspace, so a repo whose branches can trigger Stage 2 leaves it off permanently and states so. |

`$CODEX_PLUGIN` is **not exported by default**; `scripts/codex-plugin-root.sh` resolves
`~/.claude/plugins/cache/openai-codex/codex/<version>` (that path is `${CLAUDE_PLUGIN_ROOT}`
inside the plugin's own commands). A `module not found` error means the path is wrong, not
that Codex is unavailable. The rescue subagent is a
**forwarder, not an orchestrator** — it does not read the repo, poll, or summarize. Shaping
the prompt before the handoff is the orchestrator's job; the plugin's `gpt-5-4-prompting`
skill is the contract for that.

A Codex task inherits the session cwd as its sandbox root, so cross-repo delegation must pass
`--cwd <repo>`; a sandbox refusal is a plumbing error, not a reason to work inline.

## Tier selection beyond the equivalence table

Prefer the mechanical tier over the build tier when the task meets all three conditions: precise outcome,
small scope, and a clear check. It suits small UI adjustments from textual requirements,
mechanical refactors, known fixes, focused regression tests, and utilities with explicit inputs
and outputs. See `~/.claude/rules/native-codex-routing.md` § Focused coding selection for examples and a prompt.
Use the build tier for diagnosis or broader implementation and the architecture tier for design
or ambiguous requirements. If a mechanical-tier task reveals those needs, return the findings and
reassign it; do not keep expanding the fast task. Check live model availability before dispatch;
if `gpt-6-luna` is unavailable, use the build tier and report that substitution. Model availability
alone does not trigger the Claude fallback.

**An escalation is scoped to the round that needed it, not a new floor.** When a build-tier
round hits something that genuinely needs `gpt-6-astra` — a stuck root cause, a design
trade-off, an ambiguous requirement — escalate that one round explicitly and say why. The
*next* round re-selects tier from its own prompt, not from what the previous round used: if it
still reads as "fix this", "make it compile", "round N on the same bug", that is Build /
implementation and belongs back on `gpt-6-sol`. Rewording the prompt is not by itself
evidence the work type changed — "reconsider the approach to X" at the same tier, round after
round, is the same pattern wearing different words, and a genuine architecture question earns
its tier from what it's asking, not from how it's phrased. **Three consecutive rounds dispatched
above the Build / implementation row — pinned to `gpt-6-astra` or higher — for work the prompt
itself still frames as an ongoing fix** (not a fresh design question) trips the Mismatch protocol
trigger (`~/.claude/CLAUDE.md` § Model Routing). The anchor is the tier, not the trend: three rounds correctly held at
`gpt-6-sol` never trips this — that is the compliant case this whole rule protects — only
three rounds still *above* it while the prompt reads as a fix does. On trip, stop and decide
whether this needs one Astra round to diagnose and decide, then Sol to implement the decision,
or whether the repeated failure is itself the runaway signature in `codex-dispatch-protocol.md`
§4a that calls for cancel-and-rescope instead of another dispatch at the same tier. Incident
record: `docs/reference/rule-histories.md` § model-routing.

- **Leave `--model` unset** to inherit whatever `~/.codex/config.toml` sets; pass one only
  to move a tier deliberately. Same for `--effort` — set it when the equivalence-table row disagrees
  with the local default, not by reflex. The current local default is `gpt-6-sol` at
  `high` — the Build / implementation row, matching the majority of real dispatches — so
  an unset `--model` already lands there; pass `--model gpt-6-astra --effort xhigh`
  explicitly to step *up* a tier for genuine architecture/design work, or `--model gpt-6-luna --effort low`
  to step down for small, precise, easily-checked edits. (Flipped 2026-09-20, `cch-w50`:
  measurement over a 30-day, 374-job window found 69% of dispatches resolving to
  `gpt-6-astra` by unset-default alone, most of it routine build/fix work — a distinct,
  still-present failure mode from the cross-round escalation-sticking incident fixed in
  PR #65; see `docs/reference/rule-histories.md` § model-routing. The default moved from
  `gpt-5.6-terra` to `gpt-6-sol` on 2026-09-23 with the new release; the new tiers require
  codex-cli >= 0.155.0.)
- The companion's `--effort` accepts `none|minimal|low|medium|high|xhigh` only. `max` and
  `ultra` exist on the raw models (astra / sol / terra reach `ultra`, luna reaches `max`)
  but are not reachable through this path.
- Retired or superseded, never pin: `gpt-5.4` is gone from the roster entirely and
  `gpt-5.4-mini` carries an upgrade pointer to `gpt-5.6-luna`; `gpt-5.5` retires
  2026-10-14 and points to `gpt-5.6-sol`. The `gpt-5.6-sol`, `gpt-5.6-terra`, and
  `gpt-5.6-luna` models are labelled Older; `gpt-5.3-codex-spark` is absent from the live
  roster. On the Claude side `claude-fable-5` is superseded by `claude-fable-5-1`,
  `claude-sonnet-5` by `claude-sonnet-5-5` (released 2026-09-28), and
  `claude-opus-5`, `claude-opus-4-8`, and `claude-opus-4-7` are superseded for every
  Claude-column row.
- Model slugs move, and **`~/.codex/models_cache.json` is not reliably authoritative** — it
  carries its own `client_version`/`fetched_at` and can lag the installed `codex` CLI by
  several releases; on 2026-09-08 it was written by 0.147.0 against an installed 0.153.4 and
  omitted `gpt-6-astra` altogether, including as the user's own configured default. On
  2026-09-23 the cache (client_version 0.155.0) was ahead of the installed CLI (0.153.4),
  and the new slugs returned 400 until upgrading. Read it for `slug` / `description` /
  `visibility` / `upgrade` detail, but **check its `client_version` against `codex --version`
  and probe new slugs against the installed CLI before relying on them**; the mismatch can go
  either way. Treat the host's live roster as the source of truth when they disagree (the
  Codex app's own tool schemas enumerate it:
  `~/.codex/.codex-global-state.json` →
  `electron-persisted-atom-state.mcp-extension-sidebar-catalog`, whose `model` parameter
  description lists every slug and its supported reasoning efforts).

## What stays in Claude — and it is a short list

Only two things are genuinely irreducible: **the orchestrator's own turn** (Claude Code is
Claude; the driving loop cannot be moved) and **tools Codex cannot reach** — MCP servers,
browser / computer-use, Artifacts, iOS Simulator, Figma, and anything needing a permission
prompt. Everything else has a Codex route:

| Reflex | Route it to Codex instead |
|--------|---------------------------|
| `Explore` / `general-purpose` / `Plan` subagents for a survey or investigation | one read-only `/codex:rescue` run; ask for a written findings file, not a narrative |
| A `Workflow` / ultracode fan-out of Claude subagents | several `--background` Codex tasks — parallelism does not have to be Claude parallelism |
| `/code-review`, `/security-review`, a branch-completion review pass | `/codex:rescue` read-only with the review contract as the task text (the `/codex:review` slash commands are user-typed only — see § Codex-first); Claude subagent only on stated Codex unavailability |
| Reproducing a review finding, writing its negative control, hand-verifying the reviewer's claim | one Codex verification/fix task per round; the orchestrator's output per finding is ONE triage line (fix / bead / unverified) |
| `test-writer`, and code-quality's *analysis* half | a Codex `task`; Claude keeps only the pass/fail bookkeeping |
| Reading files to understand before editing | don't — hand the question to Codex with the paths, and let it do the reading |

Genuinely Claude-side bookkeeping — beads, branch discipline, git state, PR flow, and
**running** the `verify_cmd` gate — stays here, but it is nearly free: a `bd` call or a Bash
exit code costs a fraction of one file read. Keep it here for correctness (a gate is only
evidence when run by the party reporting it — `verification-integrity.md`), not because it
is expensive to move.

**Orchestration runs on the cheapest Claude that can hold the thread — `claude-sonnet-5-5`
by default.** Opus 5.5 is for a session where the *orchestration itself* is the hard part
(multi-repo state, a delicate migration). If the hard part is the engineering, that is a
Codex handoff (`gpt-6-sol` by default, `gpt-6-astra` for genuine design work), not an
Opus session. `claude-haiku-4-5` is enough for a forward-and-report loop.

## Keeping Claude's context small

The orchestrator's context is the second Claude budget and the easy one to blow: a 2,000-line
file read once is re-sent on every turn that follows.

- **Ask Codex for a file, not a monologue.** "Write findings to `docs/x-findings.md`; reply
  with ≤10 lines" beats pasting a full report into the transcript.
- **Use compact output contracts** (`gpt-5-4-prompting`: `<compact_output_contract>`) on
  every handoff. The default Codex answer is longer than Claude needs.
- **Fewer, larger handoffs.** Each round trip re-reads the accumulated thread; one task with
  a clear done-condition costs less than five clarifying ones.
- **Prefer `--background`** for anything long, and collect the result once.
- **Do not pre-read the repo to write the prompt.** Paths and a question are usually enough;
  Codex opens the files on its own tokens.

## Fallback to Claude

Fall back **only when Codex is genuinely unavailable**: vendor `openai` is disabled in the
vendor switch (`~/.claude/CLAUDE.md` § Vendor switch — no readiness check needed or wanted), a successful
`setup --json` reports `ready: false`, or login is missing or fails (`codex login` / `/codex:setup`). A readiness
check that **ERRORS** (module not found, path wrong, resolver failure) is **not** evidence that
Codex is unavailable — resolve the path and retry before ever falling back. Only an actual
`"ready": false` from a successful setup run, or a missing/failed login, counts as unavailable.
State which one
applies in one line, then do the work inline on that row's Claude model — except when the vendor
is disabled by config, which is routed silently (`~/.claude/CLAUDE.md` § Vendor switch). Never fall back
silently on an actual `ready: false` or login failure, and never because delegating merely feels slower. "It's only a one-liner" is not a
fallback reason either — under the budget rule the handoff is the default even for small
edits; the only edits worth keeping inline are ones already open in Claude's context where
the round trip would cost more Claude tokens than the edit itself.
