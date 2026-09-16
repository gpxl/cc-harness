#!/usr/bin/env bash
# Selftest for scripts/verify.sh — the gate's entry point must itself be falsifiable.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
verify=$root/scripts/verify.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cc-harness-verify-selftest.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
failures=0

pass() { printf '%s: PASS\n' "$1"; }
fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }

# 1. Zero resolved selftests must FAIL, never PASS(0).
out=$(CC_HARNESS_SELFTESTS=" " CC_HARNESS_VERIFY_LOG_DIR="$tmp/l1" bash "$verify" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -Fq 'no selftests resolved'; then
  pass 'empty list fails'
else
  fail 'empty list fails' "rc=$rc out=$out"
fi

# 2. The reported per-test exit code is the real one (negative control: exit 3 must print "exit 3").
mkdir -p "$tmp/fake"
printf '#!/usr/bin/env bash\nexit 3\n' > "$tmp/fake/exit3-selftest.sh"
out=$(CC_HARNESS_SELFTESTS="$tmp/fake/exit3-selftest.sh" CC_HARNESS_VERIFY_LOG_DIR="$tmp/l2" bash "$verify" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -Fq 'exit3-selftest: FAIL (exit 3)'; then
  pass 'real exit code reported'
else
  fail 'real exit code reported' "rc=$rc out=$out"
fi

# 3. Positive control: one passing selftest → PASS (1 selftests), exit 0.
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/fake/ok-selftest.sh"
out=$(CC_HARNESS_SELFTESTS="$tmp/fake/ok-selftest.sh" CC_HARNESS_VERIFY_LOG_DIR="$tmp/l3" bash "$verify" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Fq 'CC-HARNESS VERIFY: PASS (1 selftests)'; then
  pass 'single passing selftest passes'
else
  fail 'single passing selftest passes' "rc=$rc out=$out"
fi

# 4. A missing selftest file is a FAIL, not a skip.
out=$(CC_HARNESS_SELFTESTS="scripts/does-not-exist-selftest.sh" CC_HARNESS_VERIFY_LOG_DIR="$tmp/l4" bash "$verify" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -Fq 'does-not-exist-selftest: FAIL'; then
  pass 'missing selftest fails'
else
  fail 'missing selftest fails' "rc=$rc out=$out"
fi

# 5. verify.sh's default list equals the list under CLAUDE.md "### The gate" — no silent drift.
# Parsed structurally, from the section's BULLETS only. The old parse read every backticked
# `*.sh` between "### The gate" and a "Merge only" line that is mid-paragraph, so it never
# terminated (correct only while The gate is the last section) and it counted prose mentions —
# rewording `bash scripts/verify.sh` to a bare path would have false-reddened the gate (cch-x1q
# items G and H).
gate_list() {  # gate_list <claude-md> -> one selftest path per line, from the section's bullets
  awk '
    /^### The gate/ { inside = 1; next }
    inside && /^#/  { exit }
    inside && /^- `[^`]+\.sh`/ {
      line = $0
      sub(/^- `/, "", line)
      sub(/`.*$/, "", line)
      print line
    }
  ' "$1"
}

listed=$(gate_list "$root/CLAUDE.md" | sort)
defaults=$(bash "$verify" --list | sort)
if [ -n "$listed" ] && [ "$listed" = "$defaults" ]; then
  pass 'default list matches CLAUDE.md gate list'
else
  fail 'default list matches CLAUDE.md gate list' "CLAUDE.md: $(printf '%s' "$listed" | tr '\n' ' ') | verify.sh: $(printf '%s' "$defaults" | tr '\n' ' ')"
fi

# 6. The parse reads bullets, not prose: a section that mentions a bare selftest path in a sentence,
# and a later section that lists one, must both be invisible to it.
cat > "$tmp/claude-fixture.md" <<'FIXTURE'
### The gate

Prose that names scripts/prose-only-selftest.sh and `scripts/also-prose-selftest.sh` inline.

- `hooks/selftest.sh`
- `scripts/verify-selftest.sh`

Merge only when every listed selftest reports PASS at the PR's HEAD.

### A later section

- `scripts/not-the-gate-selftest.sh`
FIXTURE
parsed=$(gate_list "$tmp/claude-fixture.md")
if [ "$parsed" = "$(printf '%s\n' 'hooks/selftest.sh' 'scripts/verify-selftest.sh')" ]; then
  pass 'gate-list parse reads bullets only, and stops at the next section'
else
  fail 'gate-list parse reads bullets only, and stops at the next section' "parsed=$(printf '%s' "$parsed" | tr '\n' ' ')"
fi

# 7. The gate's length is pinned to a literal, so a selftest dropped from the default list fails the
# gate instead of shrinking a green. Negative control: a copy with one entry removed must FAIL
# before it runs anything.
mutant=$tmp/verify-mutant.sh
sed 's| scripts/verify-selftest.sh"| "|' "$verify" > "$mutant"
if cmp -s "$mutant" "$verify"; then
  fail 'dropping a selftest from the default list fails the gate' 'the mutation did not apply'
else
  out=$(CC_HARNESS_VERIFY_LOG_DIR="$tmp/l7" bash "$mutant" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -Fq 'the default gate list holds 16 selftests, expected 17'; then
    pass 'dropping a selftest from the default list fails the gate'
  else
    fail 'dropping a selftest from the default list fails the gate' "rc=$rc out=$out"
  fi
fi

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'VERIFY SELFTEST RESULT: PASS'
  exit 0
fi
printf '%s\n' 'VERIFY SELFTEST RESULT: FAIL'
exit 1
