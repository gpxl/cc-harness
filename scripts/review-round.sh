#!/usr/bin/env bash
# Dispatch one bounded, read-only branch-review round and persist its reviewer thread.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/review-round.sh <base> [--bead <id>] [--user-approved "<words>"] [--dry-run] [--selftest]' >&2
  printf '%s\n' '       scripts/review-round.sh --collect <job-id> [--round <k>]' >&2
  printf '%s\n' '       scripts/review-round.sh --adopt <round> <job-id>' >&2
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
mode='review'
base=''
bead=''
user_approved=''
dry_run=false
selftest=false
collect_job=''
collect_round=''
adopt_round=''
adopt_job=''

[ "$#" -gt 0 ] || { usage; exit 2; }
case "$1" in
  --collect)
    mode='collect'
    [ "$#" -ge 2 ] || { usage; exit 2; }
    collect_job=$2
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --round) [ "$#" -ge 2 ] || { usage; exit 2; }; collect_round=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
      esac
    done
    ;;
  --adopt)
    mode='adopt'
    [ "$#" -eq 3 ] || { usage; exit 2; }
    adopt_round=$2
    adopt_job=$3
    ;;
  *)
    base=$1
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --bead) [ "$#" -ge 2 ] || { usage; exit 2; }; bead=$2; shift 2 ;;
        --user-approved) [ "$#" -ge 2 ] || { usage; exit 2; }; user_approved=$2; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        --selftest) selftest=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
      esac
    done
    ;;
esac

