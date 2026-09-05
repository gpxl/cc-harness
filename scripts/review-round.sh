#!/usr/bin/env bash
# Dispatch one bounded, read-only branch-review round and persist its reviewer thread.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/review-round.sh <base> [--bead <id>] [--user-approved "<words>"] [--dry-run] [--selftest]' >&2
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
base=${1:-}
[ -n "$base" ] || { usage; exit 2; }
shift
bead=''
user_approved=''
dry_run=false
selftest=false
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
if [ -f "$thread_file" ]; then
  reviewer_thread=$(tr -d '[:space:]' < "$thread_file")
  newest_thread=''
  if jobs_json=$("$jobs_tool" --cwd "$repo_root" --json 2>/dev/null); then
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
for (const field of ["jobId", "logFile", "waitCommand", "threadId"]) {
  const text = String(value[field] ?? "");
  process.stdout.write(Buffer.from(text, "utf8").toString("base64") + "\t");
}
' "$job_json") || { printf '%s\n' 'review-round: dispatch returned invalid JSON' >&2; exit 1; }
IFS=$'\t' read -r job_id_b64 log_file_b64 wait_command_b64 thread_b64 _ <<< "$job_fields"
decode() { node -e 'process.stdout.write(Buffer.from(process.argv[1], "base64").toString("utf8"));' "$1"; }
job_id=$(decode "$job_id_b64")
log_file=$(decode "$log_file_b64")
wait_command=$(decode "$wait_command_b64")
thread_id=$(decode "$thread_b64")
[ -n "$job_id" ] && [ -n "$thread_id" ] || { printf '%s\n' 'review-round: dispatch returned no jobId or reviewer threadId' >&2; exit 1; }

printf '%s\n' "$round" > "$counter"
printf '%s\n' "$thread_id" > "$thread_file"
printf 'REVIEW ROUND: job %s\n' "$job_id"
printf 'REVIEW ROUND: log %s\n' "$log_file"
printf 'REVIEW ROUND: wait with %s\n' "$wait_command"
