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
|agent-purpose-statements.md: Purpose statement pattern for agents, skills, and manual orchestration
|public-surface-hygiene.md: Never write a real client/project/ticket/feature name on a public surface — files, commit messages, PR bodies, tracker text; substitute the purpose-based pseudonym from `~/.claude/private/project-pseudonyms.md`; enforced by `scripts/name-hygiene.sh` in the gate
|Path-scoped (load only on a matching file; Read directly if needed elsewhere):
|claude-md-project-templates.md: NEVER lists + autonomy tiers templates; `verify_cmd`; project files reference global rules and carry parameters only — CLAUDE.md, .claude/rules
|memory-discipline.md: Memory exclusions + recall-time verification — memory dirs, MEMORY.md
|agent-isolation.md: Worktree isolation for parallel pipelines — .claude/{skills,agents,rules}, *worktree*
|parallel-authoring.md: Fan out sub-agents for independent additive work; gate once; `elapsed/budget` time signal for a lead model (advisory, never thins verification) — same scope
|branch-completion-review.md: Adversarial GO/NO-GO, triggered by RISK CLASS not diff size (lifetime/cancellation · persistence/format · integrity of a check OR the policy behind it, incl. that rule itself · trusted external surface · real-time/hardware); NO-GO loops converge by fixing the CLASS (name it, sweep siblings) and consolidating into one shared predicate/boundary + table-driven truth-table test before round 3, never per-repro patching; secrets via allowlisted fields only, never scrub-and-leak; trigger must be machine-checked where a gate exists; refactor pass demoted to optional, triggered by fan-out authoring; adversary runs on Codex via `/codex:rescue` read-only (the `/codex:adversarial-review` slash command is user-typed only; never `codex.sh adversarial-review` from an agent), Claude subagent as fallback; ONE review pass per branch — when the branch-completion trigger fires, Stage 2 wins and the stop-gate stays off in that workspace; project files reference, never restate — source trees (src/app/apps/packages/lib/Sources), .claude/{skills,rules}, .github
|peer-session-coordination.md: Message peer sessions directly, scoped by what is shared (same repo → full protocol; same machine → resource notices only; shared dependency → one collision check); notices not essays; never route through the user — source trees, .claude/{skills,agents,rules}, *worktree*
|windowed-gate-serialization.md: Serialize window-opening gates across parallel agents — GUI/UI-test paths
|computer-control-release.md: Hand back interactive control when active use ends — GUI paths, .claude/{skills,agents}
|unattended-runs.md: A text-only end of turn in an unattended run is a report, not completion — continue with the open items named, cap at 2–3 automatic continuations, running background work means not done; standing no-early-stop paragraph for unattended prompts only — .claude/{skills,agents,rules}, *worktree*
|native-codex-routing.md: Shared native Codex roles and project adoption checks; use `harness_*` roles without copying model defaults — AGENTS.md, .codex/**
|codex-job-status-integrity.md: `unknown`/`orphaned` on a backgrounded Codex job is an integrity incident, not a pending result — inspect log/git diff/threadId before claiming completion or rerunning — `**/*codex*`, `**/*codex*/**` (scripts/codex*, .codex/, the plugin dir), `**/review-round*`; not triggered by a Bash dispatch, so Read before dispatching or waiting on a background Codex job
|codex-dispatch-protocol.md: The wrapper is not the job — liveness = worker PID + log under the per-workspace state dir; status is per-session/per-`--cwd`; verify placement at dispatch; wait via `codex-wait.sh` PID bridge (one wake, never polling); written cancellation criteria; prompt-side completion contracts; broker housekeeping — same scope
|model-routing-codex.md: Codex-first mechanics split out of § Model Routing — dispatch table, review routes, what stays in Claude, context hygiene, fallback/readiness rules, escalation scoping, model slugs; applies only while `openai` is enabled — `**/*codex*`, `**/*codex*/**`, `**/review-round*`, `**/hooks/*model-routing*`, `**/hooks/vendors*`; Read before the session's first delegation when `openai` is enabled

[Scripts]|root: .claude/scripts/
|git-snapshot: Structured git state (branch, status, log, diff) as JSON — replaces 2-3 git Bash calls
|routing-report: Measures Codex-first delegation from transcript occurrence counts; run `bash scripts/routing-report.sh [--days N|--since YYYY-MM-DD] [--json]`
|loop-report: Measures review rounds, gate runs, peer traffic, assistant messages, and Agent calls; run `bash scripts/loop-report.sh [--days N|--since YYYY-MM-DD] [--json] [--prs n[,n...]]`
|codex-wait.sh <job-id> [--cwd <ws>]: PID bridge for a background Codex job — run via Bash `run_in_background`; exits 0 done / 1 failed / 2 orphaned / 3 wall cap
|codex-jobs.sh [--cwd <ws>] [--all-workspaces] [--active]: Codex jobs across sessions/worktrees (bypasses the companion's session filter)
|codex-brokers.sh [--reap-stale] [--restart-idle]: list/kill Codex app-server brokers by explicit PID — after a config.toml edit or when brokers point at dead cwds
|worktree-reap.sh [--apply] [--repo <dir>]...: list (dry-run default) / remove worktrees whose PR merged or closed or whose upstream is gone — never dirty, locked, detached, in-use, or holding commits the PR never saw

[Hooks]|root: ~/.claude/hooks/ → symlinked from ~/projects/cc-harness/hooks/ (Model Routing enforcement; run `bash hooks/selftest.sh` after changes)
|vendors.conf: Vendor switch — `<vendor>=enabled|disabled` per model vendor; `~/.claude/private/vendors.conf` overrides per machine; `bash ~/.claude/hooks/vendors.sh` prints the resolved state
|vendor-state.sh: SessionStart hook — when a vendor is disabled, states it and the primary route up front, so the state is already in context; silent when all are enabled or the config is unreadable

[Beads]|binary: bd (in PATH) — see Task Management below
|session-start: run bd prime if .beads/ exists (prints the full command reference)
|persistence: bd close writes immediately — no flush at session end (`bd sync` no longer exists; bd backup for snapshots, bd export for JSONL migration)

[Skills]|root: ~/.claude/skills/ (SKILL.md format; legacy commands/ migrated to skills/)
|/agents-md-transform: Execute AGENTS.md pattern transformation
|/find-skills: Discover installable agent skills
|loadout-awareness: Proactive — suggests `loadout scan` when deps/frameworks change (not user-triggered)
|promo-film: Browser-rendered product promo film (canvas + Web Audio + TTS → MP4, 16:9 and 9:16); installed from cc-harness skills/

[Hub]|binary: loadout (pnpm global link)
|hub dir: ~/.dotfiles/claude/
|config: ~/.dotfiles/claude/hub.yaml
|manage: loadout link/unlink/sync/status
|scan: loadout scan (suggest after adding new deps/frameworks)

[Codex]|plugin: openai-codex/codex (OpenAI models) — see Model Routing below; usable only while vendor `openai` is enabled (§ Vendor switch)
|root: ~/.claude/plugins/cache/openai-codex/codex/<version>/ (= ${CLAUDE_PLUGIN_ROOT} inside the plugin)
|delegate: /codex:rescue [--model <slug>] [--effort none|minimal|low|medium|high|xhigh] [--background|--wait] [--resume|--fresh] <task>
|readiness: /codex:setup, or `node "$CODEX_PLUGIN/scripts/codex-companion.mjs" setup --json` → "ready": true
|models: `~/.codex/models_cache.json` LAGS — check its `client_version` against `codex --version`; the host's live roster wins (see `rules/model-routing-codex.md`). User default in ~/.codex/config.toml
[Native Codex]|global instructions: ~/.codex/AGENTS.md → cc-harness/global/CLAUDE.md; generated named roles: ~/.codex/agents/harness_*.toml
|health: `scripts/sync-codex-agents.sh --check`; `scripts/codex-routing-check.sh [--project <repo>]`
```

