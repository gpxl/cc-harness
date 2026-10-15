#!/usr/bin/env bash
# Every file in rules/ must have a one-line entry in the [Rules] index of global/CLAUDE.md, and
# every entry must name a file that exists. Each entry's group (Always loaded / Path-scoped) must
# also agree with whether the rule carries a non-empty `paths:` frontmatter list.
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
  sed -n '/^\[Rules\]/,/^\[[^]]/p' "$1" | sed -nE 's/^\|([A-Za-z0-9._/-]+\.md):.*/\1/p' | sort -u
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

# The index splits [Rules] into `|Always loaded:` and `|Path-scoped ...` groups, and that split is
# a claim about each file's frontmatter: a rule with a `paths:` list loads only on a matching file,
# one without it loads every turn. When the two disagree the index lies about load cost or, worse,
# about whether a rule is in context at all — a "path-scoped" rule whose frontmatter was dropped
# silently becomes always loaded, and an "always loaded" rule that gained `paths:` silently stops
# loading. Neither shows up in the presence check above.
index_groups() {  # index_groups <claude-md> -> "<always|scoped|none> <name>" per [Rules] entry
  sed -n '/^\[Rules\]/,/^\[[^]]/p' "$1" | awk '
    /^\|Always loaded:/ { group = "always"; next }
    /^\|Path-scoped/    { group = "scoped"; next }
    match($0, /^\|[A-Za-z0-9._\/-]+\.md:/) { print (group == "" ? "none" : group), substr($0, 2, RLENGTH - 2) }'
}

has_paths_frontmatter() {  # has_paths_frontmatter <file> -> 0 when line 1 opens a frontmatter block holding a non-empty paths: list
  awk '
    NR == 1 { if ($0 != "---") exit 1; next }
    $0 == "---" { exit (items > 0 ? 0 : 1) }
    /^paths:[[:space:]]*$/ { inpaths = 1; next }
    inpaths && /^[[:space:]]+-[[:space:]]*[^[:space:]]/ { items++; next }
    /^[^[:space:]]/ { inpaths = 0 }
    END { if (NR < 2) exit 1 }' "$1"
}

check_scoping() {  # check_scoping <rules-dir> <claude-md> -> prints each disagreement, 1 when any
  local rules_dir=$1 claude_md=$2 problems=0 group name file
  while read -r group name; do
    [ -n "$name" ] || continue
    file="$rules_dir/$name"
    [ -f "$file" ] || continue  # a missing file is check_index's finding, not this one
    case "$group" in
      always)
        if has_paths_frontmatter "$file"; then
          printf 'rules/%s is indexed under Always loaded but has a paths: frontmatter list — it loads only on a matching file; move its entry under Path-scoped\n' "$name"
          problems=$((problems + 1))
        fi ;;
      scoped)
        if ! has_paths_frontmatter "$file"; then
          printf 'rules/%s is indexed under Path-scoped but has no non-empty paths: frontmatter — it loads every turn; add the paths: list or move its entry under Always loaded\n' "$name"
          problems=$((problems + 1))
        fi ;;
      *)
        printf 'rules/%s is indexed before any |Always loaded: or |Path-scoped group marker\n' "$name"
        problems=$((problems + 1)) ;;
    esac
  done <<EOF
$(index_groups "$claude_md")
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

# And the remedy the failure message offers must actually work: a gate whose only advertised fix
# cannot turn it green is a gate nobody can clear.
nested_ok="$workdir/nested-ok"; make_fixture "$nested_ok" alpha.md beta.md sub/gamma.md
mkdir -p "$nested_ok/rules/sub"; printf 'rule\n' > "$nested_ok/rules/sub/gamma.md"
expect 'a correctly indexed rule in a subdirectory passes' 0 '' "$nested_ok/rules" "$nested_ok/global/CLAUDE.md"

expect 'a missing rules directory is refused' 1 'rules directory not found' "$workdir/absent" "$ok/global/CLAUDE.md"
expect 'a missing index file is refused' 1 'index file not found' "$ok/rules" "$workdir/absent/CLAUDE.md"

# --- index group vs frontmatter -----------------------------------------------------------------

expect_scoping() {  # expect_scoping <name> <expected-rc> <needle-or-empty> <rules-dir> <claude-md>
  local name=$1 expected=$2 needle=$3 out rc
  out=$(check_scoping "$4" "$5" 2>&1); rc=$?
  if [ "$rc" -ne "$expected" ]; then fail "$name" "rc=$rc (want $expected) output=$out"; return; fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -Fq "$needle"; then fail "$name" "missing '$needle' in: $out"; return; fi
  pass "$name"
}

make_scoped_fixture() {  # make_scoped_fixture <dir>: alpha always loaded, beta path-scoped, both agreeing
  local dir=$1
  mkdir -p "$dir/rules" "$dir/global" || return 1
  printf '# Alpha\nrule\n' > "$dir/rules/alpha.md"
  printf -- '---\npaths:\n  - "**/*beta*"\n---\n# Beta\nrule\n' > "$dir/rules/beta.md"
  {
    printf '%s\n' '```' '[Rules]|root: ~/.claude/rules/' '|Always loaded:' '|alpha.md: one line'
    printf '%s\n' '|Path-scoped (load only on a matching file):' '|beta.md: one line — *beta*'
    printf '%s\n' '[Scripts]|root: scripts/' '```'
  } > "$dir/global/CLAUDE.md"
}

