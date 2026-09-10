#!/usr/bin/env bash
# Hermetic regression test for name-hygiene.sh. Builds throwaway git repos in $TMPDIR; never
# reads the real one. The denied token used throughout is the synthetic canary from the shipped
# denylist, so this file never has to contain a real private name.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tool="$root/scripts/name-hygiene.sh"
shipped_denylist="$root/scripts/testdata/name-hashes.txt"
# Assembled, never written literally: this file is itself scanned by the gate below, and a denied
# token spelled out here would make the check permanently red on its own fixture. Exempting the
# file would be the allowlist the rule forbids, so the literal simply never exists.
canary=$(printf 'zzz-%s-name' 'canary')
canary_cased=$(printf 'ZZZ-%s-Name' 'Canary')
completed=0
workdir=''
trap 'status=$?; [ "$completed" = 1 ] || status=1; [ -z "$workdir" ] || rm -rf "$workdir"; exit "$status"' EXIT HUP INT TERM

failures=0
pass() { printf '%s: PASS\n' "$1"; }
fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }

workdir=$(mktemp -d "${TMPDIR:-/tmp}/name-hygiene-selftest.XXXXXX") || exit 1

# A repo with one clean tracked file and one clean commit message.
make_repo() {
  local dir=$1
  mkdir -p "$dir" || return 1
  git -C "$dir" init --quiet 2>/dev/null || return 1
  git -C "$dir" config user.email selftest@example.invalid
  git -C "$dir" config user.name 'Selftest'
  printf '%s\n' 'AudioApp is the pseudonym for a native audio app.' > "$dir/notes.md"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit --quiet -m 'docs: describe AudioApp' >/dev/null 2>&1
}

expect_rc() {
  local name=$1 expected=$2; shift 2
  local output rc
  output=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$expected" ]; then pass "$name"; else fail "$name" "rc=$rc (want $expected) output=$output"; fi
}

expect_rc_and_text() {
  local name=$1 expected=$2 needle=$3; shift 3
  local output rc
  output=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$expected" ] && printf '%s' "$output" | grep -Fq "$needle"; then
    pass "$name"
  else
    fail "$name" "rc=$rc (want $expected) missing '$needle' in: $output"
  fi
}

clean="$workdir/clean"
make_repo "$clean" || { printf '%s\n' 'NAME HYGIENE SELFTEST: FAIL (could not build fixture)'; completed=1; exit 1; }
expect_rc 'clean repo passes' 0 bash "$tool" --root "$clean" --denylist "$shipped_denylist"

# NEGATIVE CONTROL: the same repo, one denied token planted. A checker that cannot go red here
# is decoration (rules/verification-integrity.md).
dirty="$workdir/dirty"
make_repo "$dirty" || exit 1
printf 'the %s appears here\n' "$canary" > "$dirty/leak.md"
git -C "$dirty" add -A >/dev/null 2>&1
git -C "$dirty" commit --quiet -m 'docs: add a file' >/dev/null 2>&1
expect_rc_and_text 'planted token in a tracked file fails' 1 "leak.md:1" \
  bash "$tool" --root "$dirty" --denylist "$shipped_denylist" --no-history
expect_rc_and_text 'the failure names the pseudonym to use' 1 'synthetic canary' \
  bash "$tool" --root "$dirty" --denylist "$shipped_denylist" --no-history

# A hyphen-separated part must be caught even when the whole compound is not denied.
part="$workdir/part"
make_repo "$part" || exit 1
printf 'prefix-%s-suffix\n' "$canary" > "$part/compound.md"
git -C "$part" add -A >/dev/null 2>&1
git -C "$part" commit --quiet -m 'docs: compound' >/dev/null 2>&1
expect_rc 'hyphen parts of a compound are checked' 1 \
  bash "$tool" --root "$part" --denylist "$shipped_denylist" --no-history

# Casing must not launder a name.
cased="$workdir/cased"
make_repo "$cased" || exit 1
printf '%s\n' "$canary_cased" > "$cased/cased.md"
git -C "$cased" add -A >/dev/null 2>&1
git -C "$cased" commit --quiet -m 'docs: cased' >/dev/null 2>&1
expect_rc 'uppercase form is caught' 1 \
  bash "$tool" --root "$cased" --denylist "$shipped_denylist" --no-history

# A commit message is as public as a file, and --no-history must not hide one.
msg="$workdir/msg"
make_repo "$msg" || exit 1
printf 'clean body\n' > "$msg/ok.md"
git -C "$msg" add -A >/dev/null 2>&1
git -C "$msg" commit --quiet -m "fix: repair the $canary path" >/dev/null 2>&1
expect_rc_and_text 'denied token in a commit message fails' 1 'commit ' \
  bash "$tool" --root "$msg" --denylist "$shipped_denylist"
expect_rc '--no-history skips commit messages' 0 \
  bash "$tool" --root "$msg" --denylist "$shipped_denylist" --no-history

# An instrument that cannot see must not report clean.
expect_rc_and_text 'missing denylist is a setup error, not a pass' 2 'denylist not found' \
  bash "$tool" --root "$clean" --denylist "$workdir/absent.txt"
: > "$workdir/empty.txt"
expect_rc_and_text 'denylist with no hashes is a setup error' 2 'no hashes' \
  bash "$tool" --root "$clean" --denylist "$workdir/empty.txt"
printf '%s\n' '# only a comment' > "$workdir/comments.txt"
expect_rc 'comment-only denylist is a setup error' 2 \
  bash "$tool" --root "$clean" --denylist "$workdir/comments.txt"
expect_rc_and_text 'a non-repository is a setup error' 2 'not a git repository' \
  bash "$tool" --root "$workdir" --denylist "$shipped_denylist"

# The shipped denylist must never regress into holding plaintext.
if grep -nvE '^[[:space:]]*(#.*)?$|^[0-9a-f]{64}[[:space:]]*(#.*)?$' "$shipped_denylist" >/dev/null 2>&1; then
  fail 'shipped denylist holds only hashes and comments' "unexpected line in $shipped_denylist"
else
  pass 'shipped denylist holds only hashes and comments'
fi

# THE GATE ITSELF. Everything above proves the checker can go red against fixtures; this runs it
# against THIS repository's tracked tree, which is what makes registering the selftest in
# scripts/verify.sh actually gate anything. Without it the suite is green while the tree leaks
# (measured: a planted name passed a full verify run — rules/verification-integrity.md).
#
# Tree only, deliberately. The three surfaces are covered in three places and this is the daily
# one: new commit messages are checked by the commit agent before push (agents/commit.md Step 8),
# and full history is checked once, at a history rewrite. A gate that scanned all history would be
# red for reasons no current change can fix.
real_output=$(bash "$tool" --root "$root" --no-history 2>&1); real_rc=$?
if [ "$real_rc" -eq 0 ]; then
  pass 'this repository'\''s tracked tree is clean'
else
  fail 'this repository'\''s tracked tree is clean' "$real_output"
fi

if [ "$failures" -eq 0 ]; then printf '%s\n' 'NAME HYGIENE SELFTEST: PASS'; completed=1; exit 0; fi
printf '%s\n' 'NAME HYGIENE SELFTEST: FAIL'; completed=1; exit 1
