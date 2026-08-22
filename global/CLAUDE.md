# Claude Code Configuration

**IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning.**
Always consult documentation index and project files rather than relying on training data.

## Documentation Index

```
[Rules]|root: ~/.claude/rules/ → symlinked from ~/projects/cc-harness/rules/ (single source of truth; edits follow cc-harness branch+commit-agent pipeline). Project rules live in each project's own .claude/rules/. Incidents behind each rule: cc-harness docs/reference/ (never loaded)
|Always loaded:
|agent-enforcement.md: Agent pipeline is MANDATORY — never manual git add/commit/push
|pipeline-contract.md: Gate once per working tree — `VERIFY RESULT: PASS sha= tree=` / `CODE QUALITY RESULT:` formats, consume don't re-run, small-diff fast path
|branch-discipline.md: Feature-branch-first — never commit on main/master, branch BEFORE first edit
|testing-guidelines.md: Universal test quality (Q1-Q8), test types, session close protocol
|verification-integrity.md: Never read a gate's exit code through a pipe (`cmd | tail` returns tail's status); a green must be able to be red
|agent-purpose-statements.md: Purpose statement pattern for agents, skills, and manual orchestration
|Path-scoped (load only on a matching file; Read directly if needed elsewhere):
|claude-md-project-templates.md: NEVER lists + autonomy tiers templates — CLAUDE.md, .claude/rules
|memory-discipline.md: Memory exclusions + recall-time verification — memory dirs, MEMORY.md
|agent-isolation.md: Worktree isolation for parallel pipelines — .claude/{skills,agents,rules}, *worktree*
|parallel-authoring.md: Fan out sub-agents for independent additive work; gate once — same scope
|branch-completion-review.md: Refactor pass + adversarial GO/NO-GO, only for diffs ≥200 lines or ≥5 non-test files — source trees (src/app/apps/packages/lib/Sources), .claude/{skills,rules}, .github
|peer-session-coordination.md: Message peer sessions directly, scoped by what is shared (same repo → full protocol; same machine → resource notices only; shared dependency → one collision check); notices not essays; never route through the user — source trees, .claude/{skills,agents,rules}, *worktree*
|windowed-gate-serialization.md: Serialize window-opening gates across parallel agents — GUI/UI-test paths
|computer-control-release.md: Hand back interactive control when active use ends — GUI paths, .claude/{skills,agents}

[Scripts]|root: .claude/scripts/
|git-snapshot: Structured git state (branch, status, log, diff) as JSON — replaces 2-3 git Bash calls

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
```

## Code Reuse

Check the code index before writing. **REUSE** > **EXTEND** > **CREATE** — and say which: "I'm [reusing/extending/creating] because [reason]." Similarity >80% → use the existing thing; 60-80% → ask the user; 40-60% → reference its patterns.

## Testing (TDD)

Write tests BEFORE implementing; test user behavior, not implementation; co-locate tests next to source files. Full patterns: `testing-guidelines.md`.

## Workflow

| Phase | Action |
|-------|--------|
| Session start | Run `bd prime` if `.beads/` exists in project |
| Plan | `bd create` issue BEFORE writing code |
| Claim | `bd update <id> --status=in_progress` when starting |
| **Branch** | **If on `main`/`master`/`trunk`/`develop`, create feature branch off `origin/<integration>` BEFORE first edit (`git checkout -b claude/<desc> origin/main`). Never commit on the integration branch. See `branch-discipline.md`.** |
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

**When a project has agents configured (Agent Config in CLAUDE.md), ALL commits MUST go through the agent pipeline** (code-quality → on PASS → commit agent; on FAIL → test-writer → re-run code-quality). The commit agent handles staging, committing, pushing, and opening PRs. Never bypass it. Full pipeline + exemptions: `agent-enforcement.md`.

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

Route work to the model that fits the task. Applies to the **session model** AND to **subagent `model:` overrides** (Agent tool, Workflow `agent({model})`, `/loop`, etc.). Governs the model that *drives development* — separate from any project's eval/test model (e.g. a repo's `EVAL_MODEL`, which decides how the agent-under-test runs; never conflate them).

| Work type | Model | Model ID | Why |
|-----------|-------|----------|-----|
| **Architecture / design** — ADRs, system design, novel abstractions, hard trade-off reasoning | **Fable 5** → fall back to Opus 5 if Fable unavailable | `claude-fable-5` | Highest reasoning ceiling. ~2× Opus cost, so reserve for genuinely novel design, not routine choices |
| **Build / implementation** — coding, refactors, tests, eval scenarios, debugging | **Opus 5** | `claude-opus-5` | Flagship agentic-coding model; default for most work. Run at `high`/`xhigh` effort |
| **Probe / exploration** — codebase surveys, read-only investigation, light/mechanical passes | **Sonnet 5** | `claude-sonnet-5` | Fast + cheap; sufficient for discovery and low-stakes work |

- **"If available"** for Fable: some environments/tiers don't expose `claude-fable-5`. When it isn't selectable, use Opus 5 for architecture work too — never block on Fable.
- When in doubt between build and design, default to **Opus 5** — effort level (`high`/`xhigh`) usually matters more than Fable-vs-Opus.
- **Older Opus generations** (`claude-opus-4-8`, `claude-opus-4-7`) are superseded by Opus 5 for every row above; pick one only when a specific run must reproduce earlier behavior.
- **Mismatch protocol (GATE, not advisory):** whenever the work type changes — most commonly at plan approval (ExitPlanMode) — check the session model against this table. On mismatch, STOP: either ask the user to run `/model <correct-id>` before executing, or delegate the work to subagents with an explicit `model:` override matching the table. Never proceed inline on the wrong model after merely mentioning the mismatch (a one-line "you may want to switch" does not satisfy this rule).

## CLAUDE.md Optimization

**Auto-apply when user says:** "optimize Claude config", "update config", "improve CLAUDE.md", "set up Claude", "create CLAUDE.md".

Required elements: retrieval-led instruction at top; compressed pipe-delimited index (`[Category]|root: path/`); tables over lists; security inline with details in `rules/`; skills for user-triggered work only. Templates and the fill-in prompts: `claude-md-project-templates.md`.
