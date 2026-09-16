#!/usr/bin/env bash
# List Codex companion jobs across Claude sessions and, optionally, workspaces.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/codex-jobs.sh [--cwd <dir>] [--all-workspaces] [--active] [--json]' >&2
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cwd="$PWD"
all_workspaces=false
active=false
json=false
state_files=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      cwd="$2"
      shift 2
      ;;
    --all-workspaces)
      all_workspaces=true
      shift
      ;;
    --active)
      active=true
      shift
      ;;
    --json)
      json=true
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

if [ "$all_workspaces" = true ]; then
  # Every plugin install keeps its own data root (codex-inline, codex-openai-codex, ...) next to
  # this session's; a job dispatched under another install is invisible unless the siblings are read.
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
    for state_file in "$(dirname "$CLAUDE_PLUGIN_DATA")"/*/state/*/state.json; do
      [ -f "$state_file" ] && state_files+=("$state_file")
    done
  fi
  for state_file in "${TMPDIR:-/tmp}"/codex-companion/*/state.json; do
    # The plugin's own selftest leaves fixture stores behind; they hold fake "running" jobs.
    case "$state_file" in */codex-plugin-test-*) continue ;; esac
    [ -f "$state_file" ] && state_files+=("$state_file")
  done
else
  # A store we cannot read must never look like "no jobs" (verification-integrity.md).
  plugin_root=$(bash "$script_dir/codex-plugin-root.sh" 2>/dev/null) || {
    printf '%s\n' 'CODEX JOBS: unavailable (Codex plugin root could not be resolved)' >&2; exit 1; }
  state_dir=$(CODEX_STATE_MODULE="$plugin_root/scripts/lib/state.mjs" node --input-type=module -e '
const { resolveStateDir } = await import(process.env.CODEX_STATE_MODULE);
console.log(resolveStateDir(process.argv[1]));
' -- "$cwd" 2>/dev/null) || {
    printf '%s\n' 'CODEX JOBS: unavailable (state dir could not be resolved for the given --cwd)' >&2; exit 1; }
  [ -f "$state_dir/state.json" ] && state_files+=("$state_dir/state.json")
fi

output_mode='text'
[ "$json" = true ] && output_mode='json'
active_flag='false'
[ "$active" = true ] && active_flag='true'

node -e '
const fs = require("fs");
const activeOnly = process.argv[1] === "true";
const outputMode = process.argv[2];
const stateFiles = process.argv.slice(3);
// A record whose tracked pid is gone while its status still says queued/running is an ORPHAN, not
// pending work (rules/codex-job-status-integrity.md). --active is consulted precisely when nobody
// is watching, so it must not report a worker that died days ago as live: an instrument that
// cannot tell "still executing" from "not looking" reports unknown dressed up as good.
function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid < 1) return null;  // nothing to check — unverifiable, not alive
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM" ? true : false;
  }
}
// Liveness is the PID *and* the log mtime (rules/codex-dispatch-protocol.md §1); the pid alone
// answers only half the question. A live pid that has written nothing for the cancellation window
// is a stall, and a dead pid over a log written seconds ago is a record contradicting itself —
// both are reported rather than folded into "live" or "gone".
const staleSeconds = Number(process.env.CC_HARNESS_CODEX_LOG_STALE_SECONDS || 900);
function logAgeSeconds(logFile) {
  if (typeof logFile !== "string" || logFile === "") return null;
  try {
    return Math.max(0, Math.round((Date.now() - fs.statSync(logFile).mtimeMs) / 1000));
  } catch {
    return null;  // no log to read — unverified, never "fresh"
  }
}
const jobs = [];
let orphaned = 0;
let unverifiable = 0;
let stalled = 0;
let unlogged = 0;
let contradictory = 0;
for (const stateFile of stateFiles) {
  try {
    const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    if (!Array.isArray(state.jobs)) continue;
    for (const job of state.jobs) {
      if (!job || typeof job !== "object") continue;
      const alive = pidAlive(job.pid);
      const age = logAgeSeconds(job.logFile);
      const fresh = age !== null && age <= staleSeconds;
      const annotated = { ...job, pidAlive: alive, logAgeSeconds: age, logFresh: fresh };
      if (activeOnly) {
        if (job.status !== "queued" && job.status !== "running") continue;
        if (alive === false && !fresh) { orphaned += 1; continue; }
        if (alive === false) { contradictory += 1; }
        else if (alive === null) { unverifiable += 1; }
        else if (age === null) { unlogged += 1; }
        else if (!fresh) { stalled += 1; }
      }
      jobs.push(annotated);
    }
  } catch {
    // An incomplete state write is not a usage error; omit it this tick.
  }
}
jobs.sort((left, right) => String(right.updatedAt ?? "").localeCompare(String(left.updatedAt ?? "")));
function pidState(pid) {
  const alive = pidAlive(pid);
  if (alive === null) return "-";
  return `${pid}(${alive ? "alive" : "dead"})`;
}
// Counted out loud, never silently dropped: "0 live" and "0 seen" are different answers, and a
// filter that hid its omissions would make an orphan look like no work at all.
function reportOmissions(stream) {
  if (!activeOnly) return;
  if (orphaned > 0) {
    stream.write(`CODEX JOBS: ${orphaned} orphaned record(s) omitted — status says queued/running but the tracked pid is gone (codex-job-status-integrity.md)\n`);
  }
  if (unverifiable > 0) {
    stream.write(`CODEX JOBS: ${unverifiable} record(s) listed with no usable pid — liveness unverified\n`);
  }
  if (contradictory > 0) {
    stream.write(`CODEX JOBS: ${contradictory} record(s) listed whose pid is gone but whose log was written within ${staleSeconds}s — the record contradicts itself, inspect before reusing (codex-job-status-integrity.md)\n`);
  }
  if (unlogged > 0) {
    stream.write(`CODEX JOBS: ${unlogged} record(s) alive by pid only — no readable log to date the work\n`);
  }
  if (stalled > 0) {
    stream.write(`CODEX JOBS: ${stalled} record(s) alive by pid only — no log write in over ${staleSeconds}s (codex-dispatch-protocol.md §4)\n`);
  }
  if (jobs.length === 0) {
    stream.write(orphaned > 0
      ? "CODEX JOBS: no live work (every queued/running record is orphaned — dead pid, no recent log write)\n"
      : "CODEX JOBS: no live work\n");
  }
}
if (outputMode === "json") {
  console.log(JSON.stringify(jobs));
  reportOmissions(process.stderr);
} else {
  for (const job of jobs) {
    console.log([
      String(job.id ?? "-"),
      String(job.status ?? "-"),
      String(job.phase ?? "-"),
      pidState(job.pid),
      job.logAgeSeconds === null ? "log:-" : `log:${job.logAgeSeconds}s`,
      String(job.sessionId ?? "-").slice(0, 8) || "-",
      String(job.updatedAt ?? "-"),
      String(job.workspaceRoot ?? "-")
    ].join(" "));
  }
  reportOmissions(process.stdout);
}
' "$active_flag" "$output_mode" ${state_files[@]+"${state_files[@]}"} || {
  printf '%s\n' 'CODEX JOBS: unavailable (state could not be read)' >&2; exit 1; }
