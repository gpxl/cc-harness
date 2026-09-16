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
canary_hash=$(awk '/synthetic canary/ { print $1; exit }' "$shipped_denylist")
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

# --range checks only outgoing history. It takes precedence over --no-history so an accidental
# combination cannot silently omit the surface the caller explicitly selected.
ranged="$workdir/ranged"
make_repo "$ranged" || exit 1
printf 'clean body\n' > "$ranged/history.md"
git -C "$ranged" add -A >/dev/null 2>&1
git -C "$ranged" commit --quiet -m "docs: record $canary" >/dev/null 2>&1
rm "$ranged/history.md"
git -C "$ranged" add -A >/dev/null 2>&1
git -C "$ranged" commit --quiet -m 'docs: remove historical note' >/dev/null 2>&1
expect_rc 'outgoing clean range skips historical message' 0 \
  bash "$tool" --root "$ranged" --denylist "$shipped_denylist" --range 'HEAD~1..HEAD'
expect_rc 'range takes precedence over no-history' 1 \
  bash "$tool" --root "$ranged" --denylist "$shipped_denylist" --range 'HEAD~2..HEAD~1' --no-history

# A private name in a repository path is a public leak even when its contents are clean. Build
# the filename at runtime: this selftest is scanned by the same gate it exercises.
path_leak="$workdir/path-leak"
make_repo "$path_leak" || exit 1
printf 'clean contents\n' > "$path_leak/$canary.md"
git -C "$path_leak" add -A >/dev/null 2>&1
git -C "$path_leak" commit --quiet -m 'docs: add path fixture' >/dev/null 2>&1
expect_rc_and_text 'denied token in a tracked path fails' 1 ':path:' \
  bash "$tool" --root "$path_leak" --denylist "$shipped_denylist" --no-history

# Large text remains covered, including a token split across the scanner's chunk boundary.
large="$workdir/large"
make_repo "$large" || exit 1
{
  head -c 65534 < /dev/zero | tr '\0' ' '
  printf '%s ' "$canary"
  dd if=/dev/zero bs=1m count=5 2>/dev/null | tr '\0' 'a'
} > "$large/large.md"
git -C "$large" add -A >/dev/null 2>&1
git -C "$large" commit --quiet -m 'docs: add large fixture' >/dev/null 2>&1
expect_rc_and_text 'large text file is scanned across chunk boundary' 1 'large.md:1' \
  bash "$tool" --root "$large" --denylist "$shipped_denylist" --no-history

# A git diagnostic is evidence that commit messages were not scanned, never a clean result.
fakebin="$workdir/fakebin"
mkdir -p "$fakebin" || exit 1
real_git=$(command -v git)
printf '%s\n' '#!/usr/bin/env bash' 'if [ "$3" = log ]; then printf "%s\\n" "injected git log failure" >&2; exit 128; fi' \
  "exec \"$real_git\" \"\$@\"" > "$fakebin/git"
chmod +x "$fakebin/git"
expect_rc_and_text 'failed history read is a setup error, not a pass' 2 'injected git log failure' \
  env "PATH=$fakebin:$PATH" bash "$tool" --root "$clean" --denylist "$shipped_denylist"

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

# The denylist contains only hashes, but its comments are still a public surface. It must not
# become an allowlisted path merely because the scanner reads its configuration from it.
comment_denylist="$workdir/comment-denylist"
make_repo "$comment_denylist" || exit 1
mkdir -p "$comment_denylist/scripts" || exit 1
printf '%s # comment carries %s\n' "$canary_hash" "$canary" > "$comment_denylist/scripts/denylist.txt"
expect_rc_and_text 'denied token in a denylist comment fails' 1 'scripts/denylist.txt:1' \
  bash "$tool" --root "$comment_denylist" --denylist "$comment_denylist/scripts/denylist.txt" --no-history

# `git ls-files --cached` includes an unstaged deletion, but `git add -A` would publish no file
# at that path. The absent file is therefore skipped, without treating it as a coverage gap.
deleted="$workdir/deleted"
make_repo "$deleted" || exit 1
printf 'removed before staging\n' > "$deleted/vanished.md"
git -C "$deleted" add -A >/dev/null 2>&1
git -C "$deleted" commit --quiet -m 'docs: add removable fixture' >/dev/null 2>&1
rm "$deleted/vanished.md"
expect_rc 'unstaged tracked deletion is skipped' 0 \
  bash "$tool" --root "$deleted" --denylist "$shipped_denylist" --no-history

# A present unreadable file remains a setup error: the gate must not claim clean when coverage
# is incomplete. Restore permissions immediately so the fixture can be cleaned up.
unreadable="$workdir/unreadable"
make_repo "$unreadable" || exit 1
printf 'present but protected\n' > "$unreadable/protected.md"
git -C "$unreadable" add -A >/dev/null 2>&1
git -C "$unreadable" commit --quiet -m 'docs: add protected fixture' >/dev/null 2>&1
chmod 000 "$unreadable/protected.md"
expect_rc_and_text 'present unreadable tracked file is a setup error' 2 'cannot scan protected.md' \
  bash "$tool" --root "$unreadable" --denylist "$shipped_denylist" --no-history
chmod 644 "$unreadable/protected.md"

