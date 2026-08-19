# Branch Discipline

Feature-branch-first. Never commit on the integration branch (`main`/`master`/`trunk`/`develop`), even with intent to "move it later." Branch BEFORE the first commit, not after.

Branch creation costs nothing; branching late costs at least a destructive rewind of `main` and at worst an accidental push to remote `main` (which can trigger release CI/CD).

## The rule

Before the first edit that you intend to commit, check the current branch. If it's an integration branch, create and check out a feature branch off the up-to-date integration ref.

| Detect | Act |
|--------|-----|
| `git rev-parse --abbrev-ref HEAD` returns `main`/`master`/`trunk`/`develop` | Create feature branch BEFORE first commit |
| Otherwise (already on a feature branch) | Proceed |

## Standard branching sequence

```bash
# At the start of any task that will produce a commit:
current_branch=$(git rev-parse --abbrev-ref HEAD)
case "$current_branch" in
  main|master|trunk|develop)
    git fetch origin "$current_branch" --quiet
    # Project convention determines the prefix — see "Branch naming" below.
    branch="claude/<short-kebab-description>"
    git checkout -b "$branch" "origin/$current_branch"
    ;;
esac
# now safe to edit + commit
```

## Branch naming

Use the project's documented convention if it has one (`CLAUDE.md` → `Agent Config` → `branch_pattern`). Otherwise:

- `claude/<short-kebab-description>` for interactive Claude Code sessions
- `agent/<short-kebab-description>` for scheduled / autonomous routines

Tie the description to the tracker id or PR intent when possible: `claude/cms-8rn-substrate-write-hook`, `claude/fix-stale-readme-badge`.

## Where this fits

The **Branch** step sits between claiming the tracker item and the first edit — before TDD, gates, and the commit agent.

## Interaction with the commit agent

The commit agent inherits CWD and HEAD and commits on whatever branch is checked out; it does NOT refuse when that branch is `main`, because by then the code is staged and the user has asked to commit. **The pre-commit branch check is the orchestrator's job, not the commit agent's** — skills and orchestrators doing multi-step git work run the branching sequence in their preamble.

## Interaction with worktree isolation

A pipeline running in a `git worktree` (see `agent-isolation.md`) already gets a feature branch from `git worktree add -b <branch> <path> origin/main`; no extra step. This rule applies primarily to non-worktree sessions in the main checkout.

## Recovery if you slip

If a commit lands on `main` before you remember this rule:

```bash
git branch <feature-branch> HEAD          # mark the commit
git checkout <feature-branch>              # switch off main first
git branch -f main "origin/main"           # rewind main (NOT --hard; just moves the ref)
```

Reversible, but not routine: if you do this more than once a week, add the branch step to the project's CLAUDE.md autonomy tier as an explicit reminder.

## Enforcement and cleanup

Rules steer the model; hooks are a hard stop. When a project keeps skipping the branch step, install a `PreToolUse` guard that refuses `Edit`/`Write`/`NotebookEdit` while HEAD is on an integration branch, with a narrow allowlist (`.beads/`, `MEMORY.md`, `~/.claude/plans/`, `~/.claude/projects/*/memory/`). Script, settings snippet, and the post-merge worktree/branch reaper: `docs/reference/branch-guard-setup.md` in cc-harness (SetDigger's `scripts/branch-guard.sh` is a live example).
