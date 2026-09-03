#!/usr/bin/env bash
# Host-side, allowlisted build mailbox for sandboxed Codex turns.
set -u

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script_path="$script_dir/codex-mailbox.sh"
table_names=()
table_commands=()

usage() {
  printf '%s\n' 'Usage:' >&2
  printf '%s\n' '  scripts/codex-mailbox.sh start --workspace <dir> [--wall <minutes>]' >&2
  printf '%s\n' '  scripts/codex-mailbox.sh stop --workspace <dir>' >&2
  printf '%s\n' '  scripts/codex-mailbox.sh status [--workspace <dir>]' >&2
  printf '%s\n' '  scripts/codex-mailbox.sh once --workspace <dir>' >&2
}

is_task_name() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_safe_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

add_task() {
  local name="$1" command="$2" index
  if ! is_task_name "$name"; then
    printf 'CODEX MAILBOX: invalid task name in task table: %s\n' "$name" >&2
    return 1
  fi
  if [ -z "$command" ]; then
    printf 'CODEX MAILBOX: empty command for task: %s\n' "$name" >&2
    return 1
  fi
  for index in "${table_names[@]+"${table_names[@]}"}"; do
    if [ "$index" = "$name" ]; then
      printf 'CODEX MAILBOX: duplicate task name in task table: %s\n' "$name" >&2
      return 1
    fi
  done
  table_names+=("$name")
  table_commands+=("$command")
}

