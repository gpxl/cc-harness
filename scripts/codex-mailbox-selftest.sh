#!/usr/bin/env bash
# Hermetic protocol checks for codex-mailbox.sh. Drives `once`; never starts a detached runner.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tool="$script_dir/codex-mailbox.sh"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-mailbox-selftest.XXXXXX") || exit 1
TMPDIR="$tmp_root/host-tmp"
export TMPDIR
mkdir -p "$TMPDIR"
workspace="$tmp_root/workspace"
tasks="$tmp_root/tasks.tsv"
count_file="$tmp_root/run-count.txt"
failures=0
assertions=0
sacrificial_pid=''

cleanup() {
  local status=$?
  if [ -n "${sacrificial_pid:-}" ]; then
    kill -TERM "$sacrificial_pid" 2>/dev/null || true
    wait "$sacrificial_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp_root"
  [ "$completed" = 1 ] || status=1
  exit "$status"
}
# A completion sentinel, not `$?`: on bash 3.2 (the system shell here) a script killed by
# set -e/set -u runs its EXIT trap with $? ALREADY RESET TO 0, so capturing the status in the
# trap is inert — measured. Only positive evidence that the suite reached its own verdict can
# distinguish a real pass from an abort. cch-85b; rules/verification-integrity.md.
completed=0
trap cleanup EXIT HUP INT TERM

mkdir -p "$workspace/bin"

cat > "$workspace/bin/ok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'ok-output'
exit 0
EOF
cat > "$workspace/bin/fail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'fail-output'
exit 23
EOF
cat > "$workspace/bin/count" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'count-output'
printf '%s\n' 'ran' >> "$CODEX_MAILBOX_COUNT_FILE"
exit 0
EOF
chmod +x "$workspace/bin/ok" "$workspace/bin/fail" "$workspace/bin/count"

printf 'ok\t%s\nfail\t%s\ncount\t%s\n' \
  "$workspace/bin/ok" "$workspace/bin/fail" "$workspace/bin/count" > "$tasks"

assert_true() {
  local description="$1"
  shift
  assertions=$((assertions + 1))
  if ! "$@"; then
    printf 'assertion failed: %s\n' "$description" >&2
    failures=$((failures + 1))
  fi
}

assert_equal() {
  local description="$1" expected="$2" actual="$3"
  assertions=$((assertions + 1))
  if [ "$expected" != "$actual" ]; then
    printf 'assertion failed: %s (expected %s, got %s)\n' "$description" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

write_request() {
  local id="$1" task="$2"
  node -e 'process.stdout.write(JSON.stringify({ task: process.argv[2] }) + "\n");' \
    -- "$id" "$task" > "$workspace/.codex-mailbox/req-$id.json"
}

json_value() {
  node -e '
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[process.argv[2]];
process.stdout.write(String(value));
' -- "$1" "$2"
}

json_parses() {
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));' -- "$1" >/dev/null
}

run_once() {
  local output="$tmp_root/once.out" result
  set +e
  CODEX_MAILBOX_TASKS="$tasks" CODEX_MAILBOX_COUNT_FILE="$count_file" \
    bash "$tool" once --workspace "$workspace" > "$output" 2>&1
  result=$?
  set -e
  assert_equal 'once exits successfully' 0 "$result"
}

symlink_request_is_refused() {
  test "$symlink_request_result" -ne 0 &&
    test ! -e "$workspace/.codex-mailbox/resp-symlink-request.json"
}

log_symlink_delivery_is_safe() {
  test "$(cat "$symlink_sentinel")" = 'sentinel remains intact' &&
    test "$(json_value "$log_symlink_response" exit)" = 0 &&
    grep -q 'ok-output' "$workspace/.codex-mailbox/log-log-symlink.txt"
}

response_temp_symlink_delivery_is_safe() {
  test "$(cat "$symlink_sentinel")" = 'sentinel remains intact' &&
    test "$(json_value "$response_temp_symlink_response" exit)" = 0 &&
    json_parses "$response_temp_symlink_response"
}

forged_pid_is_refused() {
  test "$forged_pid_result" -ne 0 && kill -0 "$sacrificial_pid"
}

empty_name_is_refused() {
  test "$empty_name_result" -ne 0 &&
    grep -q 'invalid task name in task table' "$tmp_root/empty-name.out"
}

mkdir -p "$workspace/.codex-mailbox"

# A symlinked request must not be accepted as a request payload.
printf '%s\n' '{"task":"ok"}' > "$tmp_root/symlink-request.json"
ln -s "$tmp_root/symlink-request.json" "$workspace/.codex-mailbox/req-symlink-request.json"
set +e
CODEX_MAILBOX_TASKS="$tasks" CODEX_MAILBOX_COUNT_FILE="$count_file" \
  bash "$tool" once --workspace "$workspace" > "$tmp_root/symlink-request.out" 2>&1
symlink_request_result=$?
set -e
assert_true 'a symlinked request is refused without a response' symlink_request_is_refused
rm -f "$workspace/.codex-mailbox/req-symlink-request.json"

# These planted destinations must be atomically replaced, never opened for writing.
symlink_sentinel="$tmp_root/mailbox-symlink-sentinel.txt"
printf '%s\n' 'sentinel remains intact' > "$symlink_sentinel"
ln -s "$symlink_sentinel" "$workspace/.codex-mailbox/log-log-symlink.txt"
write_request log-symlink ok
run_once
log_symlink_response="$workspace/.codex-mailbox/resp-log-symlink.json"
assert_true 'log-destination symlink preserves its sentinel and still delivers output' log_symlink_delivery_is_safe

