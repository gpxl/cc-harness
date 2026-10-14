#!/usr/bin/env bash
# Dispatch one bounded, read-only branch-review round and persist its reviewer thread.
#
# Reviewer vendor (cch-pam). The round goes to Codex while vendor 'openai' is enabled
# (hooks/vendors.sh, `vendor_enabled openai`). While it is disabled the SAME prompt, budget and
# refusals run on a headless Claude reviewer instead: `claude -p` with only Read/Grep/Glob, model
# ${REVIEW_ROUND_CLAUDE_MODEL:-claude-opus-5-5} at effort ${REVIEW_ROUND_CLAUDE_EFFORT:-medium},
# backgrounded under <git-common-dir>/review-rounds/claude-jobs/<job-id>.{prompt,log,out,err,pid,exit,json}.
# Its job ids start with `claude-`, and --collect/--adopt accept them like a Codex job id. Every
# collected findings file opens with `REVIEWER: vendor=<openai|anthropic> ...`; a Claude-authored
# round is a same-vendor review, so its acknowledgement carries `reviewer=anthropic` (an extra
# token review-ack-check.sh ignores) and must never be presented as a cross-vendor check.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/review-round.sh <base> [--bead <id>] [--evidence-file <path>] [--self-check] [--scope-changed "<words>"] [--acceptance-reworded "<words>"] [--user-approved "<words>"] [--dry-run] [--selftest]' >&2
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
evidence_file=''
scope_changed=''
acceptance_reworded=''
self_check=false

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
        --evidence-file) [ "$#" -ge 2 ] || { usage; exit 2; }; evidence_file=$2; shift 2 ;;
        --scope-changed) [ "$#" -ge 2 ] || { usage; exit 2; }; scope_changed=$2; shift 2 ;;
        --acceptance-reworded) [ "$#" -ge 2 ] || { usage; exit 2; }; acceptance_reworded=$2; shift 2 ;;
        --user-approved) [ "$#" -ge 2 ] || { usage; exit 2; }; user_approved=$2; shift 2 ;;
        --self-check) self_check=true; shift ;;
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
scope_file="$counter.scope"
thread_wait_seconds=${REVIEW_ROUND_THREAD_WAIT_SECONDS:-30}
case "$thread_wait_seconds" in
  ''|*[!0-9]*) printf '%s\n' 'review-round: REVIEW_ROUND_THREAD_WAIT_SECONDS must be an integer from 0 to 30' >&2; exit 2 ;;
esac
[ "$thread_wait_seconds" -le 30 ] || { printf '%s\n' 'review-round: REVIEW_ROUND_THREAD_WAIT_SECONDS must be at most 30' >&2; exit 2; }

archive_pending=''

dispatcher=${REVIEW_ROUND_DISPATCH:-}
if [ -z "$dispatcher" ]; then
  dispatcher=$(command -v codex-dispatch.sh 2>/dev/null || printf '%s' "$script_dir/codex-dispatch.sh")
fi
jobs_tool=${REVIEW_ROUND_JOBS:-}
if [ -z "$jobs_tool" ]; then
  jobs_tool=$(command -v codex-jobs.sh 2>/dev/null || printf '%s' "$script_dir/codex-jobs.sh")
fi

