#!/usr/bin/env bash
# Hermetic verdict checks for codex-brokers.sh: an active job is never STALE, wherever its cwd is.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tool="$script_dir/codex-brokers.sh"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-brokers-selftest.XXXXXX") || exit 1
failures=0
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp_root"
}
trap cleanup EXIT HUP INT TERM

fake_tmp="$tmp_root/tmp"
data="$tmp_root/plugin-data"
mkdir -p "$fake_tmp/active-ws" "$fake_tmp/dead-ws" "$tmp_root/idle-ws" "$tmp_root/Local Sites/ws" \
  "$data/state/active-ws-1111" "$data/state/idle-ws-2222" "$data/state/dead-ws-3333" "$data/state/ws-4444"

# Real, living processes so the pid registration matches the way the tool sees a live broker.
sleep 30 & active_pid=$!; pids+=("$active_pid")
sleep 30 & idle_pid=$!;   pids+=("$idle_pid")
sleep 30 & stale_pid=$!;  pids+=("$stale_pid")
sleep 30 & spaced_pid=$!; pids+=("$spaced_pid")

write_state() {
  local dir="$1" pid="$2" status="$3"
  printf '{"endpoint":"unix:%s/b.sock","pidFile":"%s/b.pid","logFile":"%s/b.log","sessionDir":"%s","pid":%s}\n' \
    "$dir" "$dir" "$dir" "$dir" "$pid" > "$dir/broker.json"
  printf '{"version":1,"config":{},"jobs":[{"id":"j","status":"%s","pid":null}]}\n' "$status" > "$dir/state.json"
}
write_state "$data/state/active-ws-1111" "$active_pid" running
write_state "$data/state/idle-ws-2222" "$idle_pid" completed
write_state "$data/state/dead-ws-3333" "$stale_pid" completed
write_state "$data/state/ws-4444" "$spaced_pid" completed
rmdir "$fake_tmp/dead-ws"

# A pre-captured `ps -axww -o pid=,ppid=,etime=,command=` listing (see CODEX_BROKERS_PS_SNAPSHOT).
snapshot="$tmp_root/ps.txt"
broker_line() { printf '%s 1 01:00 node /x/scripts/app-server-broker.mjs serve --endpoint unix:/s --cwd %s --pid-file /s/p\n' "$1" "$2"; }
{
  broker_line "$active_pid" "$fake_tmp/active-ws"
  broker_line "$idle_pid" "$tmp_root/idle-ws"
  broker_line "$stale_pid" "$fake_tmp/dead-ws"
  broker_line "$spaced_pid" "$tmp_root/Local Sites/ws"
  printf '4242 1 01:00 node /x/scripts/codex-companion.mjs task-worker --cwd %s\n' "$tmp_root/idle-ws"
} > "$snapshot"

out="$tmp_root/out.txt"
CODEX_BROKERS_PS_SNAPSHOT="$snapshot" CLAUDE_PLUGIN_DATA="$data" TMPDIR="$fake_tmp" bash "$tool" > "$out" 2>&1 || {
  printf '%s\n' 'CODEX BROKERS SELFTEST: FAIL (tool exited non-zero)'; exit 1; }

expect() {
  local pid="$1" verdict="$2"
  if ! grep -q "^CODEX BROKER $pid .* verdict=$verdict " "$out"; then
    printf 'expected broker %s to be %s; got: %s\n' "$pid" "$verdict" "$(grep "^CODEX BROKER $pid " "$out" || echo '<missing>')" >&2
    failures=$((failures + 1))
  fi
}
expect "$active_pid" LIVE     # under $TMPDIR but serving a running job: never STALE
expect "$idle_pid" IDLE       # registered, cwd exists, no active job
expect "$stale_pid" STALE     # cwd gone
expect "$spaced_pid" IDLE     # a cwd containing a space must not be truncated into a missing path
if grep -q '^CODEX BROKER 4242 ' "$out"; then
  printf '%s\n' 'non-broker process listed as a broker' >&2; failures=$((failures + 1))
fi
if grep -q 'action=reaped' "$out"; then
  printf '%s\n' 'listing mode must never reap' >&2; failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'CODEX BROKERS SELFTEST: PASS'; exit 0
fi
printf '%s\n' 'CODEX BROKERS SELFTEST: FAIL'; exit 1
