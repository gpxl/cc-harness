#!/usr/bin/env bash
# Hermetic behavioral checks for codex-wait.sh.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
waiter="$script_dir/codex-wait.sh"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-wait-selftest.XXXXXX") || exit 1
live_pid=''
failures=0
last_status=0

cleanup() {
  if [ -n "$live_pid" ] && kill -0 "$live_pid" 2>/dev/null; then
    kill -TERM "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp_root"
}
trap cleanup EXIT HUP INT TERM

record_failure() {
  failures=$((failures + 1))
}

write_job() {
  local file="$1"
  local id="$2"
  local status="$3"
  local phase="$4"
  local pid="$5"
  local created_at="$6"

  node -e '
const fs = require("fs");
const [file, id, status, phase, pid, createdAt] = process.argv.slice(1);
const record = {
  id,
  status,
  phase,
  pid: pid === "null" ? null : Number(pid),
  logFile: `${file}.log`,
  createdAt,
  updatedAt: createdAt
};
fs.writeFileSync(file, `${JSON.stringify(record)}\n`, "utf8");
' "$file" "$id" "$status" "$phase" "$pid" "$created_at"
}

run_wait() {
  local file="$1"
  local id="$2"
  shift 2

  if CODEX_WAIT_JOB_FILE="$file" bash "$waiter" "$id" "$@" > "$tmp_root/wait.out" 2>&1; then
    last_status=0
  else
    last_status=$?
  fi
}

assert_status() {
  local expected="$1"
  if [ "$last_status" -ne "$expected" ]; then
    record_failure
  fi
}

if [ ! -x "$waiter" ]; then
  printf '%s\n' 'CODEX WAIT SELFTEST: FAIL'
  exit 1
fi

completed_file="$tmp_root/completed.json"
write_job "$completed_file" 'completed-job' 'completed' 'done' 'null' '2000-01-01T00:00:00.000Z'
run_wait "$completed_file" 'completed-job' --interval 1 --max-minutes 0
assert_status 0

run_wait "$completed_file" 'completed-job' --interval 1 --max-minutes 0
if [ "$last_status" -eq 1 ]; then
  record_failure
fi

failed_file="$tmp_root/failed.json"
write_job "$failed_file" 'failed-job' 'failed' 'done' 'null' '2000-01-01T00:00:00.000Z'
run_wait "$failed_file" 'failed-job' --interval 1 --max-minutes 0
assert_status 1

cancelled_file="$tmp_root/cancelled.json"
write_job "$cancelled_file" 'cancelled-job' 'cancelled' 'cancelled' 'null' '2000-01-01T00:00:00.000Z'
run_wait "$cancelled_file" 'cancelled-job' --interval 1 --max-minutes 0
assert_status 1

sleep 0.1 &
dead_pid=$!
wait "$dead_pid" || true

unknown_file="$tmp_root/unknown.json"
write_job "$unknown_file" 'unknown-job' 'unknown' 'orphaned' 'null' '2000-01-01T00:00:00.000Z'
run_wait "$unknown_file" 'unknown-job' --interval 1 --max-minutes 0
assert_status 2

dead_running_file="$tmp_root/dead-running.json"
write_job "$dead_running_file" 'dead-running-job' 'running' 'working' "$dead_pid" '2000-01-01T00:00:00.000Z'
run_wait "$dead_running_file" 'dead-running-job' --interval 1 --max-minutes 1
assert_status 2

dead_queued_file="$tmp_root/dead-queued.json"
write_job "$dead_queued_file" 'dead-queued-job' 'queued' 'queued' "$dead_pid" '2000-01-01T00:00:00.000Z'
run_wait "$dead_queued_file" 'dead-queued-job' --interval 1 --max-minutes 1
assert_status 2

sleep 30 &
live_pid=$!
live_running_file="$tmp_root/live-running.json"
write_job "$live_running_file" 'live-running-job' 'running' 'working' "$live_pid" '2000-01-01T00:00:00.000Z'
run_wait "$live_running_file" 'live-running-job' --interval 1 --max-minutes 0
assert_status 3

run_wait "$tmp_root/missing.json" 'missing-job' --interval 1 --max-minutes 0
assert_status 4

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'CODEX WAIT SELFTEST: PASS'
  exit 0
fi

printf '%s\n' 'CODEX WAIT SELFTEST: FAIL'
exit 1
