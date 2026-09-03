# Claude Code Configuration

**IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning.**
Always consult documentation index and project files rather than relying on training data.

## Documentation Index

```
[Rules]|root: ~/.claude/rules/ → symlinked from ~/projects/cc-harness/rules/ (single source of truth; edits follow cc-harness branch+commit-agent pipeline). Project rules live in each project's own .claude/rules/. Incidents behind each rule: cc-harness docs/reference/ (never loaded)
|Always loaded:
|agent-enforcement.md: Agent pipeline is MANDATORY — never manual git add/commit/push; code-quality agent is skipped when `quality_gate_pattern` is `(none)` — `verify_cmd` → `VERIFY RESULT:` is the whole gate
|pipeline-contract.md: Gate once per working tree — `VERIFY RESULT: PASS sha= tree=` / `CODE QUALITY RESULT:` formats, consume don't re-run, small-diff fast path
|branch-discipline.md: Feature-branch-first — never commit on main/master, branch BEFORE first edit
|testing-guidelines.md: Universal test quality (Q1-Q8), test types, session close protocol
|verification-integrity.md: Never read a gate's exit code through a pipe (`cmd | tail` returns tail's status); a green must be able to be red
|codex-job-status-integrity.md: `unknown`/`orphaned` on a backgrounded Codex job is an integrity incident, not a pending result — inspect log/git diff/threadId before claiming completion or rerunning
|codex-dispatch-protocol.md: The wrapper is not the job — liveness = worker PID + log under the per-workspace state dir; status is per-session/per-`--cwd`; verify placement at dispatch; wait via `codex-wait.sh` PID bridge (one wake, never polling); written cancellation criteria; prompt-side completion contracts; broker housekeeping
|agent-purpose-statements.md: Purpose statement pattern for agents, skills, and manual orchestration
|Path-scoped (load only on a matching file; Read directly if needed elsewhere):
|claude-md-project-templates.md: NEVER lists + autonomy tiers templates; `verify_cmd`; project files reference global rules and carry parameters only — CLAUDE.md, .claude/rules
|memory-discipline.md: Memory exclusions + recall-time verification — memory dirs, MEMORY.md
|agent-isolation.md: Worktree isolation for parallel pipelines — .claude/{skills,agents,rules}, *worktree*
|parallel-authoring.md: Fan out sub-agents for independent additive work; gate once — same scope
|branch-completion-review.md: Adversarial GO/NO-GO, triggered by RISK CLASS not diff size (lifetime/cancellation · persistence/format · integrity of a check OR the policy behind it, incl. that rule itself · trusted external surface · real-time/hardware); trigger must be machine-checked where a gate exists; refactor pass demoted to optional, triggered by fan-out authoring; adversary runs on Codex via `/codex:rescue` read-only (the `/codex:adversarial-review` slash command is user-typed only; never `codex.sh adversarial-review` from an agent), Claude subagent as fallback; ONE review pass per branch — when the branch-completion trigger fires, Stage 2 wins and the stop-gate stays off in that workspace; project files reference, never restate — source trees (src/app/apps/packages/lib/Sources), .claude/{skills,rules}, .github
|peer-session-coordination.md: Message peer sessions directly, scoped by what is shared (same repo → full protocol; same machine → resource notices only; shared dependency → one collision check); notices not essays; never route through the user — source trees, .claude/{skills,agents,rules}, *worktree*
|windowed-gate-serialization.md: Serialize window-opening gates across parallel agents — GUI/UI-test paths
|computer-control-release.md: Hand back interactive control when active use ends — GUI paths, .claude/{skills,agents}

[Scripts]|root: .claude/scripts/
|git-snapshot: Structured git state (branch, status, log, diff) as JSON — replaces 2-3 git Bash calls
|routing-report: Measures Codex-first delegation from transcript occurrence counts; run `bash scripts/routing-report.sh [--days N|--since YYYY-MM-DD] [--json]`
|codex-wait.sh <job-id> [--cwd <ws>]: PID bridge for a background Codex job — run via Bash `run_in_background`; exits 0 done / 1 failed / 2 orphaned / 3 wall cap
|codex-jobs.sh [--cwd <ws>] [--all-workspaces] [--active]: Codex jobs across sessions/worktrees (bypasses the companion's session filter)
|codex-brokers.sh [--reap-stale] [--restart-idle]: list/kill Codex app-server brokers by explicit PID — after a config.toml edit or when brokers point at dead cwds

[Hooks]|root: ~/.claude/hooks/ → symlinked from ~/projects/cc-harness/hooks/ (Model Routing enforcement; run `bash hooks/selftest.sh` after changes)

[Beads]|binary: bd (in PATH) — see Task Management below
|session-start: run bd prime if .beads/ exists (prints the full command reference)
|persistence: bd close writes immediately — no flush at session end (`bd sync` no longer exists; bd backup for snapshots, bd export for JSONL migration)

[Skills]|root: ~/.claude/skills/ (SKILL.md format; legacy commands/ migrated to skills/)
|/optimize-video: Optimize a video file/dir for web delivery (delegates to video-optimize agent)
|/agents-md-transform: Execute AGENTS.md pattern transformation
|/find-skills: Discover installable agent skills
|loadout-awareness: Proactive — suggests `loadout scan` when deps/frameworks change (not user-triggered)

[Hub]|binary: loadout (pnpm global link)
|hub dir: ~/.dotfiles/claude/
|config: ~/.dotfiles/claude/hub.yaml
|manage: loadout link/unlink/sync/status
|scan: loadout scan (suggest after adding new deps/frameworks)

[Codex]|plugin: openai-codex/codex (OpenAI models) — see Model Routing below
|root: ~/.claude/plugins/cache/openai-codex/codex/<version>/ (= ${CLAUDE_PLUGIN_ROOT} inside the plugin)
|delegate: /codex:rescue [--model <slug>] [--effort none|minimal|low|medium|high|xhigh] [--background|--wait] [--resume|--fresh] <task>
|readiness: /codex:setup, or `node "$CODEX_PLUGIN/scripts/codex-companion.mjs" setup --json` → "ready": true
|models: authoritative local list in ~/.codex/models_cache.json; user default in ~/.codex/config.toml
```

