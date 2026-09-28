#!/usr/bin/env bash
# List, and with --apply remove, git worktrees whose work is finished: the branch's PR is MERGED
# or CLOSED, or the branch's upstream is gone. Dry-run by default. Covers every worktree the repo
# knows about, wherever it lives (<repo>-worktrees/*, .claude/worktrees/*, a pipeline's
# worktree_root) — scripted pipelines clean up after themselves, session-made worktrees do not.
#
# Never removed: the main checkout; a locked worktree; a detached HEAD (no branch to judge);
# one with ANY uncommitted or untracked change, including edits hidden by assume-unchanged or
# skip-worktree, or whose status cannot be read; one some process is sitting in (its cwd is inside
# it — a live session, a shell, a dev server); one whose HEAD is not contained in the PR's final
# head commit (work added after the PR); and anything whose PR lookup FAILED, which is reported as
# its own verdict and never folded into "no PR" (rules/verification-integrity.md).
#
# `git worktree remove` keeps the branch, so a removed worktree loses no commits. The local branch
# itself is deleted only for a MERGED PR whose final head contains it (agent-enforcement.md
# § Branch cleanup on merge). Missing-path worktrees are pruned with `git worktree prune`.
#
# Usage: worktree-reap.sh [--apply] [--repo <dir>]...   (default repo: the cwd's)
# Output: one `WORKTREE <path> branch=<b> pr=<state>[#n] verdict=<REMOVE|KEEP|PRUNE> reason=<r>
#         action=<dry-run|removed|kept|pruned|failed>` line per non-main worktree, then a summary
#         (`candidates` = REMOVE/PRUNE verdicts, acted on only with --apply).
# Exit: 0 ok (including nothing to do); 1 a removal failed; 2 usage error.
#
# Test seams (hermetic selftest only): WORKTREE_REAP_PR_FILE — lines `<branch> <STATE> <n> <oid>`
# or `<branch> ERROR` replace the gh lookup (an absent branch means no PR);
# WORKTREE_REAP_CWDS_FILE — one path per line replaces the lsof process-cwd scan.
set -uo pipefail