ln -s "$symlink_sentinel" "$workspace/.codex-mailbox/resp-response-temp-symlink.json.tmp"
write_request response-temp-symlink ok
run_once
response_temp_symlink_response="$workspace/.codex-mailbox/resp-response-temp-symlink.json"
assert_true 'response-temp symlink preserves its sentinel and still delivers JSON' response_temp_symlink_delivery_is_safe
rm -f "$workspace/.codex-mailbox/resp-response-temp-symlink.json.tmp"

# Mailbox state is attacker-controlled and must never select a process to signal.
sleep 600 &
sacrificial_pid=$!
printf '%s\t0\t9999999999\n' "$sacrificial_pid" > "$workspace/.codex-mailbox/runner.pid"
set +e
CODEX_MAILBOX_TASKS="$tasks" bash "$tool" stop --workspace "$workspace" > "$tmp_root/forged-pid.out" 2>&1
forged_pid_result=$?
set -e
assert_true 'forged mailbox pid is refused and leaves the test-owned process alive' forged_pid_is_refused

# An empty task-table row/name fails closed instead of being skipped.
empty_name_tasks="$tmp_root/empty-name-tasks.tsv"
printf 'ok\t%s\n\n' "$workspace/bin/ok" > "$empty_name_tasks"
set +e
CODEX_MAILBOX_TASKS="$empty_name_tasks" bash "$tool" once --workspace "$workspace" > "$tmp_root/empty-name.out" 2>&1
empty_name_result=$?
set -e
assert_true 'an empty task-table name fails closed as invalid' empty_name_is_refused

# Allowlisted work must preserve its actual command exit status and complete log.
write_request ok1 ok
run_once
ok_response="$workspace/.codex-mailbox/resp-ok1.json"
assert_equal 'zero-exit task response' 0 "$(json_value "$ok_response" exit)"
assert_true 'zero-exit log contains command output' grep -q 'ok-output' "$workspace/.codex-mailbox/log-ok1.txt"

write_request fail1 fail
run_once
fail_response="$workspace/.codex-mailbox/resp-fail1.json"
assert_equal 'non-zero task response preserves real exit' 23 "$(json_value "$fail_response" exit)"
assert_true 'non-zero log contains command output' grep -q 'fail-output' "$workspace/.codex-mailbox/log-fail1.txt"

# An unallowlisted task must not execute as a command; if it did, this would create the sentinel.
write_request blocked 'touch sentinel'
run_once
blocked_response="$workspace/.codex-mailbox/resp-blocked.json"
assert_equal 'unallowlisted task gets exit -1' -1 "$(json_value "$blocked_response" exit)"
assert_true 'unallowlisted task reports an error' grep -q 'task not allowlisted' "$blocked_response"
assert_true 'unallowlisted task did not create its sentinel' test ! -e "$workspace/sentinel"

# Task text is never evaluated. These are the critical negative controls.
write_request inject1 'build; touch pwned'
write_request inject2 '$(touch pwned2)'
run_once
assert_equal 'semicolon injection gets exit -1' -1 "$(json_value "$workspace/.codex-mailbox/resp-inject1.json" exit)"
assert_equal 'command-substitution injection gets exit -1' -1 "$(json_value "$workspace/.codex-mailbox/resp-inject2.json" exit)"
assert_true 'semicolon injection did not run touch' test ! -e "$workspace/pwned"
assert_true 'command substitution did not run touch' test ! -e "$workspace/pwned2"

# NEGATIVE CONTROL FOR is_task_name ITSELF. Every injection case above is ALSO refused by the
# exact-match table lookup, so all of them stay green when the name regex is deleted — measured, by
# stubbing the regex to `true` and watching this suite still pass. The regex's real job is guarding
# the TABLE: add_task refuses a malformed entry so it can never become reachable, and the runner
# fails closed. Delete the regex and the entry below loads, the request matches it, and the sentinel
# appears. Without this case the suite cannot tell a working guard from a missing one
# (rules/verification-integrity.md).
bad_tasks="$tmp_root/bad-tasks.tsv"
bad_output="$tmp_root/bad-output.txt"
printf 'BADNAME\t%s\n' "touch '$workspace/regex-bypassed'" > "$bad_tasks"
write_request badname 'BADNAME'
set +e
CODEX_MAILBOX_TASKS="$bad_tasks" bash "$tool" once --workspace "$workspace" > "$bad_output" 2>&1
bad_result=$?
set -e
assert_true 'a task table holding a malformed name is refused' test "$bad_result" -ne 0
assert_true 'the runner says which name it rejected' grep -q 'invalid task name in task table' "$bad_output"
assert_true 'no command from a rejected table ever ran' test ! -e "$workspace/regex-bypassed"


# A claimed request becomes .done and a later pass cannot run it again.
write_request once1 count
run_once
assert_true 'consumed request is moved aside' test -f "$workspace/.codex-mailbox/req-once1.json.done"
run_once
count_lines=$(wc -l < "$count_file")
count_lines=${count_lines//[[:space:]]/}
assert_equal 'consumed request is not run twice' 1 "$count_lines"

# Consumers only see the renamed response; the final document is complete JSON.
assert_true 'no response temp file remains' test -z "$(find "$workspace/.codex-mailbox" -name 'resp-*.json.tmp' -print -quit)"
assert_true 'final response parses as JSON' json_parses "$ok_response"

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'CODEX MAILBOX SELFTEST: PASS'
  completed=1; exit 0
fi
printf '%s\n' 'CODEX MAILBOX SELFTEST: FAIL'
completed=1; exit 1
