# Claude Code Configuration

**IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning.**
Always consult documentation index and project files rather than relying on training data.

## Documentation Index

```
[Rules]|root: ~/.claude/rules/ → symlinked from ~/projects/cc-harness/rules/ (single source of truth; edits follow cc-harness branch+commit-agent pipeline). Project-specific rules live in each project's own .claude/rules/
|agent-enforcement.md: Agent pipeline is MANDATORY — never manual git add/commit/push
|branch-discipline.md: Feature-branch-first — never commit on main/master, branch BEFORE first edit
|testing-guidelines.md: Universal test quality (Q1-Q8), TDD, session close protocol
|claude-md-project-templates.md: NEVER lists + autonomy tiers templates for project CLAUDE.md
|memory-discipline.md: Memory exclusion reinforcements + recall-time verification protocol
|agent-purpose-statements.md: Purpose statement pattern for agents, skills, and manual orchestration
|agent-isolation.md: Worktree-based isolation for parallel agent pipelines — when and how
|parallel-authoring.md: Fan-out parallel sub-agents for independent additive work; gate once
|verification-integrity.md: Never read a gate's exit code through a pipe (`cmd | tail` returns tail's status); a green must be able to be red
|windowed-gate-serialization.md: Parallel agents on GUI-app projects — author headless in parallel, serialize window-opening gates through one stream + machine-global lock

[Scripts]|root: .claude/scripts/
|git-snapshot: Structured git state (branch, status, log, diff) as JSON — replaces 2-3 git Bash calls

[Beads]|binary: bd (in PATH)
|init: bd init --stealth (if no .beads/ in project)
|workflow: bd prime (full context), bd ready (find work), bd create/update/close
|session-start: run bd prime if .beads/ exists
|persistence: bd close writes immediately — no explicit flush at session end (bd sync was removed; use bd backup for snapshots, bd export for JSONL migration)

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

1. Check code index before writing
2. **REUSE** > **EXTEND** > **CREATE**
3. Explain: "I'm [reusing/extending/creating] because [reason]"

| Similarity | Action |
|------------|--------|
| >80% | Use existing |
| 60-80% | Ask user |
| 40-60% | Reference patterns |

## Testing (TDD)

See `.claude/rules/testing-guidelines.md` for complete patterns.

- Write tests BEFORE implementing
- Test user behavior, NOT implementation
- Co-locate tests next to source files

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

### Agent-Gated Commits (CRITICAL)

**When a project has agents configured (Agent Config in CLAUDE.md), ALL commits MUST go through the agent pipeline. No exceptions.**

| Rule | Detail |
|------|--------|
| **PROHIBITED** | Running `git add`, `git commit`, `git push` manually for ANY change — source, docs, config, or generated files |
| **REQUIRED** | Run code-quality agent → on PASS → delegate to commit agent |
| **REQUIRED** | If code-quality FAIL → test-writer agent → re-run code-quality → commit agent |
| **TRIGGER** | Any user request to "commit", "push", "save", "ship it", "yes" (to commit prompt) |
| **EXCEPTION** | Projects without Agent Config in CLAUDE.md use standard git workflow |

The commit agent handles staging, committing, pushing, and opening PRs. Never bypass it.

### Parallel Agent Runs (CRITICAL)

When multiple sessions / routines may run against the same repo simultaneously, orchestrator skills that edit code MUST wrap their pipeline in a `git worktree` so branch switches and staged changes don't leak between sessions. See `agent-isolation.md` for the lifecycle; opt in via `worktree_root` + `isolation_required_for` in the project's Agent Config.

### Planning vs Implementation (CRITICAL)

Planning and implementation are **always separate phases** requiring explicit commands.

| Phase | Trigger | Action |
|-------|---------|--------|
| **Plan only** | "plan", "design", "create tasks" | Create beads issues → STOP. Do NOT write code. |
| **Implement** | "implement", "start", "work on", "build" | Pick up a beads issue → write code |

When asked to **plan**: create all `bd create` issues, set dependencies with `bd dep add`, then say "Plan complete — run `bd ready` to start implementing."

**NEVER begin writing code during a planning session unless explicitly told to implement.**

### Task Management (CRITICAL)

**Use `bd` (beads) for ALL task tracking in ALL projects. No exceptions.**

| Rule | Detail |
|------|--------|
| **REQUIRED** | `bd create` before writing code for any non-trivial task |
| **REQUIRED** | `bd update --status=in_progress` when starting a task |
| **REQUIRED** | `bd close <id>` when done (close persists immediately; no session-end flush needed) |
| **PROHIBITED** | TodoWrite, TaskCreate, or markdown checklists for task tracking |
| New project | Run `bd init --stealth --prefix <abbrev>` if no `.beads/` exists |
| Full context | `bd prime` — run this at session start in any beads project |
| Find work | `bd ready` — lists unblocked open issues |

**Session Close:** `bd close` already persists immediately — no explicit flush command is needed. The legacy `bd sync --flush-only` step has been removed (the `sync` subcommand no longer exists in current `bd`). See testing-guidelines.md.

## Security

- Never expose, log, or commit secrets
- Never commit `.env`, credentials, or tokens
- Validate at system boundaries (user input, external APIs)
- Use least-privilege approach for all operations
- Project-specific auth patterns live in each project's rules/

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

**Auto-apply when user says:** "optimize Claude config", "update config", "improve CLAUDE.md", "set up Claude", "create CLAUDE.md"

| Config | Pass Rate |
|--------|-----------|
| No docs / Skills | 53% |
| **AGENTS.md index** | **100%** |

**Required:**
1. Retrieval-led instruction at top
2. Compressed pipe-delimited index: `[Category]|root: path/`
3. Tables over lists (~50% reduction)
4. Security inline, details in rules/
5. Skills for user-triggered only

**Workflow:** Read structure → Add instruction → Create index → Convert to tables → Extract to rules → Report line counts