sha256_hex() {  # sha256_hex <<< text -> hex digest
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# The acceptance criteria are the branch's definition of done. A review dispatched without them
# lets the reviewer's latest finding become the definition instead, which is how a three-round
# budget turns into six (rules/branch-completion-review.md; the 2026-09-16 evaluation).
resolve_acceptance() {  # -> acceptance text on stdout, empty when none could be resolved
  local shown
  if [ -n "${REVIEW_ROUND_ACCEPTANCE:-}" ]; then
    printf '%s\n' "$REVIEW_ROUND_ACCEPTANCE"
    return 0
  fi
  [ -n "$bead" ] || return 0
  command -v bd >/dev/null 2>&1 || return 0
  shown=$(bd show "$bead" 2>/dev/null) || return 0
  # Terminate on the NEXT bd show section heading, not on any all-caps line: criteria bodies
  # legitimately contain them ("MUST NOT REGRESS"), and the old terminator silently dropped
  # everything after the first one — two-thirds of a definition of done, with no indication.
  printf '%s\n' "$shown" | awk '
    /^ACCEPTANCE CRITERIA$/ { found = 1; next }
    found && /^(DESCRIPTION|DESIGN|NOTES|ACCEPTANCE CRITERIA|PARENT|CHILDREN|DEPENDS ON|BLOCKS|RELATED|LABELS|COMMENTS|ATTACHMENTS|HISTORY)[[:space:]]*$/ { exit }
    found && NF { print }
  '
}

refuse_without_acceptance() {
  printf 'review-round: refused — no acceptance criteria resolved for this review\n' >&2
  if [ -n "$bead" ]; then
    printf 'review-round: %s has no ACCEPTANCE CRITERIA section (or bd could not read it)\n' "$bead" >&2
  else
    printf 'review-round: no --bead was supplied\n' >&2
  fi
  printf '%s\n' 'Supply them one of three ways:' >&2
  printf '%s\n' '  bd update <id> --acceptance="<what done means>"   then re-run with --bead <id>' >&2
  printf '%s\n' '  --bead <id> pointing at an item that already has them' >&2
  printf '%s\n' '  REVIEW_ROUND_ACCEPTANCE="<what done means>" scripts/review-round.sh ...' >&2
  printf '%s\n' 'A reviewer with no definition of done writes one from its own findings.' >&2
  exit 1
}

# Commits that change what is under review. fix/test/docs/chore land BECAUSE of a round; a feat or
# refactor commit makes the next round a first look at different code, which the per-branch counter
# used to charge against the old budget.
scope_subjects() {
  local subjects
  # Capture git's own status before any filter touches it: a pipeline would report grep's status,
  # and `|| true` would erase the difference between "git failed" and "no scope-changing commits"
  # (rules/verification-integrity.md). A bad base must not read as an empty scope.
  subjects=$(git log --format=%s "$base..HEAD") || {
    printf 'review-round: cannot list commits in %s..HEAD\n' "$base" >&2
    exit 2
  }
  [ -n "$subjects" ] || return 0
  printf '%s\n' "$subjects" | grep -vaE '^(fix|test|docs|chore)(\([^)]*\))?!?:' || true
}

# The stamp has two independent halves, recorded separately so a refusal can say WHICH moved.
# A combined digest can only report "something changed", and the two causes want opposite
# remedies: new feature commits mean the next round is a first look at different code and the
# budget should restart, while a reworded acceptance is the same code judged by the same
# criteria in different words and must NOT buy three more rounds.
acceptance_digest() { printf '%s\n' "$1" | sha256_hex; }
subjects_digest() { scope_subjects | sha256_hex; }

scope_stamp() {  # scope_stamp <acceptance> -> "acceptance=<hex> subjects=<hex>"
  printf 'acceptance=%s subjects=%s\n' "$(acceptance_digest "$1")" "$(subjects_digest)"
}

stamp_field() {  # stamp_field <stamp> <acceptance|subjects> -> that half, empty when absent
  printf '%s' "$1" | sed -nE "s/.*(^|[[:space:]])$2=([0-9a-f]+).*/\2/p"
}

legacy_scope_stamp() {  # legacy_scope_stamp <acceptance> -> the pre-split combined digest
  # Branches that were mid-review when the halves were split still carry a bare digest. Recomputing
  # the old formula tells an unchanged scope from a genuinely changed one, so an in-flight branch
  # does not lose its counter and its findings to a format migration.
  { printf '%s\n' "$1"; printf -- '---\n'; scope_subjects; } | sha256_hex
}

archive_scope_state() {  # archive_scope_state <old-stamp> -> archive directory
  local base_dir archive n=1 f
  # Keyed by a digest of the whole stamp, not a prefix of it: the stamp's own first characters are
  # the constant literal "acceptance=", which would give every scope on a branch the same directory.
  base_dir="$counter.scope-$(printf '%s' "$1" | sha256_hex | cut -c1-12)"
  archive="$base_dir"
  # A branch can return to a scope it reviewed before (revert, then re-land), which would key a
  # second archive to the same stamp. Both documents promise "archived, not deleted", so never
  # reuse a directory that already holds rounds.
  while [ -e "$archive" ]; do
    n=$((n + 1))
    archive="$base_dir-$n"
  done
  mkdir -p "$archive"
  # The self-check's record archives with the rest. Its file is named -r0-self-review.md, which the
  # findings glob does not match, so leaving it out left the PREVIOUS scope's self-review to be
  # inlined into the new scope's round 1 — a pass over a diff that no longer exists, presented to
  # the reviewer as the author's coverage of this one (round 1 of this branch, MAJOR 2).
  for f in "$counter" "$thread_file" "$job_file" "$scope_file" "$counter.self-check.job" \
           "$counter.r0-collected.job" "$state_dir/$slug-r0-self-review.md" \
           "$state_dir/$slug"-r*-findings.md; do
    [ -e "$f" ] || continue
    # A half-archive leaves stale findings the next round would read as this scope's, so a failed
    # move is fatal rather than skipped.
    mv "$f" "$archive/" || {
      printf 'review-round: could not archive %s into %s\n' "$f" "$archive" >&2
      exit 1
    }
  done
  printf '%s\n' "$archive"
}

working_tree_hash() {  # -> short hash of the working tree, tracked and untracked-not-ignored
  # Built in a throwaway index so the real index and the stash are never touched; this is the
  # `stamp` helper from rules/pipeline-contract.md, which is what wrote the tree= being compared.
  (
    export GIT_INDEX_FILE
    GIT_INDEX_FILE=$(mktemp -u) || exit 1
    git read-tree HEAD >/dev/null 2>&1 || exit 1
    git add -A >/dev/null 2>&1 || exit 1
    git rev-parse --short "$(git write-tree)" 2>/dev/null || exit 1
    rm -f "$GIT_INDEX_FILE"
  )
}

evidence_records() {  # -> recorded gate lines, each marked fresh or stale against this tree
  [ -n "$evidence_file" ] || return 0
  [ -f "$evidence_file" ] || {
    printf 'review-round: --evidence-file %s does not exist\n' "$evidence_file" >&2
    exit 2
  }
  local records current line recorded
  records=$(grep -aE '^(VERIFY RESULT:|CODE QUALITY RESULT:)' "$evidence_file") || return 0
  [ -n "$records" ] || return 0
  current=$(working_tree_hash)
  # A record names the tree it was measured on. Carried without that comparison, a green from
  # before the last edit reads to the reviewer as current gate evidence — an instrument that
  # cannot tell fresh from stale reporting healthy (rules/verification-integrity.md).
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    recorded=$(printf '%s' "$line" | sed -nE 's/.*(^|[[:space:]])tree=([0-9a-f]+).*/\2/p')
    if [ -z "$current" ]; then
      printf '%s   [UNVERIFIABLE: this worktree could not be hashed, so freshness is unknown]\n' "$line"
    elif [ -z "$recorded" ]; then
      printf '%s   [UNVERIFIABLE: no tree= in this record, so it cannot be tied to a tree]\n' "$line"
    elif [ "$recorded" = "$current" ]; then
      printf '%s   [fresh: measured on this exact worktree]\n' "$line"
    else
      printf '%s   [STALE: measured on tree %s, this worktree is %s — treat it as no evidence]\n' \
        "$line" "$recorded" "$current"
    fi
  done <<EOF
$records
EOF
}

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

claude_jobs_dir="$state_dir/claude-jobs"

is_claude_job() {  # is_claude_job <job-id>: a job this script launched on the Claude reviewer path
  case "$1" in
    claude-*[!A-Za-z0-9-]*) return 1 ;;
    claude-?*) return 0 ;;
    *) return 1 ;;
  esac
}

claude_job_field() {  # claude_job_field <job-id> <field> -> a string field of its JSON record
  sed -nE "s/.*\"$2\":\"([^\"]*)\".*/\1/p" "$claude_jobs_dir/$1.json" 2>/dev/null | head -n 1
}

