# Branch Guard Setup (maintainer reference)

Machine-enforced branch discipline: a `PreToolUse` hook that refuses `Edit`/`Write`/
`NotebookEdit` while HEAD is on an integration branch. Rules steer the model; hooks are a
hard stop at tool-call time. Use both.

This file is **not symlinked into `~/.claude/`** — copy from here when setting a project up.
A live example is SetDigger's `scripts/branch-guard.sh` + `.claude/rules/branching.md`.

## 1. Drop in the guard script

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
echo "branch-guard: refusing to edit $REL while HEAD is on $BRANCH. Create a feature branch first: git checkout -b claude/<desc> origin/$BRANCH" >&2
exit 2
```

## 2. Wire the hook in the project's `.claude/settings.json`

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

Cover only paths that mutate on `main` by design — issue-tracker files (`.beads/`),
persistent agent memory, plan files. Anything you wouldn't want to see on `main` in a
`git diff` does not belong there.

## Post-merge cleanup companion

The companion to "branch first" is "clean up after merge", or worktrees under
`worktree_root` and local feature branches pile up:

| Trigger | Mechanism | Scope |
|---|---|---|
| `pr-monitor` reports `MERGED` | `pr-monitor` post-merge cleanup step | The just-merged branch and (if running inside one) the orchestrator's worktree |
| Manual / scheduled | `scripts/cleanup-stale-git-state.sh` | All stale worktrees and merged local branches in the repo |

The manual script is idempotent and refuses to touch the current checkout's working tree,
branch, or HEAD. Projects should call it out in CLAUDE.md NEVER rules so the user knows it
exists.
