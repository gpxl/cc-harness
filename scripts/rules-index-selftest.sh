#!/usr/bin/env bash
# Every file in rules/ must have a one-line entry in the [Rules] index of global/CLAUDE.md, and
# every entry must name a file that exists.
#
# CLAUDE.md § Contributing states the requirement and the reason: "a rule that isn't indexed is a
# file nothing loads". That failure is silent and invisible — the rule file is present, readable,
# correct, and simply never reaches a session — which is the shape of failure the harness's own
# verification-integrity rule exists to refuse. Until this check existed the requirement held by
# discipline alone: 18 rules and 18 entries, in sync because someone remembered each time.
#
# Fixture rows first, so the comparison is proven able to go red; the real repository last, which
# is what makes registering this in scripts/verify.sh gate anything.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
completed=0
workdir=''
trap 'status=$?; [ "$completed" = 1 ] || status=1; [ -z "$workdir" ] || rm -rf "$workdir"; exit "$status"' EXIT HUP INT TERM

failures=0
pass() { printf '%s: PASS\n' "$1"; }
fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }

workdir=$(mktemp -d "${TMPDIR:-/tmp}/rules-index-selftest.XXXXXX") || exit 1

# The index lives in a fenced block that also holds [Scripts], [Hooks] and the rest, so the read is
# scoped to the [Rules] section: it starts at the [Rules] marker and stops at the next [Section].
index_entries() {  # index_entries <claude-md> -> sorted rule filenames named in the index
  # Terminate on ANY following section, not only an uppercase-initial one: a terminator that does
  # not fire reads a later section's lines as [Rules] entries and reports an unindexed rule as
  # indexed, which is the silent pass this check exists to prevent.
  sed -n '/^\[Rules\]/,/^\[[^]]/p' "$1" | sed -nE 's/^\|([A-Za-z0-9._-]+\.md):.*/\1/p' | sort -u
}

rule_files() {  # rule_files <rules-dir> -> sorted rule paths on disk, relative to the directory
  # No depth limit: a rule filed in a subdirectory is still a rule, and hiding it from both
  # directions of this check would make it indexable and unindexed at the same time.
  ( cd -- "$1" 2>/dev/null && find . -name '*.md' -type f | sed 's|^\./||' | sort -u )
}

# Prints every discrepancy, one per line, and returns 1 when there is at least one.
check_index() {  # check_index <rules-dir> <claude-md>
  local rules_dir=$1 claude_md=$2 entries files problems=0 name
  [ -d "$rules_dir" ] || { printf 'rules directory not found: %s\n' "$rules_dir"; return 1; }
  [ -f "$claude_md" ] || { printf 'index file not found: %s\n' "$claude_md"; return 1; }
  entries=$(index_entries "$claude_md")
  files=$(rule_files "$rules_dir")
  # An empty index is a broken reader, not an empty repo: refuse rather than report agreement.
  if [ -z "$entries" ] && [ -n "$files" ]; then
    printf 'the [Rules] index is empty or unreadable in %s\n' "$claude_md"
    return 1
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$entries" | grep -Fqx "$name" || {
      printf 'rules/%s has no entry in the [Rules] index of %s — a rule that is not indexed is a file nothing loads.\n' "$name" "$claude_md"
      printf '  Add a line of exactly this shape under [Rules]: |%s: <one line about it>\n' "$name"
      problems=$((problems + 1))
    }
  done <<EOF
$files
EOF
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$files" | grep -Fqx "$name" || {
      printf 'the [Rules] index names %s, which does not exist in rules/\n' "$name"
      problems=$((problems + 1))
    }
  done <<EOF
$entries
EOF
  [ "$problems" -eq 0 ]
}

# --- fixtures -----------------------------------------------------------------------------------

make_fixture() {  # make_fixture <dir> <indexed-names...>
  local dir=$1; shift
  mkdir -p "$dir/rules" "$dir/global" || return 1
  printf '%s\n' 'alpha.md' 'beta.md' | while IFS= read -r f; do printf 'rule\n' > "$dir/rules/$f"; done
  {
    printf '%s\n' '```'
    printf '%s\n' '[Rules]|root: ~/.claude/rules/'
    printf '%s\n' '|Always loaded:'
    for name in "$@"; do printf '|%s: one line about it\n' "$name"; done
    printf '%s\n' '[Scripts]|root: scripts/'
    printf '%s\n' '|some-script: not a rule and must not be read as one'
    printf '%s\n' '```'
  } > "$dir/global/CLAUDE.md"
}