## Code Reuse

Check the code index before writing. **REUSE** > **EXTEND** > **CREATE** — and say which: "I'm [reusing/extending/creating] because [reason]." Similarity >80% → use the existing thing; 60-80% → ask the user; 40-60% → reference its patterns.

## Testing (TDD)

Write tests BEFORE implementing; test user behavior, not implementation; co-locate tests next to source files. Full patterns: `testing-guidelines.md`.

## Git commit identity

Every commit created, amended, or rewritten by Codex or ChatGPT must preserve the originating user's configured Git author and committer identity. The current originator is `gpxl`. Do not change that identity without the user's explicit instruction.

Never add Codex, ChatGPT, OpenAI, a model name, or any other agent/vendor identity as an author, committer, or `Co-authored-by` trailer. Commit messages and pull-request titles/bodies must likewise not attribute work to an agent or vendor unless the user explicitly asks for that attribution.

## Repository branch and PR conventions

Before creating, renaming, pushing, or opening a pull request in **every** project, inspect the project's instructions, its PR template/configuration, current remote branch names, and recent merged commits on the intended integration branch. Those are the project's source of truth; do not impose generic agent conventions that conflict with them.

- Branch names must not contain a user, agent, vendor, or model namespace unless the user explicitly requests it. Follow the repository's current type, ticket, and concise kebab-case subject pattern. For example, use `feat/MAR-2823-lookout-page-updates` when that is the nearest current precedent. Prefer the nearest current precedent when history is mixed.
- Use the normal integration branch as the PR base unless the user specifies another. Fetch first and review `origin/<base>...HEAD`, never a potentially stale local base branch.
- Match the title convention established by recent merged PRs. Where the project uses Conventional Commits, use `type(scope): subject` (under 70 characters unless the project specifies otherwise). Include a ticket only when local precedent or the user's linked work item calls for it.
- Use the repository's PR template exactly: retain its headings, replace every applicable placeholder, remove empty placeholder bullets, and select the correct type checkbox or equivalent field. Do not add generic agent attribution, boilerplate checklists, or invented test results.
- Make the body reviewable from the diff: **What** states the delivered outcome, **Why** identifies the user/problem context, and **Changes** separates material or breaking behavior from supporting fixes, refactors, or cleanup. Describe externally meaningful behavior and scope, not just filenames. Include verification only when it is non-obvious or required by the repository.
- Before push, self-review the actual diff against the resolved base and the project's review instructions. Ask the user only when project precedent and the user's requested naming or PR content materially conflict.