if [ "$selftest" = true ]; then
  exec bash "$script_dir/review-round-selftest.sh"
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf '%s\n' 'review-round: must run inside a Git worktree' >&2; exit 2; }
common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || exit 2
case "$common_dir" in /*) ;; *) common_dir="$repo_root/$common_dir" ;; esac
branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD)
slug=$(printf '%s' "$branch" | sed 's/[^[:alnum:]._-]/-/g')
state_dir="$common_dir/review-rounds"
counter="$state_dir/$slug"
thread_file="$counter.thread"
job_file="$counter.job"
thread_wait_seconds=${REVIEW_ROUND_THREAD_WAIT_SECONDS:-30}
case "$thread_wait_seconds" in
  ''|*[!0-9]*) printf '%s\n' 'review-round: REVIEW_ROUND_THREAD_WAIT_SECONDS must be an integer from 0 to 30' >&2; exit 2 ;;
esac
[ "$thread_wait_seconds" -le 30 ] || { printf '%s\n' 'review-round: REVIEW_ROUND_THREAD_WAIT_SECONDS must be at most 30' >&2; exit 2; }

dispatcher=${REVIEW_ROUND_DISPATCH:-}
if [ -z "$dispatcher" ]; then
  dispatcher=$(command -v codex-dispatch.sh 2>/dev/null || printf '%s' "$script_dir/codex-dispatch.sh")
fi
jobs_tool=${REVIEW_ROUND_JOBS:-}
if [ -z "$jobs_tool" ]; then
  jobs_tool=$(command -v codex-jobs.sh 2>/dev/null || printf '%s' "$script_dir/codex-jobs.sh")
fi

read_round() {
  if [ -e "$counter" ]; then
    value=$(tr -d '[:space:]' < "$counter")
    case "$value" in ''|*[!0-9]*) printf '%s\n' 'review-round: invalid round counter' >&2; exit 1 ;; esac
    printf '%s' "$value"
  else
    printf '0'
  fi
}

job_record_from_log() {
  local log_file=$1 job_id=$2
  [ -n "$log_file" ] || return 0
  printf '%s/%s.json' "$(dirname -- "$log_file")" "$job_id"
}

thread_from_job_record() {
  local record=$1
  [ -f "$record" ] || return 0
  node -e '
const fs = require("fs");
try {
  const job = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const threadId = typeof job.threadId === "string" ? job.threadId.trim() : "";
  process.stdout.write(threadId);
} catch {
  process.exit(1);
}
' "$record" 2>/dev/null || true
}

job_record_for_workspace() {
  local job_id=$1 plugin_root
  if [ -n "${REVIEW_ROUND_JOB_RECORD:-}" ]; then
    printf '%s' "$REVIEW_ROUND_JOB_RECORD"
    return 0
  fi
  plugin_root=$(bash "$script_dir/codex-plugin-root.sh" 2>/dev/null) || return 1
  CODEX_STATE_MODULE="$plugin_root/scripts/lib/state.mjs" node --input-type=module -e '
const { resolveJobFile } = await import(process.env.CODEX_STATE_MODULE);
console.log(resolveJobFile(process.argv[1], process.argv[2]));
' -- "$repo_root" "$job_id" 2>/dev/null
}

log_from_job_record() {
  local record=$1
  node -e '
const fs = require("fs");
try {
  const job = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const logFile = typeof job.logFile === "string" ? job.logFile.trim() : "";
  if (!logFile) process.exit(1);
  process.stdout.write(logFile);
} catch {
  process.exit(1);
}
' "$record" 2>/dev/null
}

final_findings_from_log() {
  local log_file=$1
  awk '
  /^[[:space:]]*Final output:?[[:space:]]*$/ || /^\[[^]]+\][[:space:]]+Final output:?[[:space:]]*$/ { in_final = 1; saw_final = 1; next }
  in_final && /^\[[^]]+\][[:space:]]/ { exit }
  in_final && (/^### (BLOCKER|MAJOR|MINOR|NIT)[[:space:]]/ || /^(BLOCKER|MAJOR|MINOR|NIT|VERDICT|OPEN BLOCKERS):/) {
    sub(/[[:space:]]+$/, "")
    print
  }
END { exit saw_final ? 0 : 1 }
' "$log_file"
}

collect_findings() {
  local job_id=$1 requested_round=$2 round record log_file findings temp findings_lines
  if [ -n "$requested_round" ]; then
    round=$requested_round
  else
    round=$(read_round)
  fi
  case "$round" in ''|*[!0-9]*|0) printf '%s\n' 'review-round: --collect needs a positive --round or an existing round counter' >&2; exit 2 ;; esac
  record=$(job_record_for_workspace "$job_id") || { printf '%s\n' "review-round: could not resolve job record for $job_id" >&2; exit 1; }
  [ -f "$record" ] || { printf '%s\n' "review-round: job record not found for $job_id" >&2; exit 1; }
  log_file=$(log_from_job_record "$record") || { printf '%s\n' "review-round: job record has no logFile for $job_id" >&2; exit 1; }
  [ -f "$log_file" ] || { printf '%s\n' "review-round: job log not found for $job_id" >&2; exit 1; }
  mkdir -p "$state_dir"
  findings="$state_dir/$slug-r$round-findings.md"
  if [ -e "$findings" ]; then
    printf '%s\n' "$findings"
    return 0
  fi
  findings_lines=$(final_findings_from_log "$log_file") || { printf '%s\n' "review-round: Final output section not found in $log_file" >&2; exit 1; }
  temp=$(mktemp "$state_dir/.${slug}-r${round}-findings.XXXXXX") || exit 1
  if [ -n "$findings_lines" ]; then
    printf '%s\n' "$findings_lines" > "$temp"
  else
    : > "$temp"
  fi
  printf '%s\n' 'Dispositions:' >> "$temp"
  mv "$temp" "$findings"
  printf '%s\n' "$findings"
}

adopt_round() {
  local round=$1 job_id=$2 current record thread_id
  case "$round" in ''|*[!0-9]*|0) printf '%s\n' 'review-round: --adopt round must be a positive integer' >&2; exit 2 ;; esac
  current=$(read_round)
  if [ "$round" -lt "$current" ]; then
    printf 'review-round: refusing to lower round counter from %s to %s\n' "$current" "$round" >&2
    exit 1
  fi
  record=$(job_record_for_workspace "$job_id") || { printf '%s\n' "review-round: could not resolve job record for $job_id" >&2; exit 1; }
  [ -f "$record" ] || { printf '%s\n' "review-round: job record not found for $job_id" >&2; exit 1; }
  thread_id=$(thread_from_job_record "$record")
  [ -n "$thread_id" ] || { printf '%s\n' "review-round: job record has no threadId for $job_id" >&2; exit 1; }
  mkdir -p "$state_dir"
  # Persist recovered reviewer state.
  printf '%s\n' "$round" > "$counter"
  printf '%s\n' "$job_id" > "$job_file"
  printf '%s\n' "$thread_id" > "$thread_file"
  printf 'REVIEW ROUND: adopted round %s job %s\n' "$round" "$job_id"
}

case "$mode" in
  collect) collect_findings "$collect_job" "$collect_round"; exit 0 ;;
  adopt) adopt_round "$adopt_round" "$adopt_job"; exit 0 ;;
esac

wait_for_thread_id() {
  local record=$1 thread_id='' attempt=0
  while :; do
    thread_id=$(thread_from_job_record "$record")
    [ -z "$thread_id" ] || { printf '%s' "$thread_id"; return 0; }
    [ "$attempt" -ge "$thread_wait_seconds" ] && return 0
    attempt=$((attempt + 1))
    sleep 1
  done
}

lock=''
prompt_file=''
cleanup() {
  [ -z "$lock" ] || rmdir "$lock" 2>/dev/null || true
  [ -z "$prompt_file" ] || rm -f "$prompt_file"
}
trap cleanup EXIT HUP INT TERM

prepare_round() {
  previous=$(read_round)
  round=$((previous + 1))
  if [ "$round" -ge 4 ] && [ -z "$user_approved" ]; then
    printf 'review-round: round %s refused — user approval is required after round 3\n' "$round" >&2
    exit 1
  fi

  goal='branch review acceptance criteria were not supplied'
  if [ -n "$bead" ]; then
    if command -v bd >/dev/null 2>&1; then
      goal=$(bd show "$bead" 2>&1 || printf 'bead %s could not be read' "$bead")
    else
      goal="bead $bead (bd unavailable)"
    fi
  fi
  goal_line=$(printf '%s' "$goal" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  printf 'GOAL: %s | ROUND %s/3 | OPEN BLOCKERS ? | NEXT: wait for verdict\n' "$goal_line" "$round"
}

if [ "$dry_run" = false ]; then
  mkdir -p "$state_dir"
  lock="$counter.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    printf 'review-round: another round is being prepared for %s\n' "$branch" >&2
    exit 3
  fi
  prepare_round
else
  prepare_round
  printf 'REVIEW ROUND: dry run; counter remains %s\n' "$previous"
  exit 0
fi

prior_findings='(none — this is the first round)'
if [ "$round" -ge 2 ]; then
  prior_findings=''
  for ((prior=1; prior<round; prior++)); do
    findings="$state_dir/$slug-r$prior-findings.md"
    if [ -f "$findings" ]; then
      prior_findings="$prior_findings\n--- round $prior findings: $findings ---\n$(<"$findings")\n"
    else
      prior_findings="$prior_findings\n--- round $prior findings unavailable: $findings ---\n"
    fi
  done
fi

prompt_file=$(mktemp "${TMPDIR:-/tmp}/review-round-prompt.XXXXXX") || exit 1
diff=$(git diff "$base"...HEAD)
cat > "$prompt_file" <<EOF
This is a bounded, read-only branch-completion review, round $round of 3.

Purpose: find decision-changing defects in the full branch diff; do not edit files or manufacture findings.
Acceptance criteria:
$goal

Diff against $base...HEAD:
$diff

Prior-round findings and dispositions (re-trace these first when present):
$prior_findings

Report BLOCKER/MAJOR/MINOR/NIT findings with file:line, failure scenario, and required action.
Classify each finding DECISION-CHANGING or POLISH. If ready to ship, say GO plainly and early.
End with exactly: VERDICT: GO or VERDICT: NO-GO, and list OPEN BLOCKERS: <number>.
EOF

resume=false
jobs_json=''
if jobs_json=$("$jobs_tool" --cwd "$repo_root" --json 2>/dev/null); then
  :
else
  jobs_json=''
fi

if [ ! -f "$thread_file" ] && [ -f "$job_file" ] && [ -n "$jobs_json" ]; then
  recorded_job_id=$(tr -d '[:space:]' < "$job_file")
  if [ -n "$recorded_job_id" ]; then
    recorded_log_file=$(node -e '
const jobs = JSON.parse(process.argv[1]);
const id = process.argv[2];
const job = Array.isArray(jobs) ? jobs.find((item) => item && String(item.id) === id) : null;
process.stdout.write(job && job.logFile ? String(job.logFile) : "");
' "$jobs_json" "$recorded_job_id" 2>/dev/null || true)
    delayed_job_record=$(job_record_from_log "$recorded_log_file" "$recorded_job_id")
    delayed_thread_id=$(wait_for_thread_id "$delayed_job_record")
    [ -z "$delayed_thread_id" ] || printf '%s\n' "$delayed_thread_id" > "$thread_file"
  fi
fi

if [ -f "$thread_file" ]; then
  reviewer_thread=$(tr -d '[:space:]' < "$thread_file")
  newest_thread=''
  if [ -n "$jobs_json" ]; then
    newest_thread=$(node -e '
const jobs = JSON.parse(process.argv[1]);
const first = Array.isArray(jobs) ? jobs[0] : null;
process.stdout.write(first && first.threadId ? String(first.threadId) : "");
' "$jobs_json" 2>/dev/null || true)
  fi
  [ -n "$reviewer_thread" ] && [ "$reviewer_thread" = "$newest_thread" ] && resume=true
fi

dispatch_args=(--read-only --json --prompt-file "$prompt_file")
[ "$resume" = false ] || dispatch_args=(--resume "${dispatch_args[@]}")
job_json=$("$dispatcher" "${dispatch_args[@]}") || exit $?
job_fields=$(node -e '
const value = JSON.parse(process.argv[1]);
for (const field of ["jobId", "logFile", "waitCommand"]) {
  const text = String(value[field] ?? "");
  process.stdout.write(Buffer.from(text, "utf8").toString("base64") + "\t");
}
' "$job_json") || { printf '%s\n' 'review-round: dispatch returned invalid JSON' >&2; exit 1; }
IFS=$'\t' read -r job_id_b64 log_file_b64 wait_command_b64 _ <<< "$job_fields"
decode() { node -e 'process.stdout.write(Buffer.from(process.argv[1], "base64").toString("utf8"));' "$1"; }
job_id=$(decode "$job_id_b64")
log_file=$(decode "$log_file_b64")
wait_command=$(decode "$wait_command_b64")
[ -n "$job_id" ] || { printf '%s\n' 'review-round: dispatch returned no jobId' >&2; exit 1; }

# Persist launch state before resolving asynchronous reviewer metadata.
printf '%s\n' "$round" > "$counter"
printf '%s\n' "$job_id" > "$job_file"
rm -f "$thread_file"
job_record=$(job_record_from_log "$log_file" "$job_id")
thread_id=$(wait_for_thread_id "$job_record")
[ -z "$thread_id" ] || printf '%s\n' "$thread_id" > "$thread_file"
printf 'REVIEW ROUND: job %s\n' "$job_id"
printf 'REVIEW ROUND: log %s\n' "$log_file"
printf 'REVIEW ROUND: wait with %s\n' "$wait_command"