expect() {  # expect <name> <expected-rc> <needle-or-empty> <rules-dir> <claude-md>
  local name=$1 expected=$2 needle=$3 out rc
  out=$(check_index "$4" "$5" 2>&1); rc=$?
  if [ "$rc" -ne "$expected" ]; then
    fail "$name" "rc=$rc (want $expected) output=$out"
    return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -Fq "$needle"; then
    fail "$name" "missing '$needle' in: $out"
    return
  fi
  pass "$name"
}

ok="$workdir/ok"; make_fixture "$ok" alpha.md beta.md
expect 'a fully indexed rules directory passes' 0 '' "$ok/rules" "$ok/global/CLAUDE.md"

missing="$workdir/missing"; make_fixture "$missing" alpha.md
expect 'an unindexed rule fails, named' 1 'rules/beta.md has no entry' "$missing/rules" "$missing/global/CLAUDE.md"

stale="$workdir/stale"; make_fixture "$stale" alpha.md beta.md gamma.md
expect 'an index entry with no rule file fails, named' 1 'index names gamma.md' "$stale/rules" "$stale/global/CLAUDE.md"

empty="$workdir/empty"; make_fixture "$empty"
expect 'an empty index is refused, not read as agreement' 1 'index is empty or unreadable' "$empty/rules" "$empty/global/CLAUDE.md"

# A script named in a neighbouring section must not be mistaken for a rule entry.
bleed="$workdir/bleed"; make_fixture "$bleed" alpha.md beta.md
printf '%s\n' '|stray-rule.md: this line sits under [Scripts], not [Rules]' >> "$bleed/global/CLAUDE.md"
expect 'an entry outside the [Rules] section is not counted' 0 '' "$bleed/rules" "$bleed/global/CLAUDE.md"

# A section header that does not start with a capital must still end the [Rules] range.
lower="$workdir/lower"; make_fixture "$lower" alpha.md beta.md
python3 - "$lower/global/CLAUDE.md" <<'PYEOF'
import sys
p = sys.argv[1]
text = open(p).read().replace('[Scripts]|root: scripts/', '[scripts]|root: scripts/\n|stray.md: lives under a lowercase section, not under [Rules]')
open(p, 'w').write(text)
PYEOF
expect 'a lowercase section header still ends the [Rules] range' 0 '' "$lower/rules" "$lower/global/CLAUDE.md"
# Asserted directly as well: with the old `^\[[A-Z]` terminator the range ran past the lowercase
# header and stray.md was read as a [Rules] entry, which is how an unindexed rule reads as indexed.
if index_entries "$lower/global/CLAUDE.md" | grep -Fqx 'stray.md'; then
  fail 'an entry under a lowercase section is not read as a rule entry' 'stray.md was counted'
else
  pass 'an entry under a lowercase section is not read as a rule entry'
fi

# A rule filed in a subdirectory is visible to both directions.
nested="$workdir/nested"; make_fixture "$nested" alpha.md beta.md
mkdir -p "$nested/rules/sub"; printf 'rule\n' > "$nested/rules/sub/gamma.md"
expect 'a rule in a subdirectory is not invisible' 1 'sub/gamma.md has no entry' "$nested/rules" "$nested/global/CLAUDE.md"

expect 'a missing rules directory is refused' 1 'rules directory not found' "$workdir/absent" "$ok/global/CLAUDE.md"
expect 'a missing index file is refused' 1 'index file not found' "$ok/rules" "$workdir/absent/CLAUDE.md"

# --- the real repository --------------------------------------------------------------------

real_out=$(check_index "$root/rules" "$root/global/CLAUDE.md" 2>&1); real_rc=$?
real_count=$(index_entries "$root/global/CLAUDE.md" | grep -c . || true)
if [ "$real_rc" -eq 0 ] && [ "$real_count" -gt 0 ]; then
  pass "every rule in this repository is indexed ($real_count entries)"
else
  fail 'every rule in this repository is indexed' "rc=$real_rc entries=$real_count $real_out"
fi

if [ "$failures" -eq 0 ]; then printf '%s\n' 'RULES INDEX SELFTEST: PASS'; completed=1; exit 0; fi
printf '%s\n' 'RULES INDEX SELFTEST: FAIL'; completed=1; exit 1
