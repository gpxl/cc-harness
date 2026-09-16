#!/usr/bin/env bash
# cc-harness verify_cmd: run every merge-gate selftest listed in CLAUDE.md "The gate".
# One log per selftest; each exit code is read directly, never through a pipe
# (rules/verification-integrity.md). A run that resolves zero selftests FAILs — a green
# must have run something. `--list` prints the default list (verify-selftest.sh checks it
# against CLAUDE.md). CC_HARNESS_SELFTESTS overrides the list (space-separated; repo-relative
# or absolute) — used by the negative controls.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
default_tests="hooks/selftest.sh scripts/codex-path-selftest.sh scripts/routing-report-selftest.sh scripts/loop-report-selftest.sh scripts/retro-evidence-selftest.sh scripts/review-round-selftest.sh scripts/review-ack-check-selftest.sh scripts/rules-index-selftest.sh scripts/install-symmetry-selftest.sh scripts/codex-routing-selftest.sh scripts/codex-wait-selftest.sh scripts/codex-brokers-selftest.sh scripts/codex-jobs-selftest.sh scripts/codex-dispatch-selftest.sh scripts/trusted-pr-merge-selftest.sh scripts/name-hygiene-selftest.sh scripts/verify-selftest.sh"

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' $default_tests
  exit 0
fi

log_dir=${CC_HARNESS_VERIFY_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/cc-harness-verify.XXXXXX")}
mkdir -p "$log_dir" || exit 1

# shellcheck disable=SC2086 — word-splitting the list is the point
set -- ${CC_HARNESS_SELFTESTS:-$default_tests}
expected=$#
# The gate's own length, written as a literal. `expected=$#` can only ever agree with the list it
# was counted from, so it cannot notice a selftest dropped from that list. verify-selftest.sh's
# CLAUDE.md comparison catches a drop from ONE of the two places; this literal is what catches a
# drop from both in the same commit, where the two agree with each other and the gate silently runs
# fewer tests. A deliberate add or removal updates this number in the same edit (cch-x1q item I).
default_test_count=17
if [ "$expected" -eq 0 ]; then
  printf 'CC-HARNESS VERIFY: FAIL (no selftests resolved — CC_HARNESS_SELFTESTS is set but empty)\n'
  exit 1
fi
if [ -z "${CC_HARNESS_SELFTESTS:-}" ] && [ "$expected" -ne "$default_test_count" ]; then
  printf 'CC-HARNESS VERIFY: FAIL (the default gate list holds %s selftests, expected %s — change default_test_count in the same edit that changes the list)\n' \
    "$expected" "$default_test_count"
  exit 1
fi

failures=0
count=0
for t in "$@"; do
  count=$((count + 1))
  name=$(basename "$t" .sh)
  case $t in
    /*) path=$t ;;
    *) path=$root/$t ;;
  esac
  bash "$path" > "$log_dir/$name.log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s: PASS\n' "$name"
    continue
  fi
  failures=$((failures + 1))
  printf '%s: FAIL (exit %s) — %s\n' "$name" "$rc" "$log_dir/$name.log"
  tail -5 "$log_dir/$name.log" | sed 's/^/    /'
done

if [ "$failures" -eq 0 ]; then
  printf 'CC-HARNESS VERIFY: PASS (%s selftests)\n' "$count"
  exit 0
fi
printf 'CC-HARNESS VERIFY: FAIL (%s of %s selftests)\n' "$failures" "$count"
exit 1
