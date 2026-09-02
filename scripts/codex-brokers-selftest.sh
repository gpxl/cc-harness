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
sleep 30 & alias_pid=$!;  pids+=("$alias_pid")

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
mkdir -p "$data/state/alias-ws-5555" "$fake_tmp/alias-ws"
write_state "$data/state/alias-ws-5555" "$alias_pid" completed
rmdir "$fake_tmp/dead-ws"

# A pre-captured `ps -axww -o pid=,ppid=,etime=,command=` listing (see CODEX_BROKERS_PS_SNAPSHOT).
snapshot="$tmp_root/ps.txt"
broker_line() { printf '%s 1 01:00 node /x/scripts/app-server-broker.mjs serve --endpoint unix:/s --cwd %s --pid-file /s/p\n' "$1" "$2"; }
{
  broker_line "$active_pid" "$fake_tmp/active-ws"
  broker_line "$idle_pid" "$tmp_root/idle-ws"
  broker_line "$stale_pid" "$fake_tmp/dead-ws"
  broker_line "$spaced_pid" "$tmp_root/Local Sites/ws"
  broker_line "$alias_pid" "$fake_tmp/alias-ws"
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
expect "$alias_pid" STALE     # under $TMPDIR with no active job

# macOS: TMPDIR is /var/... while ps reports /private/var/...; a symlinked TMPDIR must still classify
# a broker whose cwd is the real path as under tmp.
ln -s "$fake_tmp" "$tmp_root/tmplink"
out2="$tmp_root/out2.txt"
CODEX_BROKERS_PS_SNAPSHOT="$snapshot" CLAUDE_PLUGIN_DATA="$data" TMPDIR="$tmp_root/tmplink" bash "$tool" > "$out2" 2>&1 || {
  printf '%s\n' 'CODEX BROKERS SELFTEST: FAIL (tool exited non-zero under symlinked TMPDIR)'; exit 1; }
if ! grep -q "^CODEX BROKER $alias_pid .* verdict=STALE " "$out2"; then
  printf 'symlinked TMPDIR: expected broker %s STALE; got: %s\n' "$alias_pid" "$(grep "^CODEX BROKER $alias_pid " "$out2" || echo '<missing>')" >&2
  failures=$((failures + 1))
fi
if grep -q '^CODEX BROKER 4242 ' "$out"; then
  printf '%s\n' 'non-broker process listed as a broker' >&2; failures=$((failures + 1))
fi
if grep -q 'action=reaped' "$out"; then
  printf '%s\n' 'listing mode must never reap' >&2; failures=$((failures + 1))
fi

# An unregistered broker whose cwd exists is UNKNOWN, never STALE: with no discoverable state store
# (CLAUDE_PLUGIN_DATA unset) every broker would otherwise be a reap candidate, live ones included.
mkdir -p "$tmp_root/isolated"   # parent exists but holds no */state/*/broker.json
out3="$tmp_root/out3.txt"
CODEX_BROKERS_PS_SNAPSHOT="$snapshot" CLAUDE_PLUGIN_DATA="$tmp_root/isolated/no-such-data" TMPDIR="$fake_tmp" bash "$tool" > "$out3" 2>&1 || {
  printf '%s\n' 'CODEX BROKERS SELFTEST: FAIL (tool exited non-zero with no state store)'; exit 1; }
for pid in "$active_pid" "$idle_pid" "$spaced_pid"; do
  if ! grep -q "^CODEX BROKER $pid .* verdict=UNKNOWN " "$out3"; then
    printf 'no state store: expected broker %s UNKNOWN; got: %s\n' "$pid" "$(grep "^CODEX BROKER $pid " "$out3" || echo '<missing>')" >&2
    failures=$((failures + 1))
  fi
done
# ...except one whose cwd is genuinely gone: that verdict stands on its own evidence.
grep -q "^CODEX BROKER $stale_pid .* verdict=STALE " "$out3" || {
  printf 'no state store: a broker with a missing cwd must still be STALE\n' >&2; failures=$((failures + 1)); }

# And with no store discovered at all, reaping is disarmed rather than performed.
out4="$tmp_root/out4.txt"; err4="$tmp_root/err4.txt"
CODEX_BROKERS_PS_SNAPSHOT="$snapshot" CLAUDE_PLUGIN_DATA="$tmp_root/isolated/no-such-data" TMPDIR="$fake_tmp" bash "$tool" --reap-stale > "$out4" 2> "$err4" || true
grep -q 'reaping disarmed' "$err4" || { printf 'expected a disarm notice on stderr\n' >&2; failures=$((failures + 1)); }
grep -q 'action=reaped' "$out4" && { printf 'reaped with no state store discovered\n' >&2; failures=$((failures + 1)); }
for pid in "$active_pid" "$idle_pid" "$stale_pid" "$spaced_pid"; do
  kill -0 "$pid" 2>/dev/null || { printf 'disarmed run killed pid %s\n' "$pid" >&2; failures=$((failures + 1)); }
done

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'CODEX BROKERS SELFTEST: PASS'; exit 0
fi
printf '%s\n' 'CODEX BROKERS SELFTEST: FAIL'; exit 1
