#!/usr/bin/env bash
# Hermetic checks for worktree-reap.sh: finished worktrees go, anything holding work stays.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tool="$script_dir/worktree-reap.sh"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/worktree-reap-selftest.XXXXXX") || exit 1
tmp_root=$(cd "$tmp_root" && pwd -P)
failures=0
cleanup() {
  local status=$?
  rm -rf "$tmp_root"
  [ "$completed" = 1 ] || status=1
  exit "$status"
}
# Completion sentinel: on bash 3.2 an abort under set -e/-u reaches the EXIT trap with $? = 0
# (cch-85b), so only reaching the verdict below counts as a pass.
completed=0
trap cleanup EXIT HUP INT TERM

export GIT_CONFIG_GLOBAL="$tmp_root/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name selftest
git config --global user.email selftest@example.invalid
git config --global init.defaultBranch main

git init -q --bare "$tmp_root/origin.git"
main="$tmp_root/main"
git clone -q "$tmp_root/origin.git" "$main" 2>/dev/null
git -C "$main" commit -q --allow-empty -m base
git -C "$main" push -q origin main
wts="$tmp_root/wts"; mkdir -p "$wts"

prs="$tmp_root/prs.txt"; : > "$prs"
cwds="$tmp_root/cwds.txt"; : > "$cwds"

# mk <name> [path]: a worktree on branch <name> with one commit of its own; echoes the HEAD.
mk() {
  local path="${2:-$wts/$1}"
  git -C "$main" worktree add -q -b "$1" "$path" origin/main
  git -C "$path" commit -q --allow-empty -m "$1"
  git -C "$path" rev-parse HEAD
}
pr() { printf '%s\n' "$*" >> "$prs"; }

h=$(mk merged);         pr merged MERGED 1 "$h"
h=$(mk closed);         pr closed CLOSED 2 "$h"
h=$(mk spaced "$wts/with space"); pr spaced MERGED 11 "$h"
h=$(mk dirty);          pr dirty MERGED 3 "$h"; printf x > "$wts/dirty/untracked.txt"
h=$(mk later);          pr later MERGED 4 "$h"; git -C "$wts/later" commit -q --allow-empty -m after-pr
h=$(mk open);           pr open OPEN 5 "$h"
h=$(mk lookupfail);     pr lookupfail ERROR
h=$(mk inuse);          pr inuse MERGED 6 "$h"; printf '%s\n' "$wts/inuse/sub/dir" >> "$cwds"
h=$(mk locked);         pr locked MERGED 7 "$h"; git -C "$main" worktree lock "$wts/locked"
h=$(mk unknownoid);     pr unknownoid MERGED 8 0123456789abcdef0123456789abcdef01234567
h=$(mk neverpushed)
h=$(mk gone);           git -C "$wts/gone" push -q -u origin gone 2>/dev/null; git -C "$main" push -q origin --delete gone 2>/dev/null
git -C "$main" worktree add -q --detach "$wts/detached" origin/main
h=$(mk missing);        pr missing MERGED 9 "$h"; rm -rf "$wts/missing"

run() {  # run <outfile> [args...] -> exit status in $rc
  local out="$1"; shift
  rc=0
  (cd "$main" && WORKTREE_REAP_PR_FILE="$prs" WORKTREE_REAP_CWDS_FILE="$cwds" bash "$tool" "$@") > "$out" 2>"$out.err" || rc=$?
}
expect() {  # expect <outfile> <branch> <verdict> <reason-prefix> <action>
  local line
  line=$(grep " branch=$2 " "$1" || true)
  case "$line" in
    *" verdict=$3 reason=$4"*" action=$5") ;;
    *) printf 'branch %s: expected verdict=%s reason=%s* action=%s; got: %s\n' "$2" "$3" "$4" "$5" "${line:-<missing>}" >&2
       failures=$((failures + 1)) ;;
  esac
}
exists() { [ -d "$1" ] || { printf 'expected %s to still exist\n' "$1" >&2; failures=$((failures + 1)); }; }
gone()   { [ ! -d "$1" ] || { printf 'expected %s to be removed\n' "$1" >&2; failures=$((failures + 1)); }; }
has_branch() { git -C "$main" show-ref -q --verify "refs/heads/$1"; }

# --- Dry run: verdicts reported, nothing touched. ---
run "$tmp_root/dry.txt"
[ "$rc" = 0 ] || { printf 'dry run exited %s\n' "$rc" >&2; failures=$((failures + 1)); }
expect "$tmp_root/dry.txt" merged REMOVE pr-merged dry-run
expect "$tmp_root/dry.txt" closed REMOVE pr-closed dry-run
expect "$tmp_root/dry.txt" gone REMOVE upstream-gone dry-run
expect "$tmp_root/dry.txt" missing PRUNE path-missing dry-run
for d in merged closed gone dirty; do exists "$wts/$d"; done
grep -q 'mode=dry-run candidates=5 removed=0 ' "$tmp_root/dry.txt" \
  || { printf 'dry-run summary wrong: %s\n' "$(tail -1 "$tmp_root/dry.txt")" >&2; failures=$((failures + 1)); }
