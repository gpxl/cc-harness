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
listed=$(sed -n '/^### The gate/,/^Merge only/p' "$root/CLAUDE.md" | grep -oE '`[A-Za-z0-9_./-]+\.sh`' | tr -d '`' | sort)
defaults=$(bash "$verify" --list | sort)
if [ -n "$listed" ] && [ "$listed" = "$defaults" ]; then
  pass 'default list matches CLAUDE.md gate list'
else
  fail 'default list matches CLAUDE.md gate list' "CLAUDE.md: $(printf '%s' "$listed" | tr '\n' ' ') | verify.sh: $(printf '%s' "$defaults" | tr '\n' ' ')"
fi

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'VERIFY SELFTEST RESULT: PASS'
  exit 0
fi
printf '%s\n' 'VERIFY SELFTEST RESULT: FAIL'
exit 1
