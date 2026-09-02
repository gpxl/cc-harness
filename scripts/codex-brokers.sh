#!/usr/bin/env bash
# Inspect and selectively reap detached Codex app-server broker processes.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/codex-brokers.sh [--reap-stale] [--restart-idle]' >&2
}

reap_stale=false
restart_idle=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reap-stale)
      reap_stale=true
      shift
      ;;
    --restart-idle)
      restart_idle=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

snapshot=$(mktemp "${TMPDIR:-/tmp}/codex-brokers-ps.XXXXXX") || exit 0
cleanup() {
  rm -f "$snapshot"
}
trap cleanup EXIT HUP INT TERM

if [ -n "${CODEX_BROKERS_PS_SNAPSHOT:-}" ]; then
  # Selftest hook: a pre-captured `ps -axww -o pid=,ppid=,etime=,command=` listing.
  cp "$CODEX_BROKERS_PS_SNAPSHOT" "$snapshot"
elif ! ps -axww -o pid=,ppid=,etime=,command= > "$snapshot" 2>/dev/null; then
  printf '%s\n' 'CODEX BROKERS: unavailable (process listing denied)'
  exit 0
fi

broker_files=()
# Sibling data roots too: another plugin install's session may own a broker with an active job.
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  for broker_file in "$(dirname "$CLAUDE_PLUGIN_DATA")"/*/state/*/broker.json; do
    [ -f "$broker_file" ] && broker_files+=("$broker_file")
  done
fi
for broker_file in "${TMPDIR:-/tmp}"/codex-companion/*/broker.json; do
  [ -f "$broker_file" ] && broker_files+=("$broker_file")
done

records=$(node -e '
const fs = require("fs");
const path = require("path");
const [snapshot, tmpRoot, ...brokerFiles] = process.argv.slice(1);
const rows = fs.readFileSync(snapshot, "utf8").split("\n").flatMap((line) => {
  const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/);
  return match ? [{ pid: Number(match[1]), ppid: Number(match[2]), etime: match[3], command: match[4] }] : [];
});
const brokerStateByPid = new Map();
for (const brokerFile of brokerFiles) {
  try {
    const broker = JSON.parse(fs.readFileSync(brokerFile, "utf8"));
    if (!Number.isInteger(broker.pid) || broker.pid < 1) continue;
    let active = false;
    try {
      const state = JSON.parse(fs.readFileSync(path.join(path.dirname(brokerFile), "state.json"), "utf8"));
      active = Array.isArray(state.jobs) && state.jobs.some((job) => job && (job.status === "queued" || job.status === "running"));
    } catch {}
    const existing = brokerStateByPid.get(broker.pid);
    brokerStateByPid.set(broker.pid, { active: Boolean(existing?.active || active) });
  } catch {}
}
function readArgument(command, name) {
  const expression = new RegExp(`(?:^|\\s)${name.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&")}\\s+(\\S+)`);
  const match = command.match(expression);
  return match ? match[1] : "";
}
function realpathOr(value) {
  // macOS: TMPDIR is /var/... but ps reports /private/var/...; compare real paths.
  try { return fs.realpathSync.native(value); } catch { return path.resolve(value); }
}
function isUnderTmp(cwd) {
  const resolvedCwd = realpathOr(cwd);
  const resolvedTmp = realpathOr(tmpRoot);
  return resolvedCwd === resolvedTmp || resolvedCwd.startsWith(`${resolvedTmp}${path.sep}`);
}
for (const row of rows) {
  if (!/(?:^|\s)\S*app-server-broker\.mjs\s+serve(?:\s|$)/.test(row.command)) continue;
  // The cwd may contain spaces ("Local Sites"): take everything up to the next --flag.
  const cwdMatch = row.command.match(/(?:^|\s)--cwd\s+(.+?)(?=\s+--[a-z-]+(?:\s|$)|$)/);
  const cwd = cwdMatch ? cwdMatch[1] : readArgument(row.command, "--cwd");
  const children = rows.filter((candidate) => candidate.ppid === row.pid).map((candidate) => candidate.pid);
  // Active wins: a broker serving a queued/running job is LIVE wherever its cwd is (a temp or
  // scratch workspace is still a workspace). Only an inactive broker can be STALE or IDLE.
  const registered = brokerStateByPid.get(row.pid);
  let verdict = "STALE";
  if (registered?.active) {
    verdict = "LIVE";
  } else if (cwd && fs.existsSync(cwd) && !isUnderTmp(cwd) && registered) {
    verdict = "IDLE";
  }
  const values = [row.pid, row.etime, children.join(","), cwd, verdict];
  console.log(values.map((value) => `x${Buffer.from(String(value), "utf8").toString("base64")}`).join("\t"));
}
' "$snapshot" "${TMPDIR:-/tmp}" "${broker_files[@]}") || {
  printf '%s\n' 'CODEX BROKERS: unavailable (process inspection failed)'
  exit 0
}

decode_field() {
  node -e 'process.stdout.write(Buffer.from(process.argv[1].slice(1), "base64").toString("utf8"));' "$1"
}

is_alive() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && kill -0 "$1" 2>/dev/null
}

reap() {
  local broker_pid="$1"
  local child_csv="$2"
  local candidate
  local used_sigkill=false
  local targets=("$broker_pid")

  if [ -n "$child_csv" ]; then
    IFS=',' read -r -a children <<< "$child_csv"
    targets+=("${children[@]}")
  fi
  for candidate in "${targets[@]}"; do
    is_alive "$candidate" && kill -TERM "$candidate" 2>/dev/null || true
  done
  sleep 3
  for candidate in "${targets[@]}"; do
    if is_alive "$candidate"; then
      kill -KILL "$candidate" 2>/dev/null || true
      used_sigkill=true
    fi
  done
  if [ "$used_sigkill" = true ]; then
    printf '%s' 'reaped (SIGKILL required)'
  else
    printf '%s' 'reaped'
  fi
}

found=false
while IFS=$'\t' read -r encoded_pid encoded_etime encoded_children encoded_cwd encoded_verdict; do
  [ -n "${encoded_pid:-}" ] || continue
  found=true
  pid=$(decode_field "$encoded_pid")
  etime=$(decode_field "$encoded_etime")
  children=$(decode_field "$encoded_children")
  cwd=$(decode_field "$encoded_cwd")
  verdict=$(decode_field "$encoded_verdict")
  action='listed'
  if [ "$verdict" = 'STALE' ] && [ "$reap_stale" = true ]; then
    action=$(reap "$pid" "$children")
  elif [ "$verdict" = 'IDLE' ] && [ "$restart_idle" = true ]; then
    action=$(reap "$pid" "$children")
  fi
  printf 'CODEX BROKER %s cwd=%s etime=%s children=%s verdict=%s action=%s\n' "$pid" "${cwd:--}" "$etime" "${children:--}" "$verdict" "$action"
done <<< "$records"

if [ "$found" = false ]; then
  printf '%s\n' 'CODEX BROKERS: none'
fi