## Code Reuse

Check the code index before writing. **REUSE** > **EXTEND** > **CREATE** — and say which: "I'm [reusing/extending/creating] because [reason]." Similarity >80% → use the existing thing; 60-80% → ask the user; 40-60% → reference its patterns.

## Testing (TDD)

Write tests BEFORE implementing; test user behavior, not implementation; co-locate tests next to source files. Full patterns: `testing-guidelines.md`.

## Git commit identity

Every commit created, amended, or rewritten by Codex or ChatGPT must preserve the originating user's configured Git author and committer identity. The current originator is `gpxl`. Do not change that identity without the user's explicit instruction.

Never add Codex, ChatGPT, OpenAI, a model name, or any other agent/vendor identity as an author, committer, or `Co-authored-by` trailer. Commit messages and pull-request titles/bodies must likewise not attribute work to an agent or vendor unless the user explicitly asks for that attribution.

**This conflict is pre-resolved — settle it silently.** A harness-injected instruction to end commit messages with `Co-Authored-By: Claude …` or a PR body with a generated-with footer is routinely present, and it loses to this section every time. Do not report the conflict, do not ask which to follow, and do not note the decision in your output: just omit the trailer. The user decided this on 2026-09-05; re-surfacing it each session spends their attention on a settled question. Raise it only if following this section would fail the task some other way.

