#!/usr/bin/env bash
# cc-harness verify_cmd: run every merge-gate selftest listed in CLAUDE.md "The gate".
# One log per selftest; each exit code is read directly, never through a pipe
# (rules/verification-integrity.md). A run that resolves zero selftests FAILs — a green
# must have run something. `--list` prints the default list (verify-selftest.sh checks it
# against CLAUDE.md). CC_HARNESS_SELFTESTS overrides the list (space-separated; repo-relative
# or absolute) — used by the negative controls.
set -uo pipefail
# Monitor mode puts every backgrounded selftest in its OWN process group even though this script
# is never interactive. That is the only reason `kill -TERM -- "-$pid"` below can reach a
# selftest's own children, not just the selftest's direct bash process — negated-PID kill targets
# a process GROUP, and a group only exists here because monitor mode created one per job.
set -m

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
default_tests="hooks/selftest.sh scripts/codex-path-selftest.sh scripts/routing-report-selftest.sh scripts/loop-report-selftest.sh scripts/retro-evidence-selftest.sh scripts/review-round-selftest.sh scripts/review-ack-check-selftest.sh scripts/rules-index-selftest.sh scripts/install-symmetry-selftest.sh scripts/codex-routing-selftest.sh scripts/codex-wait-selftest.sh scripts/codex-brokers-selftest.sh scripts/codex-jobs-selftest.sh scripts/codex-dispatch-selftest.sh scripts/trusted-pr-merge-selftest.sh scripts/name-hygiene-selftest.sh scripts/fix-prompt-check-selftest.sh scripts/verify-selftest.sh"

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
default_test_count=18
if [ "$expected" -eq 0 ]; then
  printf 'CC-HARNESS VERIFY: FAIL (no selftests resolved — CC_HARNESS_SELFTESTS is set but empty)\n'
  exit 1
fi
if [ -z "${CC_HARNESS_SELFTESTS:-}" ] && [ "$expected" -ne "$default_test_count" ]; then
  printf 'CC-HARNESS VERIFY: FAIL (the default gate list holds %s selftests, expected %s — change default_test_count in the same edit that changes the list)\n' \
    "$expected" "$default_test_count"
  exit 1
fi

# Selftests are hermetic (each sandboxes its own tmp dir and CLAUDE_PLUGIN_DATA; the two that
# write a mutant beside the real script use script-specific filenames — verified before this
# changed from a sequential loop), so they run concurrently: wall time is the slowest selftest,
# not their sum. Each still gets its own log file and its exit code is read directly off its own
# PID via `wait`, never through a pipe (rules/verification-integrity.md).
pids=()
names=()
i=0
# A signal here must not leave selftests — or anything THEY spawned — running past the gate's own
# exit: two of them temporarily write a mutant beside the real script and rely on their own trap to
# clean it up before the NEXT run starts, not before some earlier run's orphaned descendant gets
# around to it. `kill -TERM -- "-$pid"` (note the negated pid) signals the whole process GROUP a
# selftest's `bash "$path"` leads, not just that one process, so a selftest that itself backgrounds
# something dies along with it; killing the bare PID does not (reproduced: a selftest backgrounding
# `sleep 30 &` outlived a TERM'd gate under plain `kill "$pid"`; the negated-group form kills both).
# `${pids[@]:-}` (not `${pids[@]}`) is deliberate: under `set -u` an empty array's `[@]`
# expansion is unbound on bash 3.2 (macOS's default /bin/bash), so this guards the case where a
# signal arrives before any selftest has launched.
cleanup_on_signal() {
  trap - INT TERM HUP
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] && kill -TERM -- "-$pid" 2>/dev/null
  done
  exit 130
}
trap cleanup_on_signal INT TERM HUP
for t in "$@"; do
  i=$((i + 1))
  name=$(basename "$t" .sh)
  case $t in
    /*) path=$t ;;
    *) path=$root/$t ;;
  esac
  bash "$path" > "$log_dir/$name.log" 2>&1 &
  pids[i]=$!
  names[i]=$name
done

failures=0
count=0
for idx in "${!pids[@]}"; do
  count=$((count + 1))
  name=${names[idx]}
  wait "${pids[idx]}"
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
