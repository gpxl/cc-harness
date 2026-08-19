---
paths:
  - "**/.claude/skills/**"
  - "**/.claude/agents/**"
  - "**/.claude/rules/**"
  - "**/*worktree*"
---
# Agent Isolation (Parallel-Safe Pipelines)

Concurrent Claude sessions / scheduled routines / orchestrator skills sharing one working tree corrupt each other: branch switches, cross-contaminated `git status`, and `git checkout main` in one session flipping another out of its feature branch. This rule defines when to create an isolated `git worktree` and the lifecycle every orchestrator must follow.

## When to use a worktree

| Context | Worktree? |
|---------|-----------|
| Orchestrator skill that edits code AND may overlap with another session (multi-PR skills, scheduled routines, `/loop` on a git-writing task) | **Yes** — one worktree per pipeline run |
| Ambient interactive Claude Code session the user is driving | **No** — user expects edits in their own checkout |
| Read-only pipelines (standup, observe-only audits, `bd` queries, `git log`, `gh pr view`) | **No** |
| Release agent (tags on `main`, runs after merge) | **No** — must run in main checkout |
| Commit / code-quality / test-writer / pr-monitor | **Inherit** the orchestrator's CWD; do not create their own |

**The unit of isolation is the pipeline**, not the agent call: one worktree wraps the whole orchestrator → code-quality → commit → pr-monitor chain, because code-quality must see the diff the orchestrator wrote and commit must commit that same diff. Do **not** use the `Agent` tool's built-in `isolation: "worktree"` flag for pipelines — it isolates a single sub-agent call and would nest under the orchestrator's worktree.

## Before you claim work, check nobody else has

Worktrees isolate *git state*, not *work selection*: two sessions can still pick the same item, and that costs more, because both sides finish the whole job before anyone notices. (Two same-day collisions, both caught by luck rather than by a rule: `~/projects/cc-harness/docs/reference/rule-histories.md`.)

### The preflight

Before claiming a tracked item and before the first edit, spend the ten seconds:

```bash
# 1. Is someone in a worktree for this? `+` marks a branch checked out elsewhere.
git worktree list
git branch -a --list '*<item-id>*' '*<short-slug>*'

# 2. Does a sibling worktree hold uncommitted work for it?
for wt in $(git worktree list --porcelain | awk '/^worktree /{print $2}'); do
  [ -n "$(git -C "$wt" status --short 2>/dev/null)" ] && echo "DIRTY: $wt"
done

# 3. What does the tracker say — status AND notes? A phase can be half-shipped
#    with the bead still open.
bd show <item-id>
```

### The rules

| Situation | Do |
|---|---|
| A branch, worktree, or dirty sibling matches the item | **Stop.** Do not start a parallel implementation. |
| Two sessions are already building it | **The later starter stands down** and deletes its copy. Racing to commit first just converts duplicated effort into a merge conflict. |
| You are proceeding | Claim in the tracker **before** the first edit, not at commit time — the claim is the signal the next session will look for |
| A phase looks unstarted | Read the item's NOTES, not just its status. "Open" can mean "half-shipped, awaiting one remaining step". |

### Tells that you are in a collision

Treat any of these as a stop-and-look, not a puzzle to work around:

