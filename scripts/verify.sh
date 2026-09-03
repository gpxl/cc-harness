#!/usr/bin/env bash
# cc-harness verify_cmd: run every merge-gate selftest listed in CLAUDE.md "The gate".
# One log per selftest; each exit code is read directly, never through a pipe
# (rules/verification-integrity.md). Override the list with CC_HARNESS_SELFTESTS
# (space-separated, repo-relative) — used by the negative control.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
log_dir=${CC_HARNESS_VERIFY_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/cc-harness-verify.XXXXXX")}
default_tests="hooks/selftest.sh scripts/codex-path-selftest.sh scripts/routing-report-selftest.sh scripts/install-symmetry-selftest.sh scripts/codex-wait-selftest.sh scripts/codex-brokers-selftest.sh scripts/codex-jobs-selftest.sh scripts/codex-dispatch-selftest.sh scripts/trusted-pr-merge-selftest.sh"
tests=${CC_HARNESS_SELFTESTS:-$default_tests}
failures=0
count=0

for t in $tests; do
  count=$((count + 1))
  name=$(basename "$t" .sh)
  if bash "$root/$t" > "$log_dir/$name.log" 2>&1; then
    printf '%s: PASS\n' "$name"
    continue
  fi
  rc=$?
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