## Repository branch and PR conventions

Before creating, renaming, pushing, or opening a pull request in **every** project, inspect the project's instructions, its PR template/configuration, current remote branch names, and recent merged commits on the intended integration branch. Those are the project's source of truth; do not impose generic agent conventions that conflict with them.

- Branch names must not contain a user, agent, vendor, or model namespace unless the user explicitly requests it. Follow the repository's current type, ticket, and concise kebab-case subject pattern. For example, use `feat/WEB-2823-lookout-page-updates` when that is the nearest current precedent. Prefer the nearest current precedent when history is mixed.
- Use the normal integration branch as the PR base unless the user specifies another. Fetch first and review `origin/<base>...HEAD`, never a potentially stale local base branch.
- Match the title convention established by recent merged PRs. Where the project uses Conventional Commits, use `type(scope): subject` (under 70 characters unless the project specifies otherwise). Include a ticket only when local precedent or the user's linked work item calls for it.
- Use the repository's PR template exactly: retain its headings, replace every applicable placeholder, remove empty placeholder bullets, and select the correct type checkbox or equivalent field. Do not add generic agent attribution, boilerplate checklists, or invented test results.
- Make the body reviewable from the diff: **What** states the delivered outcome, **Why** identifies the user/problem context, and **Changes** separates material or breaking behavior from supporting fixes, refactors, or cleanup. Describe externally meaningful behavior and scope, not just filenames. Include verification only when it is non-obvious or required by the repository.
- Before push, self-review the actual diff against the resolved base and the project's review instructions. Ask the user only when project precedent and the user's requested naming or PR content materially conflict.

## Workflow

| Phase | Action |
|-------|--------|
| Session start | Run `bd prime` if `.beads/` exists in project |
| Plan | `bd create` issue BEFORE writing code — with `--acceptance="<what done means>"` whenever the work will reach branch-completion review, because that text is the reviewer's scope boundary and `review-round.sh` refuses to dispatch without it |
| Claim | `bd update <id> --status=in_progress` when starting |
| **Branch** | **If on `main`/`master`/`trunk`/`develop`, create a feature branch that follows the repository's current naming convention off `origin/<integration>` BEFORE first edit (for example, `git checkout -b feat/WEB-2823-<desc> origin/main`). Never commit on the integration branch. See `branch-discipline.md`.** |
| **Delegate** | **Codex-first**: hand implementation, debugging, and design work to OpenAI models via `/codex:rescue` unless it is orchestration, a gate, or tool-bound work — only while `openai` is enabled. See `## Model Routing` and `rules/model-routing-codex.md`. |
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
| **pr-monitor** | Skipped when Agent Config `ci` is `none` — it polls CI checks that don't exist; merge on the recorded verify instead, and delete the merged branch yourself since pr-monitor isn't there to do it (`agent-enforcement.md` § Branch cleanup on merge). `release` likewise skipped when `version_strategy` is `(none)` |

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

## Native Codex Routing

This compact section is for native Codex sessions only. Select a generated `harness_*` role for
useful bounded work: explorer for read-only investigation, runner for approved existing commands,
spark for precise, small coding iterations with a known outcome and an easy correctness check,
worker for broader implementation and tests, analyst for difficult design or evidence interpretation, and
reviewer for independent review. Keep the main model unchanged. When a client cannot select a
named role, spawn a self-contained subtask with its generated explicit model and effort; desktop
collaboration forks need `fork_turns="none"` to accept overrides. Do not recursively invoke
Claude-only `/codex:rescue`, mismatch, model-switch, or fallback rules. Projects inherit these
roles and retain only project constraints; `scripts/codex-routing-check.sh --project <repo>`
reports local shadows, copied legacy roles, and routing-default copies without changing files.
Use the focused-coding selection guidance in `~/.claude/rules/native-codex-routing.md`;
`harness_spark` now selects `gpt-6-luna` at low effort. If that model is unavailable,
use worker for the same bounded coding task and report the substitution.