# A Claude job is collectable only once its worker recorded exit 0 with output. Anything else is
# named — still running, failed, or orphaned — never read as an empty review
# (rules/codex-job-status-integrity.md applies to this worker as much as to a Codex one).
require_claude_job_finished() {
  local job_id=$1 exit_file="$claude_jobs_dir/$1.exit" log="$claude_jobs_dir/$1.log" pid status stream
  if [ ! -f "$exit_file" ]; then
    pid=$(tr -d '[:space:]' < "$claude_jobs_dir/$job_id.pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf 'review-round: Claude reviewer %s is still running (pid %s); collect it after it exits\n' "$job_id" "$pid" >&2
    else
      printf 'review-round: Claude reviewer %s has no recorded exit status and its worker is gone — orphaned; read %s before re-dispatching\n' "$job_id" "$log" >&2
    fi
    exit 1
  fi
  status=$(tr -d '[:space:]' < "$exit_file")
  if [ "$status" != 0 ]; then
    printf 'review-round: Claude reviewer %s exited %s — there are no findings to collect; see %s\n' "$job_id" "$status" "$log" >&2
    # The CLI reports its own failures (context thrash, auth, budget) on stdout as often as on
    # stderr, so show the tail of both: the failure must be diagnosable from this message alone.
    for stream in out err; do
      [ -s "$claude_jobs_dir/$job_id.$stream" ] || continue
      printf 'review-round: last lines of the reviewer'"'"'s std%s:\n' "$stream" >&2
      tail -n 15 "$claude_jobs_dir/$job_id.$stream" | sed 's/^/  | /' >&2
    done
    printf '%s\n' 'review-round: a failed Claude reviewer is not charged against the round budget; re-run the same command to re-dispatch this round' >&2
    exit 1
  fi
}

job_record_for_workspace() {
  local job_id=$1 plugin_root
  if is_claude_job "$job_id"; then
    printf '%s' "$claude_jobs_dir/$job_id.json"
    return 0
  fi
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
  function append(line) { sub(/[[:space:]]+$/, "", line); body[++lines] = line }
  function flush_field() { if (field != "") { append(field); field = "" } }
  # A one-line map ("COVERAGE: traced=...; not-traced=...") carries the same two fields as the
  # three-line form, and a reviewer writes whichever it feels like. Split it rather than keeping a
  # header the next round cannot read a gap out of.
  function split_inline(text,   idx, head) {
    idx = index(text, "not-traced=")
    if (idx > 0) {
      head = substr(text, 1, idx - 1)
      sub(/[[:space:];,]+$/, "", head)
      if (head != "") append(head)
      field = substr(text, idx)
    } else {
      field = text
    }
  }
  function normalize(line,   out) { out = line; sub(/^[[:space:]]+/, "", out); gsub(/\*/, "", out); sub(/[[:space:]]+$/, "", out); return out }
  # A job can log the report as an Assistant message before its Final output, or log more
  # than one Final output. Keep only the last final section so neither copy is repeated.
  # Bracketed severity labels belong to the report; only ISO-stamped job lines frame it.
  /^[[:space:]]*Final output:?[[:space:]]*$/ || /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[^]]*\][[:space:]]+Final output:?[[:space:]]*$/ {
    for (i = 1; i <= lines; i++) delete body[i]
    lines = 0
    field = ""
    coverage = 0
    coverage_blank = 0
    in_final = 1
    saw_final = 1
    next
  }
  in_final && /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[^]]*\][[:space:]]/ { flush_field(); in_final = 0; coverage = 0; next }
  # The coverage map is what makes round N+1 spend its budget on what nobody read yet, instead of
  # resampling the same third of the diff. It is extracted with the findings for the same reason
  # they are: the thread does not survive to the next round, the file does. It is parsed
  # forgivingly — leading spaces, bold markers, the one-line form, a blank line inside the block,
  # a wrapped field — because a map the reviewer DID write and this parser dropped becomes "no gap
  # was recorded" in the next prompt, which is the exact instrument failure this feature exists to
  # remove (round 1 of this branch reproduced it).
  in_final && /^[[:space:]]*\**COVERAGE:/ {
    flush_field()
    coverage = 1
    coverage_blank = 0
    rest = normalize($0)
    sub(/^COVERAGE:[[:space:]]*/, "", rest)
    append("COVERAGE:")
    if (rest != "") split_inline(rest)
    next
  }
  coverage && /^[[:space:]]*\**(traced|not-traced)[[:space:]]*=/ {
    flush_field()
    coverage_blank = 0
    field = normalize($0)
    next
  }
  # Blank lines can separate coverage fields. After a field, a blank before other prose ends
  # its wrapping so an indented finding cannot be absorbed into the coverage map.
  coverage && /^[[:space:]]*$/ { coverage_blank = 1; next }
  coverage && field != "" && !coverage_blank && /^[[:space:]]+/ { field = field " " normalize($0); next }
  coverage {
    flush_field()
    coverage = 0
    if (coverage_blank) append("")
    coverage_blank = 0
  }
  # Severity formatting is reviewer prose, not a parser contract. Preserve every body line.
  in_final { append($0) }
  END {
    flush_field()
    if (!saw_final) exit 1
    for (i = 1; i <= lines; i++) print body[i]
  }
' "$log_file"
}