## Workflow

| Phase | Action |
|-------|--------|
| Session start | Run `bd prime` if `.beads/` exists in project |
| Plan | `bd create` issue BEFORE writing code |
| Claim | `bd update <id> --status=in_progress` when starting |
| **Branch** | **If on `main`/`master`/`trunk`/`develop`, create a feature branch that follows the repository's current naming convention off `origin/<integration>` BEFORE first edit (for example, `git checkout -b feat/MAR-2823-<desc> origin/main`). Never commit on the integration branch. See `branch-discipline.md`.** |
| **Delegate** | **Codex-first**: hand implementation, debugging, and design work to OpenAI models via `/codex:rescue` unless it is orchestration, a gate, or tool-bound work. See `## Model Routing`. |
| TDD | Write tests, then implement |
| Test | All tests pass |
| Lint | Run project linter — code NOT complete until lint passes |
| Commit | **Delegate to commit agent** — NEVER run `git add`/`git commit`/`git push` manually (including for doc-only changes) |
| Complete | `bd close <id>` (writes immediately — no explicit flush needed) |

### Task Management (CRITICAL)

**Use `bd` (beads) for ALL task tracking in ALL projects. No exceptions.**

| Rule | Detail |
|------|--------|
| **REQUIRED** | Create before code, claim on start, close when done (see Workflow above) |
| **PROHIBITED** | TodoWrite, TaskCreate, or markdown checklists for task tracking |
| Session close | `bd close` persists immediately — no flush command is needed |
| Find work | `bd ready` — lists unblocked open issues |
| New project | `bd init --stealth --prefix <abbrev>` if no `.beads/` exists |

### Agent-Gated Commits (CRITICAL)

**When a project has agents configured (Agent Config in CLAUDE.md), ALL commits MUST go through the agent pipeline** (code-quality → on PASS → commit agent; on FAIL → test-writer → re-run code-quality; when `quality_gate_pattern` is `(none)` the code-quality step is skipped and `verify_cmd` → `VERIFY RESULT:` is the gate). The commit agent handles staging, committing, pushing, and opening PRs. Never bypass it. Full pipeline + exemptions: `agent-enforcement.md`.

| Rule | Detail |
|------|--------|
| **TRIGGER** | Any user request to "commit", "push", "save", "ship it", "yes" (to commit prompt) |
| **EXCEPTION** | Projects without Agent Config in CLAUDE.md use standard git workflow |
| **GATE ONCE** | lint+test+build runs once per working tree; later steps consume the recorded `VERIFY RESULT:` / `CODE QUALITY RESULT:` line instead of re-running (`pipeline-contract.md`) |
| **pr-monitor** | Skipped when Agent Config `ci` is `none` — it polls CI checks that don't exist; merge on the recorded verify instead. `release` likewise skipped when `version_strategy` is `(none)` |

### Parallel Agent Runs (CRITICAL)