sc_ok="$workdir/sc-ok"; make_scoped_fixture "$sc_ok"
expect_scoping 'index groups that match frontmatter pass' 0 '' "$sc_ok/rules" "$sc_ok/global/CLAUDE.md"

# Negative control: a rule moved back to always-loaded (frontmatter dropped) without an index update.
sc_dropped="$workdir/sc-dropped"; make_scoped_fixture "$sc_dropped"
printf '# Beta\nrule\n' > "$sc_dropped/rules/beta.md"
expect_scoping 'a Path-scoped entry whose rule has no paths: frontmatter fails, named' 1 'rules/beta.md is indexed under Path-scoped' "$sc_dropped/rules" "$sc_dropped/global/CLAUDE.md"

# An empty paths: list is no scope at all: it must not pass as path-scoped.
sc_emptylist="$workdir/sc-emptylist"; make_scoped_fixture "$sc_emptylist"
printf -- '---\npaths:\n---\n# Beta\n' > "$sc_emptylist/rules/beta.md"
expect_scoping 'a paths: key with no globs does not count as path-scoped' 1 'rules/beta.md is indexed under Path-scoped' "$sc_emptylist/rules" "$sc_emptylist/global/CLAUDE.md"

# A paths: list outside a leading frontmatter block is prose, not scope.
sc_body="$workdir/sc-body"; make_scoped_fixture "$sc_body"
printf -- '# Beta\n---\npaths:\n  - "**/*beta*"\n---\n' > "$sc_body/rules/beta.md"
expect_scoping 'a paths: list that is not leading frontmatter does not count' 1 'rules/beta.md is indexed under Path-scoped' "$sc_body/rules" "$sc_body/global/CLAUDE.md"

# Negative control: a rule that gained paths: but whose index entry still says Always loaded.
sc_gained="$workdir/sc-gained"; make_scoped_fixture "$sc_gained"
printf -- '---\npaths:\n  - "**/*alpha*"\n---\n# Alpha\n' > "$sc_gained/rules/alpha.md"
expect_scoping 'an Always loaded entry whose rule has paths: frontmatter fails, named' 1 'rules/alpha.md is indexed under Always loaded' "$sc_gained/rules" "$sc_gained/global/CLAUDE.md"

# Negative control: the index entry moved to Always loaded while the frontmatter still scopes it.
sc_moved="$workdir/sc-moved"; make_scoped_fixture "$sc_moved"
python3 - "$sc_moved/global/CLAUDE.md" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read().replace('|beta.md: one line — *beta*\n', '').replace('|alpha.md: one line\n', '|alpha.md: one line\n|beta.md: one line\n')
open(p, 'w').write(t)
PYEOF
expect_scoping 'a scoped rule listed under Always loaded fails, named' 1 'rules/beta.md is indexed under Always loaded' "$sc_moved/rules" "$sc_moved/global/CLAUDE.md"

# An entry above both group markers has no stated load cost.
sc_ungrouped="$workdir/sc-ungrouped"; make_scoped_fixture "$sc_ungrouped"
python3 - "$sc_ungrouped/global/CLAUDE.md" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read().replace('|Always loaded:\n|alpha.md: one line\n', '|alpha.md: one line\n|Always loaded:\n')
open(p, 'w').write(t)
PYEOF
expect_scoping 'an entry before any group marker fails, named' 1 'rules/alpha.md is indexed before any' "$sc_ungrouped/rules" "$sc_ungrouped/global/CLAUDE.md"

# --- the real repository --------------------------------------------------------------------

scope_out=$(check_scoping "$root/rules" "$root/global/CLAUDE.md" 2>&1); scope_rc=$?
scoped_count=$(index_groups "$root/global/CLAUDE.md" | grep -c '^scoped ' || true)
always_count=$(index_groups "$root/global/CLAUDE.md" | grep -c '^always ' || true)
if [ "$scope_rc" -eq 0 ] && [ "$scoped_count" -gt 0 ] && [ "$always_count" -gt 0 ]; then
  pass "every index group in this repository matches its rule's frontmatter ($always_count always loaded, $scoped_count path-scoped)"
else
  fail 'every index group in this repository matches its rule frontmatter' "rc=$scope_rc always=$always_count scoped=$scoped_count $scope_out"
fi

real_out=$(check_index "$root/rules" "$root/global/CLAUDE.md" 2>&1); real_rc=$?
real_count=$(index_entries "$root/global/CLAUDE.md" | grep -c . || true)
if [ "$real_rc" -eq 0 ] && [ "$real_count" -gt 0 ]; then
  pass "every rule in this repository is indexed ($real_count entries)"
else
  fail 'every rule in this repository is indexed' "rc=$real_rc entries=$real_count $real_out"
fi

if [ "$failures" -eq 0 ]; then printf '%s\n' 'RULES INDEX SELFTEST: PASS'; completed=1; exit 0; fi
printf '%s\n' 'RULES INDEX SELFTEST: FAIL'; completed=1; exit 1