collect_findings() {
  local job_id=$1 requested_round=$2 round record log_file findings temp findings_lines reviewer_line
  if [ -n "$requested_round" ]; then
    round=$requested_round
  else
    round=$(read_round)
  fi
  # Round 0 is the pre-review self-check, not a review round: it has its own file name and never
  # touches the counter, so collecting it cannot make the branch look like it has been reviewed.
  case "$round" in ''|*[!0-9]*) printf '%s\n' 'review-round: --collect needs a numeric --round or an existing round counter' >&2; exit 2 ;; esac
  if [ "$round" = 0 ] && [ -z "$requested_round" ]; then
    printf '%s\n' 'review-round: --collect --round 0 must be asked for explicitly (it records the self-check, not a round)' >&2
    exit 2
  fi
  record=$(job_record_for_workspace "$job_id") || { printf '%s\n' "review-round: could not resolve job record for $job_id" >&2; exit 1; }
  [ -f "$record" ] || { printf '%s\n' "review-round: job record not found for $job_id" >&2; exit 1; }
  log_file=$(log_from_job_record "$record") || { printf '%s\n' "review-round: job record has no logFile for $job_id" >&2; exit 1; }
  [ -f "$log_file" ] || { printf '%s\n' "review-round: job log not found for $job_id" >&2; exit 1; }
  if is_claude_job "$job_id"; then
    reviewer_line="REVIEWER: vendor=anthropic model=$(claude_job_field "$job_id" model) job=$job_id — same-vendor review, NOT a cross-vendor check; record reviewer=anthropic in the REVIEW ACK line"
  else
    reviewer_line="REVIEWER: vendor=openai job=$job_id"
  fi
  mkdir -p "$state_dir"
  if [ "$round" = 0 ]; then
    findings="$state_dir/$slug-r0-self-review.md"
  else
    findings="$state_dir/$slug-r$round-findings.md"
  fi
  if [ -e "$findings" ]; then
    # For a round, the counter bounds this: round N is collected once. Round 0 has no counter, so a
    # second self-check would collect the FIRST pass's file and exit 0 — handing round 1 a
    # pre-fix self-review while hiding what the second pass found (round 1 of this branch, MAJOR 3).
    if [ "$round" = 0 ] && [ "$(cat "$counter.r0-collected.job" 2>/dev/null || true)" != "$job_id" ]; then
      printf 'review-round: refused — %s already holds an earlier self-check\n' "$findings" >&2
      printf '%s\n' 'A later self-check cannot overwrite it silently. Remove or rename that file to record this one.' >&2
      exit 1
    fi
    printf '%s\n' "$findings"
    return 0
  fi
  ! is_claude_job "$job_id" || require_claude_job_finished "$job_id"
  findings_lines=$(final_findings_from_log "$log_file") || { printf '%s\n' "review-round: Final output section not found in $log_file" >&2; exit 1; }
  temp=$(mktemp "$state_dir/.${slug}-r${round}-findings.XXXXXX") || exit 1
  # Which vendor reviewed is part of the record: a Claude round reviewing Claude-authored work is
  # not the independent second opinion a Codex round is, and the findings file is what the
  # acknowledgement is written from.
  printf '%s\n' "$reviewer_line" > "$temp"
  [ -z "$findings_lines" ] || printf '%s\n' "$findings_lines" >> "$temp"

  # A missing coverage map is stated, never silently absent: the next round must be able to tell
  # "nothing was skipped" from "nobody said what was skipped" (rules/verification-integrity.md).
  # The test is the not-traced FIELD, not the COVERAGE header: a header with no field is exactly
  # the shape a partial map has, and keying on the header let one read as a complete map.
  if ! grep -qi '^not-traced[[:space:]]*=' "$temp"; then
    if grep -q '^COVERAGE:' "$temp"; then
      printf '%s\n' 'COVERAGE: (incomplete — a coverage map was recorded with no not-traced field, so its gaps are unknown)' >> "$temp"
    else
      printf '%s\n' 'COVERAGE: (none recorded — this round'"'"'s report carried no coverage map, so its gaps are unknown)' >> "$temp"
    fi
  fi
  printf '%s\n' 'Dispositions:' >> "$temp"
  mv "$temp" "$findings"
  # Which job produced the self-review, so a re-collect of the SAME job is idempotent while a
  # second, later self-check is refused rather than silently discarded.
  [ "$round" != 0 ] || printf '%s\n' "$job_id" > "$counter.r0-collected.job"
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
  if is_claude_job "$job_id"; then
    thread_id=''  # a headless Claude reviewer has no resumable thread; the findings file carries continuity
  else
    [ -n "$thread_id" ] || { printf '%s\n' "review-round: job record has no threadId for $job_id" >&2; exit 1; }
  fi
  mkdir -p "$state_dir"
  # Persist recovered reviewer state.
  printf '%s\n' "$round" > "$counter"
  printf '%s\n' "$job_id" > "$job_file"
  if [ -n "$thread_id" ]; then printf '%s\n' "$thread_id" > "$thread_file"; else rm -f "$thread_file"; fi
  printf 'REVIEW ROUND: adopted round %s job %s\n' "$round" "$job_id"
}

case "$mode" in
  collect) collect_findings "$collect_job" "$collect_round"; exit 0 ;;
  adopt) adopt_round "$adopt_round" "$adopt_job"; exit 0 ;;
esac

# Which vendor reviews this round. A disabled vendor is not a route (global CLAUDE.md § Vendor
# switch), so with openai off the round runs on Claude rather than dying on codex.sh's refusal.
# An unreadable switch fails closed to the Claude path, exactly as codex.sh refuses on it.
reviewer_vendor=anthropic
vendors_sh=${CC_HARNESS_VENDORS_SH:-$script_dir/../hooks/vendors.sh}
if [ -r "$vendors_sh" ] && . "$vendors_sh" && vendor_enabled openai; then
  reviewer_vendor=openai
fi
claude_model=${REVIEW_ROUND_CLAUDE_MODEL:-claude-opus-5-5}
claude_effort=${REVIEW_ROUND_CLAUDE_EFFORT:-medium}
claude_bin=${REVIEW_ROUND_CLAUDE_BIN:-claude}
if [ "$reviewer_vendor" = openai ]; then
  reviewer_summary='vendor=openai (Codex, read-only)'
else
  reviewer_summary="vendor=anthropic model=$claude_model effort=$claude_effort (openai is disabled by the vendor switch; same-vendor review, not cross-vendor)"
