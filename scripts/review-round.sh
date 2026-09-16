#!/usr/bin/env bash
# Dispatch one bounded, read-only branch-review round and persist its reviewer thread.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/review-round.sh <base> [--bead <id>] [--evidence-file <path>] [--scope-changed "<words>"] [--acceptance-reworded "<words>"] [--user-approved "<words>"] [--dry-run] [--selftest]' >&2
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
  for f in "$counter" "$thread_file" "$job_file" "$scope_file" "$state_dir/$slug"-r*-findings.md; do
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
  # Reviewers write a severity three ways, and all three are the same finding. A parser that
  # knows only the heading form silently drops every title from a bullet-style report, leaving a
  # findings file with a verdict and nothing to re-trace — measured on PR #42 round 1.
  in_final && (/^### (BLOCKER|MAJOR|MINOR|NIT)[[:space:]]/ ||
               /^(BLOCKER|MAJOR|MINOR|NIT|VERDICT|OPEN BLOCKERS):/ ||
               /^[[:space:]]*[-*][[:space:]]+\*\*(BLOCKER|MAJOR|MINOR|NIT)([[:space:]]|\*|:|—|-)/) {
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
  local recorded_stamp=''

  goal=$(resolve_acceptance)
  [ -n "$(printf '%s' "$goal" | tr -d '[:space:]')" ] || refuse_without_acceptance
  stamp=$(scope_stamp "$goal")

  # The budget is per reviewed scope. A branch that grows a feature between rounds is not on its
  # second look at the same code; it is on its first look at different code.
  previous=$(read_round)
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
  printf 'REVIEW ROUND: dry run; nothing written. Counter on disk: %s; next round would be %s\n' \
    "$(read_round)" "$round"
  exit 0
fi

prior_findings='(none — this is the first round)'
if [ "$round" -ge 2 ]; then
  # prepare_round refuses when any prior round has no findings file, so every iteration reads one.
  prior_findings=''
  for ((prior=1; prior<round; prior++)); do
    findings="$state_dir/$slug-r$prior-findings.md"
    prior_findings="$prior_findings\n--- round $prior findings: $findings ---\n$(<"$findings")\n"
  done
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
diff=$(git diff "$base"...HEAD)
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

# The plugin can only resume the NEWEST tracked thread in a workspace (openai-codex 1.0.6:
# executeTaskRun resolves its resume target solely through resolveLatestTrackedTaskThread behind
# --resume-last; runAppServerTurn takes a resumeThreadId but no CLI path passes a caller-supplied
# one). So a fix task dispatched between rounds takes the slot and this reviewer cannot be resumed.
# Measured 2026-09-16: 6 of 6 rounds on one branch ran fresh for exactly that reason. The prior
# findings file, not the thread, is the continuity mechanism — say which one happened.
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
if [ -n "$archive_pending" ]; then
  archive=$(archive_scope_state "$archive_pending")
  printf 'REVIEW ROUND: prior scope archived to %s\n' "$archive"
fi
printf '%s\n' "$round" > "$counter"
printf '%s\n' "$job_id" > "$job_file"
printf '%s\n' "$stamp" > "$scope_file"
rm -f "$thread_file"
job_record=$(job_record_from_log "$log_file" "$job_id")
thread_id=$(wait_for_thread_id "$job_record")
[ -z "$thread_id" ] || printf '%s\n' "$thread_id" > "$thread_file"
printf 'REVIEW ROUND: job %s\n' "$job_id"
printf 'REVIEW ROUND: log %s\n' "$log_file"
printf 'REVIEW ROUND: wait with %s\n' "$wait_command"
