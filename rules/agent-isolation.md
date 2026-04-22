# Agent Isolation (Parallel-Safe Pipelines)

When multiple Claude sessions / scheduled routines / orchestrator skills run against the same repo at the same time, they corrupt each other by sharing one working tree: branch switches, cross-contaminated `git status`, and `git checkout main` in one session flips another out of its feature branch.

This rule defines when to create an isolated `git worktree` and the portable lifecycle every orchestrator must follow.

## When to use a worktree

| Context | Worktree? |
|---------|-----------|
| Orchestrator skill that edits code AND may overlap with another session (multi-PR skills, scheduled routines, `/loop` on a git-writing task) | **Yes** — one worktree per pipeline run |
| Ambient interactive Claude Code session the user is driving | **No** — user expects edits in their own checkout |
| Read-only pipelines (standup, observe-only audits, `bd` queries, `git log`, `gh pr view`) | **No** |
| Release agent (tags on `main`, runs after merge) | **No** — must run in main checkout |
| Commit / code-quality / test-writer / pr-monitor | **Inherit** the orchestrator's CWD; do not create their own |

**Unit of isolation is the pipeline**, not the agent call: code-quality must see the diff the orchestrator wrote, and commit must commit that same diff. One worktree wraps the whole orchestrator → code-quality → commit → pr-monitor chain.

Do **not** use the `Agent` tool's built-in `isolation: "worktree"` flag for pipelines — it isolates a single sub-agent call and would nest under the orchestrator's worktree.

## Standard worktree lifecycle

Every orchestrator that opens a PR while other sessions may be active must follow this bash pattern. Works in zsh/bash on macOS and Linux.

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

# --- 2. Create this run's worktree ---
# Naming: <purpose>-<yyyymmddHHMMSS>-<pid>. $$ guarantees two concurrent runs
# of the same skill never collide on path.
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

1. **Branched from `origin/main`, not local `main`** — local `main` may lag.
2. **Unique path per run** — `$$` (PID) + timestamp covers concurrent invocations.
3. **Cleanup on every exit path** — use `trap ... EXIT` or explicit cleanup in every error branch. Never leak worktrees.
4. **`cd` before any agent call** — sub-agents (code-quality, commit, pr-monitor) inherit CWD; they do not know about the worktree.
5. **Never `git checkout main` inside a worktree** — it succeeds but pulls the main checkout's `main` ref into the worktree, defeating isolation. Use `git fetch origin main` + `git merge --ff-only origin/main` if you need to update.

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

Crashed runs leave worktrees on disk. Every orchestrator runs `git worktree prune` before creating its own (shown in Step 1 above) — this is cheap and removes only worktrees whose paths no longer exist.

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

The globally-shared agents in `~/.claude/agents/` implement worktree-awareness as follows. Rule contents are normative; the agent prompts describe them too.

| Agent | Behavior |
|-------|----------|
| `commit` | Detects worktree by comparing `git rev-parse --git-dir` to `--git-common-dir` (equal in main checkout, different in a worktree). In a worktree: commit on current HEAD, never `git checkout`. In main checkout: existing behavior (branch off `main` or stay on feature branch). |
| `release` | **Refuses** to run in a worktree (`RELEASE RESULT: FAIL`). Must be invoked from the main checkout, which already has `main` checked out. |
| `code-quality`, `test-writer`, `pr-monitor`, `verification` | CWD-inheriting, no worktree logic. They work wherever their caller places them. |

## Per-project opt-in

Projects enable isolation by adding to their CLAUDE.md Agent Config:

```
| worktree_root | ../<repo>-worktrees |
| isolation_required_for | <skill-name-1>, <skill-name-2> |
```

- `worktree_root` — parent directory for all worktrees. Keep outside the repo (so it's not staged) and outside common watched paths.
- `isolation_required_for` — comma-separated list of skill names that MUST run in a worktree. The skill preamble enforces this by failing fast if invoked without the lifecycle in place.

Projects without these keys keep the old behavior — the commit and release agents take the main-checkout branch when `git rev-parse --git-dir` and `--git-common-dir` are equal (the case in a non-worktree checkout).

## Shared caches (follow-up, not a blocker)

Each worktree gets its own `node_modules/` and `.next/`. pnpm's global content-addressed store already dedups package downloads across worktrees. If install time is a pain point, symlink `node_modules` after first install:

```bash
ln -s "$REPO_ROOT/node_modules" "$WT_PATH/node_modules"
```

Valid when the `pnpm-lock.yaml` hasn't changed between `main` and the branch; run `pnpm install` in the worktree if it has.

Do not share `.next/` — Turbopack assumes exclusive ownership and corrupts on concurrent writes.