apply=0
repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --repo) [ $# -ge 2 ] || { echo "worktree-reap: --repo needs a directory" >&2; exit 2; }; repos+=("$2"); shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "worktree-reap: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ ${#repos[@]} -gt 0 ] || repos=(".")

tmp=$(mktemp -d "${TMPDIR:-/tmp}/worktree-reap.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

# Every process cwd on the machine, once. A worktree containing one is in use.
cwds="$tmp/cwds"
if [ -n "${WORKTREE_REAP_CWDS_FILE:-}" ]; then
  cp "$WORKTREE_REAP_CWDS_FILE" "$cwds"
else
  lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' > "$cwds" || true
fi
# The caller's own cwd counts even when lsof is unavailable.
pwd -P >> "$cwds"

in_use() {  # $1 = worktree path (physical)
  local c
  while IFS= read -r c; do
    case "$c" in "$1"|"$1"/*) return 0 ;; esac
  done < "$cwds"
  return 1
}

pr_lookup() {  # $1 = repo dir, $2 = branch -> prints "STATE NUMBER OID", "NONE", or "ERROR"
  local line
  if [ -n "${WORKTREE_REAP_PR_FILE:-}" ]; then
    line=$(awk -v b="$2" '$1 == b { $1 = ""; sub(/^ /, ""); print; exit }' "$WORKTREE_REAP_PR_FILE")
    printf '%s\n' "${line:-NONE}"
    return
  fi
  if ! line=$(cd "$1" && gh pr list --state all --head "$2" --limit 1 \
      --json state,number,headRefOid -q '.[0] // empty | "\(.state) \(.number) \(.headRefOid)"' 2>/dev/null); then
    echo ERROR; return
  fi
  printf '%s\n' "${line:-NONE}"
}

removed=0 kept=0 failed=0 pruned=0 candidates=0

reap_repo() {
  local repo="$1" root main
  if ! root=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    echo "worktree-reap: not a git repository: $repo" >&2; failed=$((failed + 1)); return
  fi
  # The main worktree is always the first porcelain entry.
  main=$(git -C "$repo" worktree list --porcelain | sed -n '1s/^worktree //p')
  git -C "$main" fetch --prune --quiet origin 2>/dev/null || echo "worktree-reap: fetch failed in $main; upstream state may be stale" >&2

  local list="$tmp/list" path="" branch="" locked=0 prunable=0 detached=0 first=1
  git -C "$main" worktree list --porcelain > "$list"
  printf '\n' >> "$list"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "branch "*) branch="${line#branch refs/heads/}" ;;
      detached) detached=1 ;;
      locked|"locked "*) locked=1 ;;
      prunable|"prunable "*) prunable=1 ;;
      "")
        if [ -n "$path" ]; then
          if [ "$first" = 1 ]; then first=0
          else judge "$main" "$path" "$branch" "$locked" "$prunable" "$detached"
          fi
        fi
        path="" branch="" locked=0 prunable=0 detached=0 ;;
    esac
  done < "$list"
}

# Prints a KEEP reason and succeeds when the worktree may hold work `git status` alone would not
# show; fails (prints nothing) only on positive evidence of a clean tree. Fails closed throughout,
# because `git worktree remove` asks git the same questions and would not catch what this misses.
dirty_reason() {
  local path="$1" out flag file
  # Index flags hide edits from status whatever its options: lowercase = assume-unchanged,
  # S = skip-worktree. An S entry absent from disk is ordinary sparse checkout, not an edit.
  out=$(git -C "$path" ls-files -v -z 2>/dev/null) || { echo status-failed; return 0; }
  while IFS= read -r -d '' file; do
    flag="${file%% *}"; file="${file#* }"
    case "$flag" in
      [a-z]) echo index-flagged; return 0 ;;
      S) [ -e "$path/$file" ] && { echo index-flagged; return 0; } ;;
    esac
  done < <(git -C "$path" ls-files -v -z 2>/dev/null)
  # Flags, not defaults: status.showUntrackedFiles=no in any config would otherwise hide untracked
  # work. A status that cannot be read is not a clean status.
  out=$(git -C "$path" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) \
    || { echo status-failed; return 0; }
  [ -n "$out" ] && { echo dirty; return 0; }
  return 1
}

report() {  # path branch pr verdict reason action
  printf 'WORKTREE %s branch=%s pr=%s verdict=%s reason=%s action=%s\n' "$@"
}

judge() {
  local main="$1" path="$2" branch="${3:--}" locked="$4" prunable="$5" detached="$6"
  local pr="-" state number oid phys verdict reason

  if [ "$prunable" = 1 ] || [ ! -d "$path" ]; then
    if [ "$apply" = 1 ]; then
      git -C "$main" worktree prune && { report "$path" "$branch" - PRUNE path-missing pruned; pruned=$((pruned + 1)); } \
        || { report "$path" "$branch" - PRUNE path-missing failed; failed=$((failed + 1)); }
    else report "$path" "$branch" - PRUNE path-missing dry-run; candidates=$((candidates + 1))
    fi
    return
  fi
  phys=$(cd "$path" && pwd -P)

  keep() { report "$path" "$branch" "$pr" KEEP "$1" kept; kept=$((kept + 1)); }
  [ "$locked" = 1 ] && { keep locked; return; }
  [ "$detached" = 1 ] && { keep detached-head; return; }
  local why
  why=$(dirty_reason "$path") && { keep "$why"; return; }
  in_use "$phys" && { keep in-use; return; }

  read -r state number oid <<EOF
$(pr_lookup "$main" "$branch")
EOF
  case "$state" in
    ERROR) pr="ERROR"; keep pr-lookup-failed; return ;;
    NONE) pr="NONE" ;;
    *) pr="$state#$number" ;;
  esac

  local head delete_branch=0
  head=$(git -C "$path" rev-parse HEAD)
  case "$state" in
    OPEN) keep pr-open; return ;;
    MERGED|CLOSED)
      # HEAD must be contained in what the PR last saw; later commits are unfinished work.
      if [ -z "${oid:-}" ] || ! git -C "$main" cat-file -e "$oid^{commit}" 2>/dev/null; then
        keep head-unverified; return
      fi
      git -C "$main" merge-base --is-ancestor "$head" "$oid" || { keep commits-after-pr; return; }
      verdict=REMOVE; reason="pr-$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
      [ "$state" = MERGED ] && delete_branch=1 ;;
    NONE)
      # No PR: only a branch whose upstream was deleted is finished. Never-pushed stays.
      if [ "$(git -C "$main" for-each-ref --format='%(upstream:track)' "refs/heads/$branch")" = "[gone]" ]; then
        verdict=REMOVE; reason=upstream-gone
      else keep no-pr; return
      fi ;;
    *) keep "unknown-pr-state"; return ;;
  esac

  candidates=$((candidates + 1))
  if [ "$apply" = 0 ]; then report "$path" "$branch" "$pr" "$verdict" "$reason" dry-run; return; fi
  if git -C "$main" worktree remove "$path" 2>"$tmp/err"; then
    removed=$((removed + 1))
    if [ "$delete_branch" = 1 ] && [ "$(git -C "$main" rev-parse "refs/heads/$branch" 2>/dev/null)" = "$head" ]; then
      git -C "$main" branch -D "$branch" >/dev/null 2>&1 && reason="$reason+branch-deleted"
    fi
    report "$path" "$branch" "$pr" "$verdict" "$reason" removed
  else
    failed=$((failed + 1))
    report "$path" "$branch" "$pr" "$verdict" "$reason:$(tr '\n' ' ' < "$tmp/err" | tr ' ' '_')" failed
  fi
}

for r in "${repos[@]}"; do reap_repo "$r"; done

mode=dry-run; [ "$apply" = 1 ] && mode=apply
printf 'WORKTREE REAP: mode=%s candidates=%s removed=%s pruned=%s kept=%s failed=%s\n' "$mode" "$candidates" "$removed" "$pruned" "$kept" "$failed"
[ "$failed" -eq 0 ]
