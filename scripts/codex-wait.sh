#!/usr/bin/env bash
# Wait for a Codex companion background job without losing orphaned workers.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/codex-wait.sh <job-id> [--cwd <dir>] [--interval <sec>] [--max-minutes <n>]' >&2
}

fail() {
  printf 'codex-wait: %s\n' "$1" >&2
  exit 4
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
job_id=''
cwd="$PWD"
interval=60
max_minutes=180

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

job_id="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      cwd="$2"
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      interval="$2"
      shift 2
      ;;
    --max-minutes)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      max_minutes="$2"
      shift 2
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

case "$interval" in
  ''|*[!0-9]*|0) fail '--interval must be a positive integer' ;;
esac
case "$max_minutes" in
  ''|*[!0-9]*) fail '--max-minutes must be a non-negative integer' ;;
esac

if [ -n "${CODEX_WAIT_JOB_FILE:-}" ]; then
  job_file="$CODEX_WAIT_JOB_FILE"
else
  plugin_root=$(bash "$script_dir/codex-plugin-root.sh" 2>/dev/null) || fail 'Codex plugin root could not be resolved'
  job_file=$(CODEX_STATE_MODULE="$plugin_root/scripts/lib/state.mjs" node --input-type=module -e '
const { resolveJobFile } = await import(process.env.CODEX_STATE_MODULE);
console.log(resolveJobFile(process.argv[1], process.argv[2]));
' -- "$cwd" "$job_id" 2>/dev/null) || fail 'job file could not be resolved'
fi

read_record() {
  node -e '
const fs = require("fs");
try {
  const job = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (!job || typeof job !== "object" || typeof job.status !== "string") process.exit(4);
  const values = [job.id, job.status, job.phase, job.pid, job.logFile, job.createdAt]
    .map((value) => String(value ?? "").replace(/[\r\n]/g, " "));
  console.log(values.map((value) => `x${Buffer.from(value, "utf8").toString("base64")}`).join("\t"));
} catch {
  process.exit(4);
}
' "$job_file" 2>/dev/null
}

decode_field() {
  node -e 'process.stdout.write(Buffer.from(process.argv[1].slice(1), "base64").toString("utf8"));' "$1"
}

epoch_from_iso() {
  node -e '
const value = Date.parse(process.argv[1]);
if (!Number.isFinite(value)) process.exit(1);
console.log(Math.floor(value / 1000));
' "$1" 2>/dev/null
}

started_epoch=$(date +%s)
max_seconds=$((max_minutes * 60))

while :; do
  if ! encoded_record=$(read_record); then
    exit 4
  fi
  IFS=$'\t' read -r encoded_id encoded_status encoded_phase encoded_pid encoded_log encoded_created <<< "$encoded_record"
  record_id=$(decode_field "$encoded_id")
  status=$(decode_field "$encoded_status")
  phase=$(decode_field "$encoded_phase")
  pid=$(decode_field "$encoded_pid")
  log_file=$(decode_field "$encoded_log")
  created_at=$(decode_field "$encoded_created")
  [ -n "$record_id" ] || record_id="$job_id"
  [ -n "$phase" ] || phase='-'
  [ -n "$log_file" ] || log_file='-'

  case "$status" in
    completed)
      printf 'CODEX JOB %s: %s phase=%s log=%s\n' "$record_id" "$status" "$phase" "$log_file"
      exit 0
      ;;
    failed|cancelled)
      printf 'CODEX JOB %s: %s phase=%s log=%s\n' "$record_id" "$status" "$phase" "$log_file"
      exit 1
      ;;
    unknown)
      # The companion already reconciled a dead worker: an integrity incident, not a failure.
      printf 'CODEX JOB %s: ORPHANED (status=unknown phase=%s) log=%s\n' "$record_id" "$phase" "$log_file"
      exit 2
      ;;
  esac

  pid_display="${pid:-null}"
  pid_alive=false
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
    pid_alive=true
  fi

  queued_is_old=false
  if [ "$status" = 'queued' ]; then
    if created_epoch=$(epoch_from_iso "$created_at"); then
      now_epoch=$(date +%s)
      if [ $((now_epoch - created_epoch)) -ge 120 ]; then
        queued_is_old=true
      fi
    fi
  fi

  if { [ "$status" = 'running' ] || { [ "$status" = 'queued' ] && [ "$queued_is_old" = true ]; }; } && [ "$pid_alive" = false ]; then
    printf 'CODEX JOB %s: ORPHANED (worker pid %s gone) log=%s\n' "$record_id" "$pid_display" "$log_file"
    exit 2
  fi

  now_epoch=$(date +%s)
  if [ $((now_epoch - started_epoch)) -ge "$max_seconds" ]; then
    printf 'CODEX JOB %s: STILL RUNNING after %sm\n' "$record_id" "$max_minutes"
    exit 3
  fi

  sleep "$interval"
done
