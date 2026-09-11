# Branch guard setup (maintainer reference)

This `PreToolUse` hook refuses `Edit`, `Write`, and `NotebookEdit` while HEAD is on an
integration branch. Rules guide the model; the hook stops the tool call. Use both.

This file is not symlinked into `~/.claude/`; copy it when setting up a project. For a live
example, see AudioWebsite's `scripts/branch-guard.sh` and `.claude/rules/branching.md`.

## 1. Add the guard script

`scripts/branch-guard.sh` (chmod +x):

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
echo "branch-guard: refusing to edit $REL while HEAD is on $BRANCH. Create a feature branch first: git checkout -b feat/<desc> origin/$BRANCH" >&2
exit 2
```

## 2. Register the hook in `.claude/settings.json`

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

## 3. Keep the allowlist narrow

Allow only paths designed to change on `main`: issue-tracker files (`.beads/`), persistent
agent memory, and plan files. If a change would be unwelcome in `git diff` on `main`, it does
not belong in the allowlist.

## Post-merge cleanup companion

Branch-first discipline needs post-merge cleanup, or worktrees under `worktree_root` and local
feature branches accumulate:

| Trigger | Mechanism | Scope |
|---|---|---|
| `pr-monitor` reports `MERGED` | `pr-monitor` post-merge cleanup step | The just-merged branch and (if running inside one) the orchestrator's worktree |
| Manual / scheduled | `scripts/cleanup-stale-git-state.sh` | All stale worktrees and merged local branches in the repo |

The manual script is idempotent and refuses to touch the current checkout's working tree,
branch, or HEAD. Mention it in the project's `CLAUDE.md` NEVER rules so users know it exists.