fi

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
  local recorded_stamp=''

  goal=$(resolve_acceptance)
  [ -n "$(printf '%s' "$goal" | tr -d '[:space:]')" ] || refuse_without_acceptance
  stamp=$(scope_stamp "$goal")

  # The self-check runs BEFORE round 1 and spends none of the budget: it is the author asking the
  # five-class attack surface of their own diff, so that round 1 is not spent on defects the author
  # could have found. Measured 2026-09-16: two first rounds on different repos returned four and
  # five MAJORs, every one of them the author's own "this check cannot go red" class.
  if [ "$self_check" = true ]; then
    round=0
    # Flags that only mean something to a budgeted round are refused, not ignored: a silently
    # dropped --user-approved reads as accepted.
    local ignored=''
    [ -z "$scope_changed" ] || ignored="$ignored --scope-changed"
    [ -z "$acceptance_reworded" ] || ignored="$ignored --acceptance-reworded"
    [ -z "$user_approved" ] || ignored="$ignored --user-approved"
    if [ -n "$ignored" ]; then
      printf 'review-round: refused —%s mean nothing to a self-check; it spends no round and stamps no scope\n' "$ignored" >&2
      exit 2
    fi
    local already
    already=$(read_round)
    if [ "$already" -gt 0 ]; then
      printf 'review-round: refused — round %s has already been dispatched; the self-check runs before round 1\n' "$already" >&2
      exit 1
    fi
    goal_line=$(printf '%s' "$goal" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
    printf 'GOAL: %s | SELF-CHECK (round 0, spends no budget) | NEXT: collect with --collect <job-id> --round 0\n' "$goal_line"
    return 0
  fi

  # The budget is per reviewed scope. A branch that grows a feature between rounds is not on its
  # second look at the same code; it is on its first look at different code.
  previous=$(read_round)
  # A reviewer PROCESS failure is not a review. When the last dispatched round ran on the Claude
  # path, its worker recorded a non-zero exit, and no findings were collected for it, that round
  # produced nothing to charge: re-dispatch the same round number instead of refusing round N+1
  # over a hole the failure itself created (the 2026-10-14 context-thrash failure spent round 1).
  # A Codex job has no such recorded exit here, so its failures keep their existing handling.
  if [ "$previous" -gt 0 ] && [ -f "$job_file" ] && [ ! -f "$state_dir/$slug-r$previous-findings.md" ]; then
    local last_job last_exit
    last_job=$(tr -d '[:space:]' < "$job_file")
    if is_claude_job "$last_job" && [ -f "$claude_jobs_dir/$last_job.exit" ]; then
      last_exit=$(tr -d '[:space:]' < "$claude_jobs_dir/$last_job.exit")
      if [ "$last_exit" != 0 ]; then
        printf 'REVIEW ROUND: round %s'"'"'s Claude reviewer %s failed (exit %s) with no findings; it is not charged — re-dispatching round %s\n' \
          "$previous" "$last_job" "$last_exit" "$previous"
        previous=$((previous - 1))
      fi
    fi
  fi
  if [ -e "$scope_file" ]; then
    recorded_stamp=$(tr -d '\n' < "$scope_file")
  fi
  local recorded_acceptance='' recorded_subjects='' unattributable=false
  if [ -n "$recorded_stamp" ]; then
    recorded_acceptance=$(stamp_field "$recorded_stamp" acceptance)
    recorded_subjects=$(stamp_field "$recorded_stamp" subjects)
    if [ -z "$recorded_acceptance" ] && [ -z "$recorded_subjects" ]; then
      # A stamp written before the halves were recorded separately is a bare digest. Recompute the
      # old formula first: when it matches, the scope did not move at all and the record is simply
      # in the older format, so upgrade it in place rather than charging the branch a restart.
      if [ "$recorded_stamp" = "$(legacy_scope_stamp "$goal")" ]; then
        printf 'REVIEW ROUND: scope stamp upgraded from the pre-split format; the scope is unchanged\n'
        printf '%s\n' "$stamp" > "$scope_file"
        recorded_stamp=$stamp
        recorded_acceptance=$(stamp_field "$stamp" acceptance)
        recorded_subjects=$(stamp_field "$stamp" subjects)
      else
        # It really did move, but a combined digest cannot say which half. Say that, rather than
        # printing an attribution the record does not support.
        unattributable=true
        recorded_acceptance='(unattributable)'
        recorded_subjects='(unattributable)'
      fi
    fi
  fi
  if [ -n "$recorded_stamp" ] && [ "$recorded_stamp" != "$stamp" ] && [ "$previous" -gt 0 ]; then
    local acceptance_moved=false subjects_moved=false
    [ "$recorded_acceptance" = "$(acceptance_digest "$goal")" ] || acceptance_moved=true
    [ "$recorded_subjects" = "$(subjects_digest)" ] || subjects_moved=true

    if [ -n "$scope_changed" ]; then
      # An explicit declaration wins whichever half moved: the operator is saying the definition
      # of done really is different, which makes the next round a first look.
      archive_pending=$recorded_stamp
      printf 'REVIEW ROUND: scope changed since round %s; archiving on dispatch\n' "$previous"
      printf 'REVIEW ROUND: scope change accepted — %s\n' "$scope_changed"
      previous=0
    elif [ "$acceptance_moved" = true ] && [ "$subjects_moved" = false ] && [ -n "$acceptance_reworded" ]; then
      # Same commits, same criteria, different words. Record the new wording and keep the counter:
      # a typo fix must not buy three more rounds, which is what a single combined digest did.
      printf 'REVIEW ROUND: acceptance text reworded — %s\n' "$acceptance_reworded"
      printf 'REVIEW ROUND: the commits under review are unchanged, so the counter stays at %s\n' "$previous"
    elif [ "$acceptance_moved" = true ] && [ "$subjects_moved" = false ]; then
      printf 'review-round: refused — the acceptance text changed since round %s, but the commits did not\n' "$previous" >&2
      printf '%s\n' 'No scope-changing commit has been added, so this is the same code under review.' >&2
      printf '%s\n' 'Say which it is:' >&2
      printf '%s\n' '  --acceptance-reworded "<why>"  same criteria, different words; the counter is kept' >&2
      printf '%s\n' '  --scope-changed "<what>"       the definition of done really changed; the budget restarts' >&2
      exit 1
    else
      printf 'review-round: refused — the reviewed scope changed since round %s\n' "$previous" >&2
      if [ "$unattributable" = true ]; then
        printf '%s\n' 'What moved: unknown — the recorded stamp predates the split into an acceptance' >&2
        printf '%s\n' 'half and a commits half, so it can only say that something changed.' >&2
      elif [ "$subjects_moved" = false ] && [ "$acceptance_moved" = false ]; then
        printf '%s\n' 'What moved: neither half — the recorded stamp is not in the format this script' >&2
        printf '%s\n' 'writes, so it cannot be compared field by field.' >&2
      else
        if [ "$subjects_moved" = true ]; then
          printf '%s\n' 'What moved: the scope-changing commits below.' >&2
        fi
        if [ "$acceptance_moved" = true ]; then
          printf '%s\n' 'What moved: the acceptance text, as well as the commits.' >&2
        fi
      fi
      printf '%s\n' 'Scope-changing commits now in this branch (fix/test/docs/chore excluded):' >&2
      scope_subjects | sed 's/^/  /' >&2
      printf '%s\n' 'The round budget looks at one scope. Restate what done means for the enlarged' >&2
      printf '%s\n' 'branch, then re-run with --scope-changed "<what changed>".' >&2
      printf '%s\n' 'The counter restarts at round 1; the prior rounds are archived, not deleted.' >&2
      exit 1
    fi
  fi

  round=$((previous + 1))
  if [ "$round" -ge 4 ] && [ -z "$user_approved" ]; then
    printf 'review-round: round %s refused — user approval is required after round 3\n' "$round" >&2
    exit 1
  fi

  # Prior rounds are the only continuity a fresh reviewer gets (see the resume note in
  # docs/reference/review-round-scripts.md). Dispatching round N with a hole in that record means
  # paying for a round that re-derives what round k already found.
  if [ "$round" -ge 2 ]; then
    local prior missing=''
    for ((prior = 1; prior < round; prior++)); do
      [ -f "$state_dir/$slug-r$prior-findings.md" ] || missing="$missing $prior"
    done
    if [ -n "$missing" ]; then
      printf 'review-round: refused — no findings recorded for round(s)%s\n' "$missing" >&2
      printf '%s\n' 'Record them before dispatching the next round:' >&2
      printf '%s\n' '  scripts/review-round.sh --collect <job-id> --round <k>' >&2
      printf '%s\n' "  or write $state_dir/$slug-r<k>-findings.md by hand with each finding's disposition" >&2
      exit 1
    fi
  fi

  goal_line=$(printf '%s' "$goal" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  printf 'GOAL: %s | ROUND %s/3 | OPEN BLOCKERS ? | NEXT: wait for verdict\n' "$goal_line" "$round"
}

git rev-parse --verify --quiet "$base^{commit}" >/dev/null || {
  printf 'review-round: %s is not a commit this worktree can resolve\n' "$base" >&2
  exit 2
}

# The review covers COMMITTED work only ($base...HEAD). An empty diff is not a clean branch: it is
# usually uncommitted work, and a reviewer handed nothing goes exploring the repository instead —
# the 2026-10-14 round that thrashed its context to death had exactly this empty prompt.
diff=$(git diff "$base"...HEAD) || { printf 'review-round: cannot diff %s...HEAD\n' "$base" >&2; exit 2; }
if [ -z "$diff" ]; then
  printf 'review-round: refused — %s...HEAD is empty, so there is nothing to review\n' "$base" >&2
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    printf '%s\n' 'review-round: the working tree has uncommitted changes; reviews cover committed work only — commit first' >&2
  fi
  exit 1
fi

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
  # `previous` is zeroed by an accepted scope change, so it is what the counter WOULD become, not
  # what is on disk. An inspector whose only job is to report state without changing it must not
  # state the state wrongly.
  if [ "$self_check" = true ]; then
    printf 'REVIEW ROUND: dry run; nothing written. Counter on disk: %s; this is the self-check, which is not a round\n' \
      "$(read_round)"
  else
    printf 'REVIEW ROUND: dry run; nothing written. Counter on disk: %s; next round would be %s\n' \
      "$(read_round)" "$round"
  fi
  printf 'REVIEW ROUND: reviewer would be %s\n' "$reviewer_summary"
  exit 0
fi

# What earlier rounds said they did NOT read. Round 3 on the 6-round branch found five defects in
# files unchanged since round 2, and round 5's finding had been present since round 2: each fresh
# reviewer samples a different subset and nothing carried the gaps forward. This does.
prior_not_traced=''
collect_not_traced() {  # collect_not_traced <round> -> that round's not-traced line, if any
  local prior=$1 file="$state_dir/$slug-r$1-findings.md" fields
  [ -f "$file" ] || return 0
  # A findings file that DISCUSSES the coverage format quotes it. Round 1 of this branch quoted a
  # reviewer log inside a fence to demonstrate a parsing defect, and its invented gap was carried
  # into round 2's prompt as a real one — a fabricated target, in the mechanism built to stop
  # fabricated coverage claims. A fenced block is an example, not a record; the same distinction
  # rules/public-surface-hygiene.md draws for a review acknowledgement.
  #
  # The presence test and the extraction read the file the SAME way on purpose: keyed differently,
  # a file whose only map is quoted would test as mapped and then carry nothing forward, which is
  # the reassuring "nothing was skipped" wording for a file that recorded nothing.
  fields=$(awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    !fence && tolower($0) ~ /^[[:space:]]*not-traced[[:space:]]*=/ { sub(/^[[:space:]]*/, ""); print }
  ' "$file" 2>/dev/null) || true
  # Any prior file WITHOUT a not-traced field is an unknown gap, however it got that way: a report
  # with no map, a partial map, or a findings file written by hand (which the refusal message above
  # invites, and which no --collect ever touched). Keying on the sentinel alone left that last path
  # reading as the reassuring "nothing was skipped" (round 1 of this branch, MINOR 3).
  if [ -z "$fields" ]; then
    printf 'round %s: no coverage map was recorded, so its gaps are unknown — treat the whole diff as untraced by it\n' "$prior"
    return 0
  fi
  printf '%s\n' "$fields" | sed "s/^/round $prior: /"
}

prior_findings='(none — this is the first round)'
if [ "$round" -ge 2 ]; then
  # prepare_round refuses when any prior round has no findings file, so every iteration reads one.
  prior_findings=''
  for ((prior=1; prior<round; prior++)); do
    findings="$state_dir/$slug-r$prior-findings.md"
    prior_findings="$prior_findings\n--- round $prior findings: $findings ---\n$(<"$findings")\n"
    prior_not_traced="$prior_not_traced$(collect_not_traced "$prior" || true)
"
  done
fi
if [ "$round" -ge 2 ]; then
  if [ -n "$(printf '%s' "$prior_not_traced" | tr -d '[:space:]')" ]; then
    coverage_targets="What earlier rounds recorded as NOT traced — after re-tracing the prior findings, spend the
rest of this review here before anything else:
$prior_not_traced"
  else
    coverage_targets='No earlier round recorded anything as not-traced. That is not the same as full coverage:
treat the parts of the diff no prior finding touched as unread, and say what you skipped.'
  fi
else
  coverage_targets='This is the first round; nothing has been traced yet.'
fi

# Calibration. rules/branch-completion-review.md § Stage 2 makes this R2+ ("From R2 omit the
# prompting skill's dig_deeper_nudge") and requires the anti-manufacture sentence VERBATIM. Neither
# was ever sent: the prompt carried a bare classify-and-ship line on every round, so every reviewer
# got the dig-deeper posture and none got the sentence restraining it. Measured 2026-09-17 over the
# four branches reviewed under that contract: 37 of 59 findings (62%) were MINOR/NIT, and every open
# backlog item was review-spawned.
#
# R1 keeps the dig-deeper posture deliberately — the first look at a diff is where breadth pays. It
# is R2+, re-reading code it has already judged, that has to be told not to reach.
if [ "$round" -ge 2 ]; then
  calibration='Classify each finding DECISION-CHANGING or POLISH; report DECISION-CHANGING first.
If you believe this branch is good enough to ship, say so plainly and early.
Do not manufacture severity to seem rigorous.'
else
  calibration='Classify each finding DECISION-CHANGING or POLISH; report DECISION-CHANGING first.
If ready to ship, say GO plainly and early.'
fi

# The author's own pass, when there was one. Round 1 reads it so the reviewer targets what the
# self-check did NOT cover instead of re-finding what it did.
self_review_file="$state_dir/$slug-r0-self-review.md"
# The archive runs AFTER dispatch (nothing is moved until the round actually launches), so a
# pending scope change means this file belongs to the scope being retired — it must not be read
# into the prompt for the scope replacing it.
[ -z "$archive_pending" ] || self_review_file=''
if [ -n "$self_review_file" ] && [ -f "$self_review_file" ]; then
  self_review_section="Author self-review and dispositions (round 0, the author's own adversarial pass — re-check
these claims rather than repeating them, and treat what it did not cover as your first target):
$(<"$self_review_file")"
else
  self_review_section='No author self-check was recorded for this branch (scripts/review-round.sh <base> --self-check).
Nothing here tells you which defects the author already hunted, so assume none were.'
fi

records=$(evidence_records)
if [ -n "$records" ]; then
  evidence_section="$records"
else
  evidence_section='No deterministic gate record was supplied with this review. Nothing here tells you
whether lint, tests or the build passed on this tree — treat every such claim in the diff or the
commit messages as unverified, and weight your attention toward what no gate could have covered.'
fi

prompt_file=$(mktemp "${TMPDIR:-/tmp}/review-round-prompt.XXXXXX") || exit 1
# The Claude reviewer reads the diff from a file in bounded chunks instead of carrying it inline:
# its context also has to hold every file it opens, and a large inline diff plus a few whole-file
# reads is how a round exhausts the window. Codex keeps the inline diff it was calibrated on.
diff_section=$diff
if [ "$reviewer_vendor" = anthropic ]; then
  mkdir -p "$claude_jobs_dir"
  job_id="claude-$(date -u +%Y%m%d%H%M%S)-$$-${RANDOM}"
  job_base="$claude_jobs_dir/$job_id"
  printf '%s\n' "$diff" > "$job_base.diff"
  diff_lines=$(wc -l < "$job_base.diff" | tr -d '[:space:]')
  diff_section="The unified diff is NOT inlined. It is in $job_base.diff ($diff_lines lines).
Read it with the Read tool in chunks of at most 300 lines (offset/limit), front to back."
fi
if [ "$self_check" = true ]; then
cat > "$prompt_file" <<EOF
This is a read-only PRE-REVIEW SELF-CHECK on the author's own branch. No round of the review budget
is being spent. You are not the adversary; you are the author asking the adversary's questions first,
so that round 1 is not spent on defects the author could have found.

Acceptance criteria — the branch's definition of done, and the boundary of this pass. Label anything
outside it OUT-OF-SCOPE:
$goal

Recorded deterministic evidence (a record marked STALE was measured on different content):
$evidence_section

Diff against $base...HEAD:
$diff_section

Work the five risk classes over this diff, and say per class what you looked for and what you found:
1. lifetime, ordering, cancellation, concurrency — listener and task lifetimes, teardown order,
   cancellation inheritance, anything that can interleave.
2. persistence, serialisation, data format — what is written, read back, versioned, migrated, and
   any path that SHOULD persist but does not.
3. integrity of a check or the policy behind it — for every check this branch adds or changes, could
   it actually go red? Name the mutation that would prove it, and say whether it was run.
4. trusted external surface — invariants that hold only while a service, config or content behaves.
5. real-time or hardware-adjacent code.

Then list, in severity order, every finding you would expect an adversary to raise against this
branch — including the ones you think are defensible, with the defence.

Then a coverage map, on its own lines:
COVERAGE:
traced=<the files and mechanisms you actually read and reasoned about>
not-traced=<what you skipped, and why>

End with exactly: VERDICT: GO or VERDICT: NO-GO, and list OPEN BLOCKERS: <number>. A self-check that
finds nothing says so plainly; manufactured findings cost the same round they were meant to save.
EOF
else
cat > "$prompt_file" <<EOF
This is a bounded, read-only branch-completion review, round $round of 3.

Purpose: find decision-changing defects in the full branch diff; do not edit files or manufacture findings.

Acceptance criteria — this is the branch's definition of done, and the boundary of this review.
Label anything outside it OUT-OF-SCOPE rather than raising it as a blocker:
$goal

Recorded deterministic evidence (each record is marked against the worktree you are reviewing;
a record marked STALE was measured on different content and is not evidence about this one):
$evidence_section

Diff against $base...HEAD:
$diff_section

$self_review_section

Prior-round findings and dispositions (re-trace these first when present):
$prior_findings

$coverage_targets

Report BLOCKER/MAJOR/MINOR/NIT findings with file:line, failure scenario, and required action.
$calibration

Report at most 3 POLISH findings, chosen for highest value. If you have more, give the count and
stop — an unbounded polish list becomes backlog nobody reads. DECISION-CHANGING findings are not
capped: report every one you can support.

Then a coverage map, in exactly this shape, on its own lines — it is how the next round knows where
to look, and "I read everything" is only believable if you can name it:
COVERAGE:
traced=<the files and mechanisms you actually read and reasoned about>
not-traced=<what you skipped, and why: budget, out of scope, or unreachable from the diff>

End with exactly: VERDICT: GO or VERDICT: NO-GO, and list OPEN BLOCKERS: <number>.
EOF
fi

if [ "$reviewer_vendor" = anthropic ]; then
cat >> "$prompt_file" <<EOF

Reading budget (your context window is finite and a review that exhausts it reports nothing):
- Never Read a whole file longer than 300 lines. Use Grep to locate what you need, then Read with
  offset/limit of at most 300 lines around it.
- Read the diff file in chunks of at most 300 lines; do not re-read chunks you have already read.
- Prefer the diff to the full file: open surrounding code only to confirm a specific suspicion.
- If you run short of budget, stop reading and report what you have, listing the rest under
  not-traced=.
Output: keep it compact — one entry per finding (severity, file:line, failure scenario, required
action; at most 4 lines each), then the COVERAGE map and the VERDICT lines. No preamble, no
restating of the diff.
EOF
fi

resume=false
jobs_json=''
if [ "$reviewer_vendor" = openai ] && jobs_json=$("$jobs_tool" --cwd "$repo_root" --json 2>/dev/null); then
  :
else
  jobs_json=''
fi

if [ "$reviewer_vendor" = openai ] && [ ! -f "$thread_file" ] && [ -f "$job_file" ] && [ -n "$jobs_json" ]; then
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

# The plugin can only resume the NEWEST tracked thread in a workspace (openai-codex 1.0.6:
# executeTaskRun resolves its resume target solely through resolveLatestTrackedTaskThread behind
# --resume-last; runAppServerTurn takes a resumeThreadId but no CLI path passes a caller-supplied
# one). So a fix task dispatched between rounds takes the slot and this reviewer cannot be resumed.
# Measured 2026-09-16: 6 of 6 rounds on one branch ran fresh for exactly that reason. The prior
# findings file, not the thread, is the continuity mechanism — say which one happened.
if [ "$reviewer_vendor" = anthropic ]; then
  [ "$round" -lt 2 ] || printf '%s\n' 'REVIEW ROUND: fresh reviewer — the Claude reviewer has no resumable thread; prior findings carry the continuity'
elif [ -f "$thread_file" ]; then
  reviewer_thread=$(tr -d '[:space:]' < "$thread_file")
  newest_thread=''
  if [ -n "$jobs_json" ]; then
    newest_thread=$(node -e '
const jobs = JSON.parse(process.argv[1]);
const first = Array.isArray(jobs) ? jobs[0] : null;
process.stdout.write(first && first.threadId ? String(first.threadId) : "");
' "$jobs_json" 2>/dev/null || true)
  fi
  if [ -n "$reviewer_thread" ] && [ "$reviewer_thread" = "$newest_thread" ]; then
    resume=true
  elif [ "$round" -ge 2 ]; then
    printf 'REVIEW ROUND: fresh reviewer — thread %s is no longer the newest tracked thread%s\n' \
      "$reviewer_thread" "${newest_thread:+ (that is $newest_thread)}"
    printf '%s\n' 'REVIEW ROUND: the plugin resumes only the newest thread; prior findings carry the continuity'
  fi
elif [ "$round" -ge 2 ]; then
  printf '%s\n' 'REVIEW ROUND: fresh reviewer — no reviewer thread was recorded for the prior round'
fi

# The Claude reviewer: the same prompt, read-only tools, backgrounded so a long review survives the
# caller's Bash timeout. Its log carries a `Final output:` section in the shape --collect already
# parses, written only once the CLI exits 0 with output, and the exit status lands in <id>.exit
# atomically — so "still running", "failed" and "orphaned" stay distinguishable.
launch_claude_review() {  # sets job_id, log_file, wait_command
  local worker_pid  # job_id and job_base were allocated with the diff file, before the prompt
  cp "$prompt_file" "$job_base.prompt"
  log_file="$job_base.log"
  : > "$log_file"
  nohup bash -c '
    bin=$1 model=$2 effort=$3 base=$4 workdir=$5 budget=$6
    set -- --model "$model" --effort "$effort"
    [ -z "$budget" ] || set -- "$@" --max-budget-usd "$budget"
    now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    printf "[%s] Claude reviewer started: model=%s effort=%s tools=Read,Grep,Glob\n" "$(now)" "$model" "$effort" >> "$base.log"
    cd "$workdir" || exit 1
    "$bin" -p "$@" --tools Read,Grep,Glob --allowed-tools Read,Grep,Glob \
      --permission-mode dontAsk --no-session-persistence --output-format text \
      < "$base.prompt" > "$base.out" 2> "$base.err"
    rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$base.out" ]; then
      printf "[%s] Claude reviewer exited 0 with no output; recorded as a failure\n" "$(now)" >> "$base.log"
      rc=1
    else
      printf "[%s] Claude reviewer exited %s\n" "$(now)" "$rc" >> "$base.log"
    fi
    if [ "$rc" -eq 0 ]; then
      printf "Final output:\n" >> "$base.log"
      cat "$base.out" >> "$base.log"
    else
      cat "$base.out" "$base.err" >> "$base.log" 2>/dev/null
    fi
    printf "%s\n" "$rc" > "$base.exit.tmp" && mv "$base.exit.tmp" "$base.exit"
  ' review-round-claude "$claude_bin" "$claude_model" "$claude_effort" "$job_base" "$repo_root" \
    "${REVIEW_ROUND_CLAUDE_MAX_BUDGET_USD:-}" \
    < /dev/null > /dev/null 2>&1 &
  worker_pid=$!
  printf '%s\n' "$worker_pid" > "$job_base.pid"
  printf '{"id":"%s","vendor":"anthropic","model":"%s","effort":"%s","pid":%s,"logFile":"%s","exitFile":"%s"}\n' \
    "$job_id" "$claude_model" "$claude_effort" "$worker_pid" "$log_file" "$job_base.exit" > "$job_base.json"
  wait_command="while kill -0 $worker_pid 2>/dev/null; do sleep 15; done; cat $job_base.exit"
}

if [ "$reviewer_vendor" = anthropic ]; then
  launch_claude_review
else
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
fi
[ -n "$job_id" ] || { printf '%s\n' 'review-round: dispatch returned no jobId' >&2; exit 1; }

# Persist launch state before resolving asynchronous reviewer metadata. The self-check writes
# NONE of it: it spends no round, so it must not move the counter, claim the reviewer thread, or
# stamp the scope — a branch that has only self-checked has not been reviewed.
if [ "$self_check" = true ]; then
  printf '%s\n' "$job_id" > "$counter.self-check.job"
else
  if [ -n "$archive_pending" ]; then
    archive=$(archive_scope_state "$archive_pending")
    printf 'REVIEW ROUND: prior scope archived to %s\n' "$archive"
  fi
  printf '%s\n' "$round" > "$counter"
  printf '%s\n' "$job_id" > "$job_file"
  printf '%s\n' "$stamp" > "$scope_file"
  rm -f "$thread_file"
fi
if [ "$self_check" = false ] && [ "$reviewer_vendor" = openai ]; then
  job_record=$(job_record_from_log "$log_file" "$job_id")
  thread_id=$(wait_for_thread_id "$job_record")
  [ -z "$thread_id" ] || printf '%s\n' "$thread_id" > "$thread_file"
fi
printf 'REVIEW ROUND: reviewer %s\n' "$reviewer_summary"
printf 'REVIEW ROUND: job %s\n' "$job_id"
printf 'REVIEW ROUND: log %s\n' "$log_file"
printf 'REVIEW ROUND: wait with %s\n' "$wait_command"
