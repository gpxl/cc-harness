# Branch Discipline

Feature-branch-first. Never commit on the integration branch (`main`/`master`/`trunk`/`develop`), even with intent to "move it later." Branch BEFORE the first commit, not after.

## Why this rule exists

Committing to `main` and then rewinding it after the fact is a recoverable mistake on a local checkout, but:

1. It leaves a window where the commit is on `main`. If `git push` happens — by the user, by an editor's auto-push, by a hook, or by an agent that didn't read the project's no-direct-push rule — the commit lands on remote `main`. Some projects gate releases off `main`; an accidental push can trigger CI/CD.
2. The "rewind" requires `git branch -f main origin/main` (or a `reset`), which is a destructive op the user has to authorize each time. Cheap if you remember; not free.
3. Branch creation costs nothing. Doing it up front removes the whole class of problem.

The cost of always branching first is one extra command at the start of a task. The cost of branching late is at least a recovery sequence and at worst a bad push.

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

Use the project's documented convention if it has one (look in `CLAUDE.md` → `Agent Config` → `branch_pattern`). Otherwise default to:

- `claude/<short-kebab-description>` for interactive Claude Code sessions
- `agent/<short-kebab-description>` for scheduled / autonomous routines

Tie the description to the bead id or PR intent when possible: `claude/cms-8rn-substrate-write-hook`, `claude/fix-stale-readme-badge`.

## Where this fits in the workflow

Insert a **Branch** step into the standard workflow, before any code edits:

| Phase | Action |
|-------|--------|
| Session start | Run `bd prime` if `.beads/` exists |
| Plan | `bd create` issue BEFORE writing code |
| Claim | `bd update <id> --status=in_progress` |
| **Branch** | **If on integration branch, create feature branch off `origin/<integration>` before first edit** |
| TDD / Implement | Write tests, then code |
| Test / Lint | All green |
| Commit | Delegate to commit agent |
| Complete | `bd close <id>` |

## Interaction with the commit agent

The commit agent inherits CWD and HEAD — it commits on whatever branch is checked out. It does NOT detect "we're on main and should have branched earlier" and refuse, because by the time it's invoked the code is already staged and the user has asked to commit. **The pre-commit branch check is the orchestrator's job, not the commit agent's.**

Skills and orchestrators that perform multi-step git work should run the branching sequence in their preamble.

## Interaction with worktree isolation

When a pipeline runs in a `git worktree` (see `agent-isolation.md`), the worktree is created with `git worktree add -b <branch> <path> origin/main` — that already enforces feature-branch creation. No extra step needed. This rule applies primarily to non-worktree sessions (interactive work in the main checkout).

## Recovery if you slip

If a commit lands on `main` before you remember this rule:

```bash
git branch <feature-branch> HEAD          # mark the commit
git checkout <feature-branch>              # switch off main first
git branch -f main "origin/main"           # rewind main (NOT --hard; just moves the ref)
```

This is reversible but should not be routine. If you find yourself doing it more than once a week, the branch step isn't sticking — add it to the project's CLAUDE.md autonomy tier as an explicit reminder.

## Machine-enforced branching (PreToolUse hook)

If a project sees the branching step skipped repeatedly — work landing on `main`, `WIP on main` stashes accumulating, the commit agent's late branch-creation carrying unrelated dirty state onto feature branches — graduate from "rule documented" to "rule enforced" by installing a PreToolUse hook.

### Project setup

1. **Drop in the guard script.** Copy this into `scripts/branch-guard.sh` in the project (chmod +x):

   ```bash
   #!/usr/bin/env bash
   set -u
   INPUT=$(cat)
   FILE_PATH=$(printf '%s' "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
   [ -z "$FILE_PATH" ] && exit 0
   DIR=$(dirname "$FILE_PATH"); [ -d "$DIR" ] || DIR=$(pwd)
   REPO=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
   BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)
   case "$BRANCH" in main|master|trunk|develop) ;; *) exit 0 ;; esac
   REL=${FILE_PATH#"$REPO/"}
   # Allowlist project-specific paths that legitimately mutate on main:
   case "$REL" in
     .beads/*|.beads) exit 0 ;;
     MEMORY.md) exit 0 ;;
   esac
   case "$FILE_PATH" in
     "$HOME"/.claude/plans/*) exit 0 ;;
     "$HOME"/.claude/projects/*/memory/*) exit 0 ;;
   esac
   echo "branch-guard: refusing to edit $REL while HEAD is on $BRANCH. Create a feature branch first: git checkout -b claude/<desc> origin/$BRANCH" >&2
   exit 2
   ```

2. **Wire the hook in the project's `.claude/settings.json`:**

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Edit|Write|NotebookEdit",
           "hooks": [
             { "type": "command", "command": "bash scripts/branch-guard.sh" }
           ]
         }
       ]
     }
   }
   ```

3. **Extend the allowlist.** Each project's allowlist should cover paths that mutate on `main` by design — issue-tracker files (`.beads/`), persistent agent memory, plan files. Keep it narrow: any path you wouldn't be comfortable seeing on `main` in a `git diff` does not belong in the allowlist.

### Why a hook and not just this rule

Rules steer the model. Hooks are a hard stop at tool-call time. Use both: this rule explains intent and recovery; the hook enforces the rule when intent fails. They complement each other — see SetDigger's `scripts/branch-guard.sh` and `.claude/rules/branching.md` for a live example.

### Post-merge worktree + branch cleanup

The companion to "branch first" is "clean up after merge." Without it, worktrees under `worktree_root` and local feature branches pile up. Two mechanisms cover this:

| Trigger | Mechanism | Scope |
|---|---|---|
| `pr-monitor` reports `MERGED` | `pr-monitor` Step 6 (post-merge cleanup) | The just-merged branch and (if running inside one) the orchestrator's worktree |
| Manual / scheduled | `scripts/cleanup-stale-git-state.sh` | All stale worktrees and merged local branches in the repo |

The manual script is idempotent and refuses to touch the current checkout's working tree, branch, or HEAD. Project should call it out in CLAUDE.md NEVER rules so the user knows it exists.