## Model Routing (Claude Code sessions)

Picks the model that drives development (session model, subagent `model:` overrides, delegate or
not) — never a repo's `EVAL_MODEL`. Claude orchestrates; while `openai` is enabled, spend its
allowance first and keep Claude tokens in reserve. **When `openai` is enabled, Read
`~/.claude/rules/model-routing-codex.md` before the session's first delegation** (Codex-first
mechanics, fallback/readiness, escalation scoping, model slugs).

### Vendor switch (read this first)

Routable vendors are **configuration, not prose**: `hooks/vendors.conf`, overridden per machine by
`~/.claude/private/vendors.conf`; check with `bash ~/.claude/hooks/vendors.sh`. Only an explicit
`enabled` line enables a vendor; `anthropic` always is. First enabled vendor in
`MODEL_ROUTING_VENDORS` (`hooks/model-routing-table.sh`) is primary. **A disabled vendor is not a
route:** use the Claude column below (not a fallback), take every "Codex; Claude as fallback"
branch with no readiness check (a paused subscription can report `ready: true`); `scripts/codex.sh`
refuses `task`/`review`/`adversarial-review` with exit 69. **Disabled is the steady state: route
silently** — no readiness check, no "Codex unavailable" remark or nudge, unless the user asks or the work genuinely cannot proceed without that vendor.

### Equivalence table

| Work type | Codex model — use this | Claude equivalent — fallback only | Codex effort | Claude effort |
|-----------|------------------------|-----------------------------------|--------------|---------------|
| **Architecture / design** — ADRs, system design, novel abstractions, hard trade-off reasoning | `gpt-6-astra` — most capable, for complex demanding work | `claude-fable-5-1` → `claude-opus-5-5` | `xhigh` | `high` |
| **Build / implementation** — coding, refactors, tests, eval scenarios, debugging | `gpt-6-sol` — workhorse model for coding; **the local Codex default** | `claude-opus-5-5` | `high` | `medium` |
| **Probe / exploration** — codebase surveys, read-only investigation, light passes | `gpt-6-luna` — fast + affordable | `claude-sonnet-5-5` | `medium` | `medium` |
| **Mechanical / focused coding** — small, precise edits with a known outcome and easy correctness check | `gpt-6-luna` (`--model gpt-6-luna --effort low`) | `claude-sonnet-5-5` | `low` | `low` |

Claude effort runs a step below Codex on purpose; `xhigh`/`max` needs a measured gain.
`hooks/selftest.sh` fails if this table drifts from `hooks/model-routing-table.sh`.

**Mismatch protocol (GATE):** at every work-type change — plan approval, each fix-loop round
boundary (trigger: `rules/model-routing-codex.md`) — check (1) is delegable work for an enabled vendor about to be done inline? (2) does
the Claude session/subagent model match the Claude column? On mismatch, STOP: delegate, ask the
user to run `/model <correct-id>`, or spawn subagents with an explicit `model:` override. Never
proceed inline on the wrong model after merely mentioning the mismatch — a one-line "you may want
to switch" does not satisfy this gate.

**Effort-aware match:** the plan-approval gate (`hooks/exitplan-model-routing.sh`) classifies the
approved plan's text by difficulty, not by "a plan was approved". Mechanical/known-outcome/easy-to-verify
work (lockfile refreshes, patch-level bumps, renames, codemods) takes the **Mechanical** row; debugging,
multi-file logic or new features take **Build**; ADR/system design takes **Architecture**. Mechanical is a positive
classification only: a plan with no clear signal, or with build and mechanical signals together,
stays on Build. A Mechanical plan names an escalation trigger (switch up only when a build/test
failure needs real debugging). A session already on the row's Claude model — or a stronger
one — is a **match**: do not STOP or ask for `/model`. STOP stays for genuine mismatches (a session
below the row's model, or delegable work for an enabled vendor done inline).

## CLAUDE.md Optimization

**Auto-apply when user says:** "optimize Claude config", "update config", "improve CLAUDE.md", "set up Claude", "create CLAUDE.md".

Required elements: retrieval-led instruction at top; compressed pipe-delimited index (`[Category]|root: path/`); tables over lists; security inline with details in `rules/`; skills for user-triggered work only. Templates and the fill-in prompts: `claude-md-project-templates.md`.
