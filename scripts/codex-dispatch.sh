#!/usr/bin/env bash
# Dispatch a Codex background task, verify its placement, and print the PID-bridge wait command.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/codex-dispatch.sh [--cwd <dir>] [--model <m>] [--effort <e>] [--read-only] [--resume] [--no-wait] [--force] [--json] (--prompt-file <f> | -- <prompt words...>)' >&2
}

fail() {
  printf 'CODEX DISPATCH: %s\n' "$1" >&2
  exit "$2"
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Selftest hooks: replace the companion and job-listing entry points without a real Codex runtime.
codex_sh=${CODEX_DISPATCH_CODEX_SH:-"$script_dir/codex.sh"}
jobs_sh=${CODEX_DISPATCH_JOBS_SH:-"$script_dir/codex-jobs.sh"}
cwd="$PWD"
model=''
effort=''
read_only=false
resume=false
no_wait=false
force=false
json=false
prompt_file=''
temporary_prompt=''

cleanup() {
  [ -z "$temporary_prompt" ] || rm -f -- "$temporary_prompt"
}
trap cleanup EXIT HUP INT TERM

real_path() {
  node -e '
const fs = require("fs");
try {
  process.stdout.write(fs.realpathSync.native(process.argv[1]));
} catch {
  process.exit(1);
}
' "$1"
}

encode_fields() {
  local json_value="$1"
  shift
  node -e '
const value = JSON.parse(process.argv[1]);
const fields = process.argv.slice(2);
for (const field of fields) {
  const item = Object.prototype.hasOwnProperty.call(value, field) ? value[field] : "";
  process.stdout.write(`x${Buffer.from(String(item ?? ""), "utf8").toString("base64")}\t`);
}
 ' "$json_value" "$@" 2>/dev/null
}

decode_field() {
  node -e 'process.stdout.write(Buffer.from(process.argv[1].slice(1), "base64").toString("utf8"));' "$1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      cwd="$2"
      shift 2
      ;;
    --model)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      model="$2"
      shift 2
      ;;
    --effort)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      effort="$2"
      shift 2
      ;;
    --prompt-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ -z "$prompt_file" ] || { usage; exit 2; }
      prompt_file="$2"
      shift 2
      ;;
    --read-only)
      read_only=true
      shift
      ;;
    --resume)
      resume=true
      shift
      ;;
    --no-wait)
      no_wait=true
      shift
      ;;
    --force)
      force=true
      shift
      ;;
    --json)
      json=true
      shift
      ;;
    --)
      shift
      [ -z "$prompt_file" ] || { usage; exit 2; }
      [ "$#" -gt 0 ] || { usage; exit 2; }
      temporary_prompt=$(mktemp "${TMPDIR:-/tmp}/codex-dispatch-prompt.XXXXXX") || exit 1
      printf '%s\n' "$*" > "$temporary_prompt"
      prompt_file="$temporary_prompt"
      break
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

if [ -z "$prompt_file" ] && [ ! -t 0 ]; then
  temporary_prompt=$(mktemp "${TMPDIR:-/tmp}/codex-dispatch-prompt.XXXXXX") || exit 1
  cat > "$temporary_prompt"
  prompt_file="$temporary_prompt"
fi

[ -n "$prompt_file" ] && [ -f "$prompt_file" ] && [ -s "$prompt_file" ] || { usage; exit 2; }
workspace=$(real_path "$cwd") || fail "invalid workspace: $cwd" 2

