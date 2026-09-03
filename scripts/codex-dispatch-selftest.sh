#!/usr/bin/env bash
# Hermetic selftest for codex-dispatch.sh; it never invokes the installed Codex runtime.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/codex-dispatch-selftest.XXXXXX") || exit 1

cleanup() {
  local status=$?
    rm -rf -- "$tmpdir"
  [ "$completed" = 1 ] || status=1
  exit "$status"
}
# A completion sentinel, not `$?`: on bash 3.2 (the system shell here) a script killed by
# set -e/set -u runs its EXIT trap with $? ALREADY RESET TO 0, so capturing the status in the
# trap is inert — measured. Only positive evidence that the suite reached its own verdict can
# distinguish a real pass from an abort. cch-85b; rules/verification-integrity.md.
completed=0
trap cleanup EXIT HUP INT TERM

failures=0
fail() {
  printf 'CODEX DISPATCH SELFTEST: FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_eq() {
  [ "$1" = "$2" ] || { fail "expected [$1], got [$2]"; return 1; }
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "missing [$2]"; return 1 ;;
  esac
}

# grep, not rg: `rg` is a shell function in this machine's zsh profile, so it does not exist for a
# bash script. That made assert_file_omits pass VACUOUSLY — a missing binary means the `if` is
# false, which reads as "the unwanted argv is absent". A gate whose green survives its own tooling
# going missing is not a gate (rules/verification-integrity.md).
assert_file_contains() {
  grep -Fqx -- "$2" "$1" || { fail "missing argv [$2]"; return 1; }
}

assert_file_omits() {
  if grep -Fqx -- "$2" "$1"; then
    fail "unexpected argv [$2]"
    return 1
  fi
}

workspace="$tmpdir/workspace"
other_workspace="$tmpdir/other-workspace"
mkdir -p "$workspace" "$other_workspace"
real_workspace=$(node -e 'process.stdout.write(require("fs").realpathSync.native(process.argv[1]));' "$workspace")
prompt_file="$tmpdir/prompt.txt"
printf '%s\n' 'selftest prompt' > "$prompt_file"

cat > "$tmpdir/codex.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$TEST_TMP/codex-argv"
case "$1" in
  task)
    printf '%s\n' "$@" > "$TEST_TMP/task-argv"
    : > "$TEST_TMP/launch-called"
    if [ "$TEST_MODE" = nojob ]; then
      printf '%s\n' '{"status":"queued"}'
    else
      printf '%s\n' '{"jobId":"job-123","status":"queued","logFile":"/tmp/codex-selftest.log"}'
    fi
    ;;
  status)
    printf '%s\n' "$@" > "$TEST_TMP/status-argv"
    if [ "$TEST_MODE" = mismatch ]; then
      status_workspace="$TEST_OTHER_WORKSPACE"
    else
      status_workspace="$TEST_WORKSPACE"
    fi
    printf '{"workspaceRoot":"%s","running":[{"id":"job-123","status":"queued","pid":%s,"workspaceRoot":"%s"}]}\n' "$status_workspace" "$PPID" "$status_workspace"
    ;;
  cancel)
    printf '%s\n' "$@" > "$TEST_TMP/cancel-argv"
    : > "$TEST_TMP/cancel-called"
    ;;
  *)
    exit 91
    ;;
esac
EOF

cat > "$tmpdir/codex-jobs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$TEST_TMP/jobs-argv"
if [ "$TEST_MODE" = duplicate ]; then
  printf '%s\n' '[{"id":"job-duplicate","status":"running","jobClass":"task"}]'
else
  printf '%s\n' '[]'
fi
EOF
chmod +x "$tmpdir/codex.sh" "$tmpdir/codex-jobs.sh"

run_dispatch() {
  local output_file="$tmpdir/stdout"
  local error_file="$tmpdir/stderr"
  set +e
  TEST_TMP="$tmpdir" TEST_MODE="$1" TEST_WORKSPACE="$workspace" TEST_OTHER_WORKSPACE="$other_workspace" \
    CODEX_DISPATCH_CODEX_SH="$tmpdir/codex.sh" CODEX_DISPATCH_JOBS_SH="$tmpdir/codex-jobs.sh" \
    bash "$script_dir/codex-dispatch.sh" "${@:2}" > "$output_file" 2> "$error_file"
  run_status=$?
  set -e
  run_stdout=$(<"$output_file")
  run_stderr=$(<"$error_file")
}