load_task_table() {
  local tasks_file row name command
  table_names=()
  table_commands=()
  if [ -n "${CODEX_MAILBOX_TASKS:-}" ]; then
    tasks_file="$CODEX_MAILBOX_TASKS"
    if [ ! -f "$tasks_file" ]; then
      printf 'CODEX MAILBOX: CODEX_MAILBOX_TASKS is not a file: %s\n' "$tasks_file" >&2
      return 1
    fi
    while IFS= read -r row || [ -n "${row:-}" ]; do
      if [[ "$row" = *$'\t'* ]]; then
        name=${row%%$'\t'*}
        command=${row#*$'\t'}
      else
        name="$row"
        command=''
      fi
      add_task "$name" "$command" || return 1
    done < "$tasks_file"
  else
    add_task build 'swift build' || return 1
    add_task test 'scripts/test.sh' || return 1
  fi
  if [ "${#table_names[@]}" -eq 0 ]; then
    printf '%s\n' 'CODEX MAILBOX: task table is empty' >&2
    return 1
  fi
}

lookup_task() {
  local requested="$1" i
  selected_command=''
  i=0
  while [ "$i" -lt "${#table_names[@]}" ]; do
    if [ "${table_names[$i]}" = "$requested" ]; then
      selected_command="${table_commands[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

canonical_workspace() {
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

mailbox_path() {
  printf '%s/.codex-mailbox' "$1"
}

host_state_path() {
  local workspace="$1" workspace_name workspace_hash
  workspace_name=$(basename "$workspace")
  workspace_hash=$(printf '%s' "$workspace" | shasum -a 256 | awk '{ print substr($1, 1, 16) }') || return 1
  printf '%s/codex-mailbox/%s-%s' "${TMPDIR:-/tmp}" "$workspace_name" "$workspace_hash"
}

prepare_host_state() {
  local workspace="$1" state_root state
  state_root="${TMPDIR:-/tmp}/codex-mailbox"
  if [ -L "$state_root" ] || { [ -e "$state_root" ] && [ ! -d "$state_root" ]; }; then
    printf 'CODEX MAILBOX: host state root is not a directory: %s\n' "$state_root" >&2
    return 1
  fi
  [ -d "$state_root" ] || mkdir -m 700 "$state_root" || return 1
  chmod 700 "$state_root" || return 1
  state=$(host_state_path "$workspace") || return 1
  if [ -L "$state" ] || { [ -e "$state" ] && [ ! -d "$state" ]; }; then
    printf 'CODEX MAILBOX: host state directory is not a directory: %s\n' "$state" >&2
    return 1
  fi
  [ -d "$state" ] || mkdir -m 700 "$state" || return 1
  chmod 700 "$state" || return 1
  printf '%s\n' "$state"
}

validate_mailbox() {
  local mailbox="$1"
  if [ -L "$mailbox" ] || [ ! -d "$mailbox" ]; then
    printf 'CODEX MAILBOX: mailbox is not a directory: %s\n' "$mailbox" >&2
    return 1
  fi
}

write_response() {
  local state="$1" mailbox="$2" id="$3" task="$4" exit_code="$5" log="$6" tail_text="$7" error_text="$8"
  local response="$mailbox/resp-$id.json" temporary
  temporary=$(mktemp "$state/resp-$id.json.tmp.XXXXXX") || return 1
  if [ -n "$error_text" ]; then
    node -e '
const fs = require("fs");
const [output, id, task, exitCode, log, tail, error] = process.argv.slice(1);
fs.writeFileSync(output, JSON.stringify({ id, task, exit: Number(exitCode), log, tail, error }) + "\n");
' -- "$temporary" "$id" "$task" "$exit_code" "$log" "$tail_text" "$error_text" || return 1
  else
    node -e '
const fs = require("fs");
const [output, id, task, exitCode, log, tail] = process.argv.slice(1);
fs.writeFileSync(output, JSON.stringify({ id, task, exit: Number(exitCode), log, tail }) + "\n");
' -- "$temporary" "$id" "$task" "$exit_code" "$log" "$tail_text" || return 1
  fi
  mv -f "$temporary" "$response"
}

read_request_task() {
  node -e '
const fs = require("fs");
const request = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (!request || typeof request.task !== "string") process.exit(2);
process.stdout.write(request.task);
' -- "$1"
}

process_request() {
  local workspace="$1" mailbox="$2" state="$3" request="$4" base id consumed task staged_log final_log tail_text exit_code error_text
  base=$(basename "$request")
  id=${base#req-}
  id=${id%.json}
  if ! is_safe_id "$id"; then
    printf 'CODEX MAILBOX: ignoring request with unsafe id: %s\n' "$base" >&2
    return 1
  fi
  if [ ! -f "$request" ] || [ -L "$request" ]; then
    printf 'CODEX MAILBOX: refusing non-regular request: %s\n' "$base" >&2
    return 1
  fi
  consumed="$mailbox/req-$id.json.done"
  mv "$request" "$consumed" || return 1
  staged_log=$(mktemp "$state/log-$id.txt.XXXXXX") || return 1
  final_log="$mailbox/log-$id.txt"
  task=''
  if ! task=$(read_request_task "$consumed" 2>/dev/null); then
    task=''
  fi

  exit_code=0
  error_text=''
  if ! is_task_name "$task" || ! lookup_task "$task"; then
    exit_code=-1
    error_text="task not allowlisted: $task"
    printf '%s\n' "$error_text" > "$staged_log"
  else
    # `selected_command` originates only in the host-side table. The request's task is used above
    # solely for a quoted equality lookup; it is never interpolated into this shell invocation.
    (
      cd -- "$workspace" || exit 127
      bash -c "$selected_command"
    ) > "$staged_log" 2>&1
    exit_code=$?
  fi
  tail_text=$(tail -n 40 "$staged_log" 2>/dev/null || true)
  mv -f "$staged_log" "$final_log" || return 1
  write_response "$state" "$mailbox" "$id" "$task" "$exit_code" "$final_log" "$tail_text" "$error_text"
}

process_pending() {
  local workspace="$1" mailbox state request result=0
  mailbox=$(mailbox_path "$workspace")
  validate_mailbox "$mailbox" || return 1
  state=$(prepare_host_state "$workspace") || return 1
  for request in "$mailbox"/req-*.json; do
    [ -f "$request" ] || continue
    process_request "$workspace" "$mailbox" "$state" "$request" || result=1
  done
  return "$result"
}

read_runner_state() {
  local state_dir="$1" state="$state_dir/runner.pid"
  [ -f "$state" ] || return 1
  IFS=$'\t' read -r runner_state_pid runner_state_started runner_state_deadline < "$state"
  [[ "${runner_state_pid:-}" =~ ^([2-9]|[1-9][0-9]+)$ ]] || return 1
  [[ "${runner_state_deadline:-}" =~ ^[0-9]+$ ]] || return 1
}

runner_cleanup() {
  local state="$1" current_pid
  if read_runner_state "$state"; then
    current_pid="$runner_state_pid"
    if [ "$current_pid" = "$$" ]; then
      rm -f "$state/runner.pid"
    fi
  fi
}

run_runner() {
  local workspace="$1" wall="$2" state now deadline
  state=$(prepare_host_state "$workspace") || return 1
  trap 'runner_cleanup "$state"' EXIT HUP INT TERM
  if ! load_task_table; then
    printf '%s\n' 'CODEX MAILBOX: runner stopped because the task table is invalid' >&2
    return 1
  fi
  now=$(date +%s)
  deadline=$((now + wall * 60))
  printf 'CODEX MAILBOX: runner pid=%s workspace=%s wall=%sm\n' "$$" "$workspace" "$wall"
  while :; do
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || break
    process_pending "$workspace" || printf '%s\n' 'CODEX MAILBOX: request processing failed' >&2
    sleep 1 || break
  done
  printf 'CODEX MAILBOX: runner wall elapsed workspace=%s\n' "$workspace"
}

start_runner() {
  local workspace="$1" wall="$2" mailbox state now deadline runner_pid workspace_b64
  mailbox=$(mailbox_path "$workspace")
  validate_mailbox "$mailbox" || return 1
  state=$(prepare_host_state "$workspace") || return 1
  if read_runner_state "$state" && kill -0 "$runner_state_pid" 2>/dev/null; then
    printf 'CODEX MAILBOX: runner already running for %s (pid %s)\n' "$workspace" "$runner_state_pid" >&2
    return 1
  fi
  rm -f "$state/runner.pid"
  now=$(date +%s)
  deadline=$((now + wall * 60))
  workspace_b64=$(node -e 'process.stdout.write(Buffer.from(process.argv[1], "utf8").toString("base64"));' -- "$workspace") || return 1
  : > "$state/runner.log" || return 1
  nohup bash "$script_path" __run --codex-mailbox-runner --workspace-b64 "$workspace_b64" --wall "$wall" \
    >> "$state/runner.log" 2>&1 < /dev/null &
  runner_pid=$!
  printf '%s\t%s\t%s\n' "$runner_pid" "$now" "$deadline" > "$state/runner.pid.tmp" || return 1
  mv -f "$state/runner.pid.tmp" "$state/runner.pid" || return 1
  printf '%s\n' "$mailbox"
}

stop_runner() {
  local workspace="$1" state attempts=0
  state=$(host_state_path "$workspace") || return 1
  if ! read_runner_state "$state"; then
    printf 'CODEX MAILBOX: no runner recorded for %s\n' "$workspace" >&2
    return 1
  fi
  if ! [[ "$runner_state_pid" =~ ^([2-9]|[1-9][0-9]+)$ ]]; then
    printf 'CODEX MAILBOX: refusing unsafe runner pid for %s\n' "$workspace" >&2
    return 1
  fi
  if ! kill -0 "$runner_state_pid" 2>/dev/null; then
    rm -f "$state/runner.pid"
    printf 'CODEX MAILBOX: runner already dead for %s (pid %s)\n' "$workspace" "$runner_state_pid"
    return 0
  fi
  kill -TERM "$runner_state_pid" || return 1
  while kill -0 "$runner_state_pid" 2>/dev/null && [ "$attempts" -lt 2 ]; do
    sleep 1
    attempts=$((attempts + 1))
  done
  if kill -0 "$runner_state_pid" 2>/dev/null; then
    # A reparented, already-exited runner can remain a zombie briefly, for which `kill -0` is
    # still true. An explicit final signal is safe because this is the PID recorded in the
    # host-private state directory; do not broaden it to a process-name search or process-group kill.
    kill -KILL "$runner_state_pid" 2>/dev/null || true
  fi
  rm -f "$state/runner.pid"
  printf 'CODEX MAILBOX: stopped workspace=%s pid=%s\n' "$workspace" "$runner_state_pid"
}

status_workspace() {
  local workspace="$1" state now remaining alive
  state=$(host_state_path "$workspace") || return 1
  if ! read_runner_state "$state"; then
    printf 'CODEX MAILBOX workspace=%s pid=- state=dead wall_remaining=0m\n' "$workspace"
    return 0
  fi
  now=$(date +%s)
  remaining=$((runner_state_deadline - now))
  [ "$remaining" -gt 0 ] || remaining=0
  if kill -0 "$runner_state_pid" 2>/dev/null; then alive=alive; else alive=dead; fi
  printf 'CODEX MAILBOX workspace=%s pid=%s state=%s wall_remaining=%sm\n' \
    "$workspace" "$runner_state_pid" "$alive" "$(( (remaining + 59) / 60 ))"
}

status_all() {
  local snapshot pid workspace_b64 workspace found=false
  snapshot=$(mktemp "${TMPDIR:-/tmp}/codex-mailbox-status.XXXXXX") || return 1
  if ! ps -axww -o pid= -o command= > "$snapshot" 2>/dev/null; then
    rm -f "$snapshot"
    printf '%s\n' 'CODEX MAILBOX: process listing unavailable' >&2
    return 1
  fi
  while IFS=$'\t' read -r pid workspace_b64; do
    [ -n "${pid:-}" ] || continue
    workspace=$(node -e 'process.stdout.write(Buffer.from(process.argv[1], "base64").toString("utf8"));' -- "$workspace_b64") || continue
    status_workspace "$workspace"
    found=true
  done < <(awk '
    /--codex-mailbox-runner/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "--workspace-b64" && i < NF) { print $1 "\t" $(i + 1); break }
      }
    }
  ' "$snapshot")
  rm -f "$snapshot"
  if [ "$found" = false ]; then
    printf '%s\n' 'CODEX MAILBOX: none'
  fi
}

subcommand="${1:-}"
[ "$#" -gt 0 ] && shift
workspace_arg=''
wall=60
runner_marker=false
workspace_b64=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      workspace_arg="$2"
      shift 2
      ;;
    --workspace-b64)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      workspace_b64="$2"
      shift 2
      ;;
    --wall)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      wall="$2"
      shift 2
      ;;
    --codex-mailbox-runner)
      runner_marker=true
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