When multiple sessions / routines may run against the same repo simultaneously, orchestrator skills that edit code MUST wrap their pipeline in a `git worktree` (opt in via `worktree_root` + `isolation_required_for` in the project's Agent Config). Lifecycle: `agent-isolation.md`.

### Planning vs Implementation (CRITICAL)

Planning and implementation are **always separate phases** requiring explicit commands.

| Phase | Trigger | Action |
|-------|---------|--------|
| **Plan only** | "plan", "design", "create tasks" | Create beads issues → STOP. Do NOT write code. |
| **Implement** | "implement", "start", "work on", "build" | Pick up a beads issue → write code |

When asked to **plan**: create all `bd create` issues, set dependencies with `bd dep add`, then say "Plan complete — run `bd ready` to start implementing."

**NEVER begin writing code during a planning session unless explicitly told to implement.**

## Security

Never expose, log, or commit secrets, `.env` files, credentials, or tokens. Validate at system boundaries (user input, external APIs) and use least privilege everywhere. Project-specific auth patterns live in each project's `rules/`.

## Communication

Explain decisions: "I chose to extend [X] because [Y]" / "I imported [X] instead of recreating"

When orchestrating agents manually, include a purpose statement: "This [context] — focus on [emphasis]." See `agent-purpose-statements.md`.

## Model Routing

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

### Codex-first (default)

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
| Review on every stop | `/codex:setup --enable-review-gate` moves end-of-turn review to Codex permanently. It is per **workspace**, not global — **check, never assume**: `~/.claude/scripts/codex.sh setup --json` → `reviewGateEnabled` (the 2026-09-02 reading "on in every main checkout" was false for rudderstack's main checkout on 2026-09-03; worktrees inherit the `false` default). It fires a Codex turn per Claude stop, including stops where the tree did not change — real spend, and it did catch a live reap-while-running bug — so leave it on where reviews earn their keep and `--disable-review-gate` where they don't. **Never stack it with the branch-completion adversary** (`branch-completion-review.md` § Cost and ordering): one review pass per branch — and **when the branch-completion trigger fires, Stage 2 wins**; the stop-gate is per-workspace, so a repo whose branches can trigger Stage 2 leaves it off permanently and states so. |

`$CODEX_PLUGIN` is **not exported by default**; `scripts/codex-plugin-root.sh` resolves
`~/.claude/plugins/cache/openai-codex/codex/<version>` (that path is `${CLAUDE_PLUGIN_ROOT}`
inside the plugin's own commands). A `module not found` error means the path is wrong, not
that Codex is unavailable. The rescue subagent is a
**forwarder, not an orchestrator** — it does not read the repo, poll, or summarize. Shaping
the prompt before the handoff is the orchestrator's job; the plugin's `gpt-5-4-prompting`
skill is the contract for that.

A Codex task inherits the session cwd as its sandbox root, so cross-repo delegation must pass
`--cwd <repo>`; a sandbox refusal is a plumbing error, not a reason to work inline.

### Equivalence table

| Work type | Codex model — use this | Claude equivalent — fallback only | Effort |
|-----------|------------------------|-----------------------------------|--------|
| **Architecture / design** — ADRs, system design, novel abstractions, hard trade-off reasoning | `gpt-5.6-sol` — frontier agentic model, highest ceiling | `claude-fable-5` → `claude-opus-5` | `xhigh` |
| **Build / implementation** — coding, refactors, tests, eval scenarios, debugging | `gpt-5.6-terra` — balanced everyday coder; the local Codex default | `claude-opus-5` | `high` |
| **Probe / exploration** — codebase surveys, read-only investigation, light passes | `gpt-5.6-luna` — fast + affordable | `claude-sonnet-5` | `medium` |
| **Mechanical** — trivial rewrites, formatting-scale edits, ultra-fast passes | `gpt-5.3-codex-spark` (`--model spark`) | `claude-sonnet-5` | `low` |

- **Leave `--model` unset** to inherit whatever `~/.codex/config.toml` sets; pass one only
  to move a tier deliberately. Same for `--effort` — set it when the row above disagrees
  with the local default, not by reflex.
- The companion's `--effort` accepts `none|minimal|low|medium|high|xhigh` only. `max` and
  `ultra` exist on some raw Codex models but are not reachable through this path.
- `gpt-5.4` / `gpt-5.4-mini` are deprecated; Codex upgrades them to `gpt-5.6-terra` /
  `gpt-5.6-luna`. Never pin them. **Older Opus generations** (`claude-opus-4-8`,
  `claude-opus-4-7`) are likewise superseded for every Claude-column row.
- Model slugs move. The authoritative local list is `~/.codex/models_cache.json`
  (`slug`, `description`, `visibility`, `upgrade`) — read it before pinning a slug this
  table doesn't name.

### What stays in Claude — and it is a short list

Only two things are genuinely irreducible: **the orchestrator's own turn** (Claude Code is
Claude; the driving loop cannot be moved) and **tools Codex cannot reach** — MCP servers,
browser / computer-use, Artifacts, iOS Simulator, Figma, and anything needing a permission
prompt. Everything else has a Codex route:

| Reflex | Route it to Codex instead |
|--------|---------------------------|
| `Explore` / `general-purpose` / `Plan` subagents for a survey or investigation | one read-only `/codex:rescue` run; ask for a written findings file, not a narrative |
| A `Workflow` / ultracode fan-out of Claude subagents | several `--background` Codex tasks — parallelism does not have to be Claude parallelism |
| `/code-review`, `/security-review`, a branch-completion review pass | `/codex:rescue` read-only with the review contract as the task text (the `/codex:review` slash commands are user-typed only — see § Codex-first); Claude subagent only on stated Codex unavailability |
| `test-writer`, and code-quality's *analysis* half | a Codex `task`; Claude keeps only the pass/fail bookkeeping |
| Reading files to understand before editing | don't — hand the question to Codex with the paths, and let it do the reading |

Genuinely Claude-side bookkeeping — beads, branch discipline, git state, PR flow, and
**running** the `verify_cmd` gate — stays here, but it is nearly free: a `bd` call or a Bash
exit code costs a fraction of one file read. Keep it here for correctness (a gate is only
evidence when run by the party reporting it — `verification-integrity.md`), not because it
is expensive to move.

**Orchestration runs on the cheapest Claude that can hold the thread — `claude-sonnet-5`
by default.** Opus 5 is for a session where the *orchestration itself* is the hard part
(multi-repo state, a delicate migration). If the hard part is the engineering, that is a
`gpt-5.6-sol` handoff, not an Opus session. `claude-haiku-4-5-20251001` is enough for a
forward-and-report loop.

### Keeping Claude's context small

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

### Fallback to Claude

Fall back **only when Codex is genuinely unavailable**: a successful `setup --json` reports
`ready: false`, or login is missing or fails (`codex login` / `/codex:setup`). A readiness
check that **ERRORS** (module not found, path wrong, resolver failure) is **not** evidence that
Codex is unavailable — resolve the path and retry before ever falling back. Only an actual
`"ready": false` from a successful setup run, or a missing/failed login, counts as unavailable.
State which one
applies in one line, then do the work inline on that row's Claude model. Never fall back
silently, and never because delegating merely feels slower. "It's only a one-liner" is not a
fallback reason either — under the budget rule the handoff is the default even for small
edits; the only edits worth keeping inline are ones already open in Claude's context where
the round trip would cost more Claude tokens than the edit itself.

- **Mismatch protocol (GATE, not advisory):** whenever the work type changes — most
  commonly at plan approval (ExitPlanMode) — check both axes. (1) Is this Codex-delegable
  work about to be done inline anyway? (2) For the work that legitimately stays here, does
  the session / subagent model match the Claude column? On mismatch, STOP: delegate to
  Codex, ask the user to run `/model <correct-id>`, or spawn subagents with an explicit
  `model:` override. Never proceed inline on the wrong model after merely mentioning the
  mismatch (a one-line "you may want to switch" does not satisfy this rule).

## CLAUDE.md Optimization

**Auto-apply when user says:** "optimize Claude config", "update config", "improve CLAUDE.md", "set up Claude", "create CLAUDE.md".

Required elements: retrieval-led instruction at top; compressed pipe-delimited index (`[Category]|root: path/`); tables over lists; security inline with details in `rules/`; skills for user-triggered work only. Templates and the fill-in prompts: `claude-md-project-templates.md`.