git -C "$main" worktree list --porcelain | grep -q "^worktree $wts/missing$" \
  || { printf 'dry run pruned a missing worktree\n' >&2; failures=$((failures + 1)); }

# --- Apply. ---
run "$tmp_root/apply.txt" --apply
[ "$rc" = 0 ] || { printf 'apply exited %s: %s\n' "$rc" "$(cat "$tmp_root/apply.txt.err")" >&2; failures=$((failures + 1)); }
out="$tmp_root/apply.txt"
expect "$out" merged REMOVE pr-merged+branch-deleted removed
expect "$out" closed REMOVE pr-closed removed
expect "$out" gone REMOVE upstream-gone removed
expect "$out" missing PRUNE path-missing pruned
expect "$out" spaced REMOVE pr-merged+branch-deleted removed
expect "$out" dirty KEEP dirty kept
expect "$out" later KEEP commits-after-pr kept
expect "$out" open KEEP pr-open kept
expect "$out" lookupfail KEEP pr-lookup-failed kept
expect "$out" inuse KEEP in-use kept
expect "$out" locked KEEP locked kept
expect "$out" unknownoid KEEP head-unverified kept
expect "$out" neverpushed KEEP no-pr kept
expect "$out" - KEEP detached-head kept
gone "$wts/merged"; gone "$wts/closed"; gone "$wts/gone"
for d in dirty later open lookupfail inuse locked unknownoid neverpushed detached; do exists "$wts/$d"; done
gone "$wts/with space"
exists "$main/.git"
# Only a MERGED branch is deleted; a closed or upstream-gone branch keeps its commits reachable.
has_branch merged && { printf 'merged branch not deleted\n' >&2; failures=$((failures + 1)); }
has_branch closed || { printf 'closed branch was deleted\n' >&2; failures=$((failures + 1)); }
has_branch gone   || { printf 'upstream-gone branch was deleted\n' >&2; failures=$((failures + 1)); }
git -C "$main" worktree list --porcelain | grep -q "^worktree $wts/missing$" \
  && { printf 'missing-path worktree not pruned\n' >&2; failures=$((failures + 1)); }
# The main checkout never appears as a candidate.
grep -q "^WORKTREE $main " "$out" && { printf 'main checkout was judged\n' >&2; failures=$((failures + 1)); }

# --- Negative control: a PR lookup failure must never read as "no PR". Upstream-gone + ERROR stays. ---
h=$(mk gone2); git -C "$wts/gone2" push -q -u origin gone2 2>/dev/null; git -C "$main" push -q origin --delete gone2 2>/dev/null
pr gone2 ERROR
run "$tmp_root/err.txt" --apply
expect "$tmp_root/err.txt" gone2 KEEP pr-lookup-failed kept
exists "$wts/gone2"

# --- Untracked work counts as dirty even when config hides untracked files from `git status`. ---
git -C "$main" config status.showUntrackedFiles no
h=$(mk hidden); pr hidden MERGED 12 "$h"; printf x > "$wts/hidden/notes.txt"
run "$tmp_root/hidden.txt" --apply
expect "$tmp_root/hidden.txt" hidden KEEP dirty kept
exists "$wts/hidden"
git -C "$main" config --unset status.showUntrackedFiles

# --- Edits hidden from `git status` by index flags still count as dirty. ---
for flag in assume-unchanged skip-worktree; do
  b="flag-$flag"; h=$(mk "$b"); pr "$b" MERGED 13 "$h"
  printf base > "$wts/$b/cfg"; git -C "$wts/$b" add cfg; git -C "$wts/$b" commit -q -m cfg
  pr "$b" MERGED 13 "$(git -C "$wts/$b" rev-parse HEAD)"
  printf local-edit > "$wts/$b/cfg"; git -C "$wts/$b" update-index "--$flag" cfg
done
run "$tmp_root/flags.txt" --apply
for flag in assume-unchanged skip-worktree; do
  expect "$tmp_root/flags.txt" "flag-$flag" KEEP index-flagged kept; exists "$wts/flag-$flag"
done

# --- A status that cannot be read is not a clean status. ---
h=$(mk badindex); pr badindex MERGED 14 "$h"
printf garbage > "$(git -C "$wts/badindex" rev-parse --git-dir)/index"
run "$tmp_root/bad.txt" --apply
expect "$tmp_root/bad.txt" badindex KEEP status-failed kept
exists "$wts/badindex"

# --- Being run from inside a worktree protects that worktree even with no lsof data. ---
h=$(mk self); pr self MERGED 10 "$h"
rc=0; (cd "$wts/self" && WORKTREE_REAP_PR_FILE="$prs" WORKTREE_REAP_CWDS_FILE=/dev/null bash "$tool" --apply) > "$tmp_root/self.txt" 2>&1 || rc=$?
expect "$tmp_root/self.txt" self KEEP in-use kept
exists "$wts/self"

# --- Usage errors exit 2. ---
rc=0; bash "$tool" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { printf 'unknown flag exited %s, expected 2\n' "$rc" >&2; failures=$((failures + 1)); }

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'WORKTREE REAP SELFTEST: PASS'; completed=1; exit 0
fi
printf '%s\n' 'WORKTREE REAP SELFTEST: FAIL'; completed=1; exit 1