# The shipped denylist must never regress into holding plaintext.
if grep -nvE '^[[:space:]]*(#.*)?$|^[0-9a-f]{64}[[:space:]]*(#.*)?$' "$shipped_denylist" >/dev/null 2>&1; then
  fail 'shipped denylist holds only hashes and comments' "unexpected line in $shipped_denylist"
else
  pass 'shipped denylist holds only hashes and comments'
fi

# A ticket namespace is denied across every number: denying one id alone would let the next
# ticket in the same private namespace through (round-3 review finding).
ticket="$workdir/ticket"
make_repo "$ticket" || exit 1
tk_a=$(printf 'zzc-%s' '2823'); tk_b=$(printf 'zzc-%s' '9999'); tk_c=$(printf 'zzc-%s' '8rn')
printf '%s\n' "$tk_a" > "$ticket/a.md"
git -C "$ticket" add -A >/dev/null 2>&1
git -C "$ticket" commit --quiet -m 'docs: ticket a' >/dev/null 2>&1
tk_denylist="$workdir/ticket-hashes.txt"
printf '%s  # ZZC-<n> (synthetic ticket namespace)\n' \
  "$(printf '%s' "$(printf 'zzc-%s' '#')" | shasum -a 256 | cut -d' ' -f1)" > "$tk_denylist"
expect_rc 'a denied ticket namespace catches the recorded id' 1 \
  bash "$tool" --root "$ticket" --denylist "$tk_denylist" --no-history
printf '%s\n' "$tk_b" > "$ticket/a.md"
expect_rc 'the same namespace with a different number also fails' 1 \
  bash "$tool" --root "$ticket" --denylist "$tk_denylist" --no-history
printf '%s\n' "$tk_c" > "$ticket/a.md"
expect_rc 'the same namespace with an alphanumeric suffix also fails' 1 \
  bash "$tool" --root "$ticket" --denylist "$tk_denylist" --no-history
printf '%s\n' 'an ordinary hyphenated word like audio-app and a bare zzc' > "$ticket/a.md"
expect_rc 'the bare namespace word alone does not false-positive' 0 \
  bash "$tool" --root "$ticket" --denylist "$tk_denylist" --no-history

# THE GATE ITSELF. Everything above proves the checker can go red against fixtures; this runs it
# against THIS repository, which is what makes registering the selftest in scripts/verify.sh
# actually gate anything. Without it the suite is green while the tree leaks (measured: a planted
# name passed a full verify run — rules/verification-integrity.md).
#
# Tracked tree plus the commit messages THIS BRANCH adds, and no further back. Scanning all
# history would be red for reasons no current change can fix, which is a gate nobody can act on;
# scanning the tree alone leaves commit messages to the commit agent's own diligence
# (agents/commit.md Step 8), and a message is as public as a file. The branch range is the part a
# leak can still be removed from by amending, so it is the part worth refusing.
gate_base=''
for candidate in origin/main main; do
  if git -C "$root" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1; then
    gate_base=$candidate
    break
  fi
done
if [ -z "$gate_base" ]; then
  # An instrument that cannot resolve its own baseline must not report clean.
  fail 'this repository is clean' "neither origin/main nor main resolves in $root, so the branch's commit messages cannot be scoped; run 'git fetch origin main' and re-run"
else
  real_output=$(bash "$tool" --root "$root" --range "$gate_base..HEAD" 2>&1); real_rc=$?
  # The reported scope is asserted, not just the verdict: a silent revert to --no-history would
  # still exit 0 here while no longer reading a single commit message.
  if [ "$real_rc" -eq 0 ] && printf '%s' "$real_output" | grep -Fq "commit messages in $gate_base..HEAD"; then
    pass "this repository is clean, tree and commit messages in $gate_base..HEAD"
  else
    fail "this repository is clean, tree and commit messages in $gate_base..HEAD" "rc=$real_rc output=$real_output"
  fi
  # Which base resolved is part of the result, not an implementation detail: main can lag the
  # remote, and a range measured against a stale base silently covers fewer commits.
  if [ "$gate_base" = 'origin/main' ]; then
    pass 'the branch range is measured against origin/main'
  else
    fail 'the branch range is measured against origin/main' "resolved $gate_base instead; run 'git fetch origin main'"
  fi
  # The gate runs BEFORE the commit agent writes this branch's commits, so at gate time the range
  # is usually empty. That is legitimate and it is why the count is printed rather than implied:
  # agents/commit.md Step 8 is the primary check on a message, this is the backstop that catches
  # anything already committed.
  # The count is asserted against git's own answer, so deleting the counter cannot leave the suite
  # green: a printed 0 must mean the range really held no commits.
  range_commits=$(git -C "$root" rev-list --count "$gate_base..HEAD" 2>/dev/null || printf '0')
  reported=$(printf '%s' "$real_output" | sed -nE 's/.*and ([0-9]+) commit messages.*/\1/p')
  if [ "$reported" = "$range_commits" ]; then
    pass "the scan reports the number of commit messages the range holds ($range_commits)"
  else
    fail 'the scan reports the number of commit messages the range holds' "reported=$reported git=$range_commits output=$real_output"
  fi
  printf 'gate scope: %s\n' "$(printf '%s' "$real_output" | tail -1)"
fi

if [ "$failures" -eq 0 ]; then printf '%s\n' 'NAME HYGIENE SELFTEST: PASS'; completed=1; exit 0; fi
printf '%s\n' 'NAME HYGIENE SELFTEST: FAIL'; completed=1; exit 1