if ! is_positive_integer "$wall"; then
  printf 'CODEX MAILBOX: --wall must be a positive integer number of minutes\n' >&2
  exit 2
fi

if [ "$subcommand" = '__run' ]; then
  [ "$runner_marker" = true ] && [ -n "$workspace_b64" ] || { usage; exit 2; }
  workspace_arg=$(node -e 'process.stdout.write(Buffer.from(process.argv[1], "base64").toString("utf8"));' -- "$workspace_b64") || exit 2
fi

if [ "$subcommand" != 'status' ] || [ -n "$workspace_arg" ]; then
  [ -n "$workspace_arg" ] || { usage; exit 2; }
  workspace=$(canonical_workspace "$workspace_arg") || {
    printf 'CODEX MAILBOX: workspace is not a directory: %s\n' "$workspace_arg" >&2
    exit 2
  }
  validate_mailbox "$(mailbox_path "$workspace")" || exit 1
fi

case "$subcommand" in
  start)
    load_task_table || exit 1
    start_runner "$workspace" "$wall"
    ;;
  stop)
    stop_runner "$workspace"
    ;;
  status)
    if [ -n "$workspace_arg" ]; then status_workspace "$workspace"; else status_all; fi
    ;;
  once)
    load_task_table || exit 1
    process_pending "$workspace"
    ;;
  __run)
    run_runner "$workspace" "$wall"
    ;;
  *)
    usage
    exit 2
    ;;
esac