rm -f "$tmpdir/launch-called" "$tmpdir/cancel-called"
run_dispatch happy --cwd "$workspace" --prompt-file "$prompt_file"
assert_eq 0 "$run_status" || true
assert_contains "$run_stdout" "CODEX DISPATCH: job-123 queued in $real_workspace" || true
assert_contains "$run_stdout" "CODEX DISPATCH: wait with scripts/codex-wait.sh job-123 --cwd $real_workspace" || true
assert_file_contains "$tmpdir/task-argv" --write || true
assert_file_contains "$tmpdir/jobs-argv" --active || true
assert_file_contains "$tmpdir/jobs-argv" --json || true

rm -f "$tmpdir/launch-called" "$tmpdir/cancel-called"
run_dispatch duplicate --cwd "$workspace" --prompt-file "$prompt_file"
assert_eq 3 "$run_status" || true
[ ! -e "$tmpdir/launch-called" ] || fail 'duplicate job launched a task'

set +e
TEST_TMP="$tmpdir" TEST_MODE=happy TEST_WORKSPACE="$workspace" TEST_OTHER_WORKSPACE="$other_workspace" \
  CODEX_DISPATCH_CODEX_SH="$tmpdir/codex.sh" CODEX_DISPATCH_JOBS_SH="$tmpdir/codex-jobs.sh" \
  bash "$script_dir/codex-dispatch.sh" --cwd "$workspace" < /dev/null > "$tmpdir/stdout" 2> "$tmpdir/stderr"
run_status=$?
set -e
assert_eq 2 "$run_status" || true
[ ! -e "$tmpdir/launch-called" ] || fail 'no-prompt invocation launched a task'

rm -f "$tmpdir/launch-called" "$tmpdir/cancel-called"
run_dispatch nojob --cwd "$workspace" --prompt-file "$prompt_file"
assert_eq 4 "$run_status" || true
[ -e "$tmpdir/launch-called" ] || fail 'no-jobId case did not invoke the launch stub'

rm -f "$tmpdir/launch-called" "$tmpdir/cancel-called"
run_dispatch mismatch --cwd "$workspace" --prompt-file "$prompt_file"
assert_eq 5 "$run_status" || true
[ -e "$tmpdir/launch-called" ] || fail 'placement mismatch did not invoke the launch stub'
[ -e "$tmpdir/cancel-called" ] || fail 'placement mismatch did not cancel the job'

rm -f "$tmpdir/launch-called" "$tmpdir/cancel-called"
run_dispatch happy --cwd "$workspace" --prompt-file "$prompt_file"
assert_eq 0 "$run_status" || true
assert_file_contains "$tmpdir/task-argv" --write || true
run_dispatch happy --read-only --cwd "$workspace" --prompt-file "$prompt_file"
assert_eq 0 "$run_status" || true
assert_file_omits "$tmpdir/task-argv" --write || true

run_dispatch happy --json --cwd "$workspace" --prompt-file "$prompt_file"
assert_eq 0 "$run_status" || true
if ! node -e '
const value = JSON.parse(process.argv[1]);
if (value.jobId !== "job-123" || value.status !== "queued" || !value.waitCommand) process.exit(1);
' "$run_stdout"; then
  fail 'JSON output was not the expected object'
fi

# Negative control: a bad expected line must fail, proving assertions are not vacuous.
case "$run_stdout" in
  *'CODEX DISPATCH: wrong-job queued'*) fail 'negative control unexpectedly passed' ;;
esac

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'CODEX DISPATCH SELFTEST: PASS'
  completed=1; completed=1; exit 0
fi
printf '%s\n' 'CODEX DISPATCH SELFTEST: FAIL' >&2
completed=1; completed=1; exit 1