- A `PreToolUse` branch guard refuses a write because HEAD moved under you (another session switched the shared checkout's branch).
- `git worktree list` shows a `+` against a branch you did not check out.
- The tracker item's notes describe work you were about to do.
- Migration/sequence numbers you did not create appear in your range.

## Standard worktree lifecycle

Every orchestrator that opens a PR while other sessions may be active must follow this pattern (zsh/bash, macOS and Linux).

```bash
# --- 0. Read Agent Config ---
# worktree_root: where isolated checkouts live (default: ../<repo>-worktrees)
# Absent key => use default.
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")
WORKTREE_ROOT="${WORKTREE_ROOT:-$REPO_ROOT/../${REPO_NAME}-worktrees}"
mkdir -p "$WORKTREE_ROOT"

# --- 1. Reap orphans from prior crashed runs (safe: only prunes missing paths) ---
git worktree prune

# --- 2. Create this run's worktree (naming: see table below) ---
PURPOSE="<short-purpose>"                         # e.g. "engagement-instrumentation"
BRANCH="agent/<short-description>"                # or claude/<description>, etc.
TS=$(date -u +%Y%m%d%H%M%S)
WT_PATH="$WORKTREE_ROOT/${PURPOSE}-${TS}-$$"

# Fetch before branching so we're on a fresh origin/main.
git fetch origin main --quiet
git worktree add -b "$BRANCH" "$WT_PATH" origin/main

# --- 3. Run the pipeline inside the worktree ---
cd "$WT_PATH"
trap 'cd "$REPO_ROOT" && git worktree remove --force "$WT_PATH" 2>/dev/null || true' EXIT

# ... edit files, invoke code-quality agent, invoke commit agent, invoke pr-monitor ...

# --- 4. Cleanup (also runs via trap on any exit path) ---
cd "$REPO_ROOT"
git worktree remove --force "$WT_PATH"
```

### Required properties

1. **Branch from `origin/main`, not local `main`** — local `main` may lag.
2. **Unique path per run** — `$$` (PID) + timestamp covers concurrent invocations.
3. **Cleanup on every exit path** — `trap ... EXIT` or explicit cleanup in every error branch; never leak worktrees.
4. **`cd` before any agent call** — sub-agents inherit CWD and know nothing about the worktree.
5. **Never `git checkout main` inside a worktree** — it succeeds but pulls the main checkout's `main` ref in, defeating isolation. To update, use `git fetch origin main` + `git merge --ff-only origin/main`.

## Concurrency-safe naming

Path template: `<worktree_root>/<purpose>-<yyyymmddHHMMSS>-<pid>`

| Component | Purpose |
|-----------|---------|
| `<worktree_root>` | Configured per-project; all worktrees under one parent for easy cleanup |
| `<purpose>` | Human-readable skill/intent label (`engagement`, `release`, `hotfix`) |
| `<yyyymmddHHMMSS>` | Ordering + forensic |
| `<pid>` (`$$`) | Guarantees uniqueness across concurrent runs of the same skill |

The branch name is independent of the path and follows the project's `branch_pattern` (e.g. `agent/<desc>` for scheduled routines, `claude/<desc>` for Claude Code sessions).

## Orphan cleanup

Crashed runs leave worktrees on disk, so every orchestrator runs `git worktree prune` before creating its own (Step 1 above) — cheap, and it removes only worktrees whose paths no longer exist.

For worktrees whose paths still exist but whose branches are already merged (agent branches after pr-monitor merge + delete), add this to session-start scripts that manage `worktree_root`:

```bash
# Reap merged agent worktrees older than 24h
find "$WORKTREE_ROOT" -maxdepth 1 -type d -mtime +0 -name 'agent-*' -print 2>/dev/null | while read -r wt; do
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || continue)
  if ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    # Remote branch gone (merged + deleted) => safe to remove
    git worktree remove --force "$wt" 2>/dev/null || true
  fi
done
```

Safe default if you're unsure: just `git worktree prune`. Never remove the main checkout.

## Per-agent policy

Worktree-awareness of the globally-shared agents in `~/.claude/agents/` (this table is normative):

| Agent | Behavior |
|-------|----------|
| `commit` | Detects worktree by comparing `git rev-parse --git-dir` to `--git-common-dir` (equal in main checkout, different in a worktree). In a worktree: commit on current HEAD, never `git checkout`. In main checkout: existing behavior (branch off `main` or stay on feature branch). |
| `release` | **Refuses** to run in a worktree (`RELEASE RESULT: FAIL`). Must be invoked from the main checkout, which already has `main` checked out. |
| `code-quality`, `test-writer`, `pr-monitor`, `verification` | CWD-inheriting, no worktree logic. They work wherever their caller places them. |

## Per-project opt-in

Projects enable isolation with two CLAUDE.md Agent Config keys:

```
| worktree_root | ../<repo>-worktrees |
| isolation_required_for | <skill-name-1>, <skill-name-2> |
```

- `worktree_root` — parent directory for all worktrees; keep it outside the repo (so it's not staged) and outside common watched paths.
- `isolation_required_for` — comma-separated skill names that MUST run in a worktree; the skill preamble fails fast without the lifecycle in place.

Without these keys, the commit and release agents take the main-checkout branch when `git rev-parse --git-dir` and `--git-common-dir` are equal.

## What worktrees do NOT isolate

Git state only. The window server, the visible screen, audio/render engines, simulators, and TCC grants are machine-global: N worktree agents each running a windowed UI gate still pop N sets of windows and contend on shared engines. Serialize those stages through one gate-runner stream with a machine-global lock — see `windowed-gate-serialization.md`.

## Shared caches (follow-up, not a blocker)

- **Default everywhere:** `pnpm install --prefer-offline` in the fresh worktree — pnpm's global store dedups downloads across worktrees, typically <15s.
- **Non-Turbopack stacks only** (plain Webpack/Vite, no Next.js 15+) may skip that install by symlinking, and only when `pnpm-lock.yaml` is unchanged between `main` and the branch:
  ```bash
  ln -s "$REPO_ROOT/node_modules" "$WT_PATH/node_modules"
  ```
- **Never symlink for Turbopack / Next.js 15+ / 16+** — it rejects out-of-tree symlinks (`Symlink node_modules is invalid, it points out of the filesystem root — TurbopackInternalError`) — and never share `.next/`: Turbopack assumes exclusive ownership and corrupts on concurrent writes.