if [ "$force" = false ]; then
  active_jobs=$("$jobs_sh" --cwd "$workspace" --active --json)
  active_fields=$(node -e '
const jobs = JSON.parse(process.argv[1]);
if (!Array.isArray(jobs)) process.exit(1);
for (const job of jobs) {
  if (!job || (job.status !== "queued" && job.status !== "running") || job.jobClass !== "task") continue;
  const values = [job.id, job.status];
  console.log(values.map((value) => `x${Buffer.from(String(value ?? ""), "utf8").toString("base64")}`).join("\t"));
}
' "$active_jobs" 2>/dev/null) || fail 'active-job check returned invalid JSON' 1
  while IFS=$'\t' read -r encoded_active_id encoded_active_status; do
    [ -n "${encoded_active_id:-}" ] || continue
    active_id=$(decode_field "$encoded_active_id")
    active_status=$(decode_field "$encoded_active_status")
    fail "refused — $active_id is already $active_status in this workspace" 3
  done <<< "$active_fields"
fi

launch_args=("$codex_sh" task --background --json --cwd "$workspace")
if [ "$read_only" = false ]; then
  launch_args+=(--write)
fi
[ -z "$model" ] || launch_args+=(--model "$model")
[ -z "$effort" ] || launch_args+=(--effort "$effort")
[ "$resume" = false ] || launch_args+=(--resume-last)
launch_args+=(--prompt-file "$prompt_file")

launch_json=$("${launch_args[@]}")
if ! launch_fields=$(encode_fields "$launch_json" jobId logFile); then
  fail 'launch returned no jobId' 4
fi
IFS=$'\t' read -r encoded_job_id encoded_log_file _ <<< "$launch_fields"
job_id=$(decode_field "$encoded_job_id")
log_file=$(decode_field "$encoded_log_file")
[ -n "$job_id" ] || fail 'launch returned no jobId' 4

placement_status='not-visible'
placement_workspace='-'
placement_pid='-'
placement_ok=false
for attempt in {1..10}; do
  if status_json=$("$codex_sh" status --json --cwd "$workspace"); then
    if placement_fields=$(node -e '
const id = process.argv[1];
try {
  const state = JSON.parse(process.argv[2]);
  const job = Array.isArray(state.running) ? state.running.find((item) => item && String(item.id) === id) : null;
  const values = job ? ["visible", job.status, job.workspaceRoot, job.pid, job.threadId] : ["absent", "", "", "", ""];
  console.log(values.map((value) => `x${Buffer.from(String(value ?? ""), "utf8").toString("base64")}`).join("\t"));
} catch {
  process.exit(1);
}
' "$job_id" "$status_json" 2>/dev/null); then
      IFS=$'\t' read -r encoded_visible encoded_status encoded_workspace encoded_pid encoded_thread_id <<< "$placement_fields"
      visible=$(decode_field "$encoded_visible")
      placement_status=$(decode_field "$encoded_status")
      placement_workspace=$(decode_field "$encoded_workspace")
      placement_pid=$(decode_field "$encoded_pid")
      placement_thread_id=$(decode_field "$encoded_thread_id")
      if [ "$visible" = 'visible' ]; then
        if placement_workspace_real=$(real_path "$placement_workspace" 2>/dev/null); then
          if { [ "$placement_status" = 'queued' ] || [ "$placement_status" = 'running' ]; } &&
            [ "$placement_workspace_real" = "$workspace" ] &&
            [[ "$placement_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$placement_pid" 2>/dev/null; then
            placement_ok=true
            break
          fi
        fi
        break
      fi
    fi
  fi
  [ "$attempt" -eq 10 ] || sleep 1
done

if [ "$placement_ok" = false ]; then
  printf 'CODEX DISPATCH: placement failed — expected id=%s status=queued|running workspaceRoot=%s livePid=true; found status=%s workspaceRoot=%s pid=%s\n' \
    "$job_id" "$workspace" "$placement_status" "$placement_workspace" "$placement_pid" >&2
  "$codex_sh" cancel "$job_id" --cwd "$workspace" || true
  exit 5
fi

wait_command="scripts/codex-wait.sh $job_id --cwd $workspace"
if [ "$json" = true ]; then
  node -e '
console.log(JSON.stringify({
  jobId: process.argv[1],
  status: process.argv[2],
  workspaceRoot: process.argv[3],
  logFile: process.argv[4],
  waitCommand: process.argv[5],
  threadId: process.argv[6]
}));
' "$job_id" "$placement_status" "$workspace" "$log_file" "$wait_command" "${placement_thread_id:-}"
else
  printf 'CODEX DISPATCH: %s queued in %s\n' "$job_id" "$workspace"
  if [ "$no_wait" = false ]; then
    printf 'CODEX DISPATCH: wait with %s\n' "$wait_command"
  fi
fi
