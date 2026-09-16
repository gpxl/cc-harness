#!/usr/bin/env bash
# Hermetic regression test for review-round.sh; the fake dispatcher never reaches Codex.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tool="$root/scripts/review-round.sh"
sample_log="$root/scripts/testdata/review-job-sample.log"
runner="$tool"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/review-round-selftest.XXXXXX") || exit 1
completed=0
trap 'status=$?; rm -rf "$tmp"; [ "$completed" = 1 ] || status=1; exit "$status"' EXIT HUP INT TERM
failures=0
pass() { printf '%s: PASS\n' "$1"; }
fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }

repo="$tmp/repo"
mkdir -p "$repo" "$tmp/bin"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name selftest
printf 'base\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm base
base=$(git -C "$repo" rev-parse HEAD)
printf 'changed\n' > "$repo/file.txt"
git -C "$repo" commit -am changed -q
common=$(git -C "$repo" rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$repo/$common" ;; esac
slug=$(git -C "$repo" symbolic-ref --short HEAD | sed 's/[^[:alnum:]._-]/-/g')
state="$common/review-rounds/$slug"
job_dir="$tmp/codex-state/workspace/jobs"
job_log="$job_dir/review-job.log"
job_record="$job_dir/review-job.json"
mkdir -p "$job_dir"

write_job_record() {
  printf '{"id":"review-job","threadId":"reviewer-thread","logFile":"%s"}\n' "$job_log" > "$job_record"
}

write_job_log() {
  cp "$sample_log" "$job_log"
}

cat > "$tmp/bin/codex-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$RR_TMP/dispatch-argv"
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--prompt-file' ]; then
    cp "$2" "$RR_TMP/dispatched-prompt"
    break
  fi
  shift
done
printf '{"jobId":"review-job","logFile":"%s","waitCommand":"scripts/codex-wait.sh review-job --cwd /repo"}\n' "$RR_JOB_LOG"
EOF
cat > "$tmp/bin/codex-jobs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '[{"id":"review-job","threadId":"%s","logFile":"%s","updatedAt":"2026-01-01T00:00:00Z"}]\n' \
  "${RR_NEWEST_THREAD:-}" "$RR_JOB_LOG"
EOF
chmod +x "$tmp/bin/codex-dispatch.sh" "$tmp/bin/codex-jobs.sh"

run() {
  set +e
  (cd "$repo" && PATH="$tmp/bin:$PATH" RR_TMP="$tmp" RR_JOB_LOG="$job_log" RR_NEWEST_THREAD="${RR_NEWEST_THREAD:-}" REVIEW_ROUND_JOB_RECORD="$job_record" REVIEW_ROUND_THREAD_WAIT_SECONDS="${RR_THREAD_WAIT_SECONDS:-30}" REVIEW_ROUND_ACCEPTANCE="${RR_ACCEPTANCE-Ship the bounded review changes.}" bash "$runner" "$base" "$@") > "$tmp/out" 2> "$tmp/err"
  rc=$?
  set -e
  output=$(<"$tmp/out")
}

run_subcommand() {
  set +e
  (cd "$repo" && PATH="$tmp/bin:$PATH" RR_TMP="$tmp" RR_JOB_LOG="$job_log" RR_NEWEST_THREAD="${RR_NEWEST_THREAD:-}" REVIEW_ROUND_JOB_RECORD="$job_record" REVIEW_ROUND_THREAD_WAIT_SECONDS="${RR_THREAD_WAIT_SECONDS:-30}" REVIEW_ROUND_ACCEPTANCE="${RR_ACCEPTANCE-Ship the bounded review changes.}" bash "$runner" "$@") > "$tmp/out" 2> "$tmp/err"
  rc=$?
  set -e
  output=$(<"$tmp/out")
}

reset_state() {
  rm -rf "$(dirname "$state")"
  rm -f "$tmp/dispatch-argv" "$tmp/dispatched-prompt"
  write_job_record
  write_job_log
}

seed_prior_findings() {  # seed_prior_findings <highest-round>
  local k
  mkdir -p "$(dirname "$state")"
  for ((k = 1; k <= $1; k++)); do
    printf '%s\n' "MAJOR: seeded r$k finding" 'VERDICT: NO-GO' 'Dispositions: fixed' > "$state-r$k-findings.md"
  done
}

make_mutant() {
  runner="$tmp/review-round-mutant.sh"
  cp "$tool" "$runner"
  chmod +x "$runner"
  sed -i '' "$1" "$runner"
}

write_job_record
write_job_log

reset_state
run_subcommand --collect review-job --round 1
findings="$state-r1-findings.md"
if [ "$rc" -eq 0 ] && [ "$(<"$findings")" = "$(printf '%s\n' \
  '### MAJOR — Fresh R2/R3 reviewers receive no prior findings' \
  '### MAJOR — Required AudioApp migration is explicitly deferred' \
  'VERDICT: NO-GO' \
  'OPEN BLOCKERS: 2' \
  'Dispositions:')" ]; then
  pass 'collect writes the expected findings from the captured job log'
else
  fail 'collect writes the expected findings from the captured job log' "rc=$rc findings=$(<"$findings" 2>/dev/null || true)"
fi

reset_state
make_mutant 's/in_final = 1/in_final = 0/'
run_subcommand --collect review-job --round 1
if [ "$rc" -ne 0 ] || ! grep -Fqx '### MAJOR — Fresh R2/R3 reviewers receive no prior findings' "$state-r1-findings.md" 2>/dev/null; then
  pass 'collect source mutation turns the captured-log row red'
else
  fail 'collect source mutation turns the captured-log row red' "rc=$rc findings=$(<"$state-r1-findings.md" 2>/dev/null || true)"
fi
runner="$tool"

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
printf 'reviewer-thread\n' > "$state.thread"
printf '%s\n' 'MAJOR: retained r1 finding' 'VERDICT: NO-GO' 'Dispositions: fix it' > "$state-r1-findings.md"
RR_NEWEST_THREAD='fixer-thread' run
if [ "$rc" -eq 0 ] && ! grep -Fqx -- '--resume' "$tmp/dispatch-argv" && grep -Fq 'MAJOR: retained r1 finding' "$tmp/dispatched-prompt"; then
  pass 'fresh R2 prompt includes r1 findings'
else
  fail 'fresh R2 prompt includes r1 findings' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
printf 'reviewer-thread\n' > "$state.thread"
printf '%s\n' 'MAJOR: retained r1 finding' 'VERDICT: NO-GO' 'Dispositions: fix it' > "$state-r1-findings.md"
make_mutant 's/\$(<"\$findings")/MUTATED_FINDINGS/'
RR_NEWEST_THREAD='fixer-thread' run
if [ "$rc" -ne 0 ] || ! grep -Fq 'MAJOR: retained r1 finding' "$tmp/dispatched-prompt" 2>/dev/null; then
  pass 'fresh-R2-findings source mutation goes red'
else
  fail 'fresh-R2-findings source mutation goes red' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi
runner="$tool"

reset_state
printf '{"id":"review-job","threadId":"recovered-reviewer-thread","logFile":"%s"}\n' "$job_log" > "$job_record"
run_subcommand --adopt 2 review-job
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 2 ] && [ "$(<"$state.job")" = review-job ] && [ "$(<"$state.thread")" = recovered-reviewer-thread ]; then
  pass 'adopt records round, job and thread'
else
  fail 'adopt records round, job and thread' "rc=$rc round=$(<"$state" 2>/dev/null || true) job=$(<"$state.job" 2>/dev/null || true) thread=$(<"$state.thread" 2>/dev/null || true)"
fi

reset_state
printf '{"id":"review-job","threadId":"recovered-reviewer-thread","logFile":"%s"}\n' "$job_log" > "$job_record"
make_mutant 's/# Persist recovered reviewer state\./exit 1 # Persist recovered reviewer state./'
run_subcommand --adopt 2 review-job
if [ "$rc" -ne 0 ] && [ ! -e "$state" ]; then
  pass 'adopt source mutation goes red'
else
  fail 'adopt source mutation goes red' "rc=$rc round=$(<"$state" 2>/dev/null || true)"
fi
runner="$tool"

run --dry-run
if [ "$rc" -eq 0 ] && [ ! -e "$state" ]; then
  run
  if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 1 ] && printf '%s' "$output" | grep -Fq 'ROUND 1/3'; then
    pass 'dry-run leaves counter untouched and real round is round 1'
  else
    fail 'dry-run leaves counter untouched and real round is round 1' "rc=$rc counter=$(<"$state" 2>/dev/null || true) output=$output"
  fi
else
  fail 'dry-run leaves counter untouched and real round is round 1' "rc=$rc counter=$state"
fi

reset_state
make_mutant 's/if \[ "$dry_run" = false \]; then/if true; then/'
run --dry-run
if [ "$rc" -eq 0 ] && [ -f "$state" ] && [ "$(<"$state")" = 1 ]; then pass 'dry-run source mutation goes red'; else fail 'dry-run source mutation goes red' "rc=$rc counter=$(<"$state" 2>/dev/null || true)"; fi
runner="$tool"

reset_state
mkdir -p "$(dirname "$state")"
printf '3\n' > "$state"
seed_prior_findings 3
run
if [ "$rc" -ne 0 ] && [ "$(<"$state")" = 3 ]; then pass 'round 4 refused without user approval'; else fail 'round 4 refused without user approval' "rc=$rc counter=$(<"$state")"; fi

reset_state
mkdir -p "$(dirname "$state")"
printf '3\n' > "$state"
seed_prior_findings 3
make_mutant 's/\[ "$round" -ge 4 \] && \[ -z "$user_approved" \]/false/'
run
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 4 ]; then pass 'round-4 refusal source mutation goes red'; else fail 'round-4 refusal source mutation goes red' "rc=$rc counter=$(<"$state" 2>/dev/null || true)"; fi
runner="$tool"

reset_state
mkdir -p "$(dirname "$state")"
printf '3\n' > "$state"
seed_prior_findings 3
RR_NEWEST_THREAD='other-thread' run --user-approved 'I approve round four'
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 4 ] && [ "$(<"$state.thread")" = reviewer-thread ]; then pass 'round 4 accepted and thread persisted from job record'; else fail 'round 4 accepted and thread persisted from job record' "rc=$rc"; fi

reset_state
mkdir -p "$(dirname "$state")"
printf '3\n' > "$state"
seed_prior_findings 3
make_mutant 's|> "$thread_file"|> /dev/null|'
RR_NEWEST_THREAD='other-thread' run --user-approved 'I approve round four'
if [ "$rc" -eq 0 ] && [ ! -e "$state.thread" ]; then pass 'thread-persistence source mutation goes red'; else fail 'thread-persistence source mutation goes red' "rc=$rc thread=$(<"$state.thread" 2>/dev/null || true)"; fi
runner="$tool"

reset_state
RR_NEWEST_THREAD='reviewer-thread' run
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 1 ] && [ "$(<"$state.job")" = review-job ] && [ "$(<"$state.thread")" = reviewer-thread ]; then
  pass 'late threadId is resolved from the job record'
else
  fail 'late threadId is resolved from the job record' "rc=$rc counter=$(<"$state" 2>/dev/null || true) job=$(<"$state.job" 2>/dev/null || true) thread=$(<"$state.thread" 2>/dev/null || true)"
fi

reset_state
make_mutant 's/wait_for_thread_id "$job_record"/true/'
RR_NEWEST_THREAD='reviewer-thread' run
if [ "$rc" -eq 0 ] && [ ! -e "$state.thread" ]; then
  pass 'late threadId record-lookup source mutation goes red'
else
  fail 'late threadId record-lookup source mutation goes red' "rc=$rc thread=$(<"$state.thread" 2>/dev/null || true)"
fi
runner="$tool"

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
seed_prior_findings 1
printf 'previous-reviewer-thread\n' > "$state.thread"
printf 'previous-review-job\n' > "$state.job"
rm -f "$job_record"
RR_NEWEST_THREAD='other-thread' RR_THREAD_WAIT_SECONDS=0 run
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 2 ] && [ "$(<"$state.job")" = review-job ] && [ ! -e "$state.thread" ]; then
  pass 'unresolved replacement job leaves no stale reviewer thread'
else
  fail 'unresolved replacement job leaves no stale reviewer thread' "rc=$rc thread=$(<"$state.thread" 2>/dev/null || true)"
fi

reset_state
rm -f "$job_record"
RR_THREAD_WAIT_SECONDS=0 run
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 1 ] && [ "$(<"$state.job")" = review-job ] && [ ! -e "$state.thread" ]; then
  pass 'a launched job is always counted'
else
  fail 'a launched job is always counted' "rc=$rc counter=$(<"$state" 2>/dev/null || true) job=$(<"$state.job" 2>/dev/null || true)"
fi

reset_state
rm -f "$job_record"
make_mutant 's|# Persist launch state before resolving asynchronous reviewer metadata.|exit 1 # mutation skips counted launch|'
RR_THREAD_WAIT_SECONDS=0 run
if [ "$rc" -ne 0 ] && [ ! -e "$state" ] && [ ! -e "$state.job" ]; then
  pass 'launched-job counting source mutation goes red'
else
  fail 'launched-job counting source mutation goes red' "rc=$rc counter=$(<"$state" 2>/dev/null || true) job=$(<"$state.job" 2>/dev/null || true)"
fi
runner="$tool"

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
seed_prior_findings 1
printf 'reviewer-thread\n' > "$state.thread"
RR_NEWEST_THREAD='reviewer-thread' run
if [ "$rc" -eq 0 ] && grep -Fqx -- '--resume' "$tmp/dispatch-argv"; then pass 'resume only when newest thread is reviewer thread'; else fail 'resume only when newest thread is reviewer thread' "rc=$rc"; fi

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
seed_prior_findings 1
printf 'reviewer-thread\n' > "$state.thread"
RR_NEWEST_THREAD='other-thread' run
if [ "$rc" -eq 0 ] && ! grep -Fqx -- '--resume' "$tmp/dispatch-argv"; then pass 'newer non-reviewer thread starts fresh'; else fail 'newer non-reviewer thread starts fresh' "rc=$rc"; fi

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
seed_prior_findings 1
printf 'reviewer-thread\n' > "$state.thread"
make_mutant 's/\[ "$reviewer_thread" = "$newest_thread" \]/true/'
RR_NEWEST_THREAD='other-thread' run
if [ "$rc" -eq 0 ] && grep -Fqx -- '--resume' "$tmp/dispatch-argv"; then pass 'newest-thread resume source mutation goes red'; else fail 'newest-thread resume source mutation goes red' "rc=$rc"; fi
runner="$tool"

# --- acceptance criteria are mandatory (cch-q4c.2) ---

reset_state
RR_ACCEPTANCE='' run
if [ "$rc" -ne 0 ] && [ ! -e "$state" ] && grep -Fq 'no acceptance criteria resolved' "$tmp/err"; then
  pass 'empty acceptance criteria refuse the round'
else
  fail 'empty acceptance criteria refuse the round' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state
RR_ACCEPTANCE='   
	 ' run
if [ "$rc" -ne 0 ] && [ ! -e "$state" ] && grep -Fq 'no acceptance criteria resolved' "$tmp/err"; then
  pass 'whitespace-only acceptance criteria refuse the round'
else
  fail 'whitespace-only acceptance criteria refuse the round' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state
make_mutant 's/|| refuse_without_acceptance/|| true/'
RR_ACCEPTANCE='' run
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 1 ]; then
  pass 'acceptance-refusal source mutation goes red'
else
  fail 'acceptance-refusal source mutation goes red' "rc=$rc counter=$(<"$state" 2>/dev/null || true)"
fi
runner="$tool"

reset_state
run
if [ "$rc" -eq 0 ] && grep -Fq 'definition of done' "$tmp/dispatched-prompt" && grep -Fq 'Ship the bounded review changes.' "$tmp/dispatched-prompt"; then
  pass 'acceptance criteria reach the prompt as the scope boundary'
else
  fail 'acceptance criteria reach the prompt as the scope boundary' "rc=$rc"
fi

# --- a round may not be dispatched over a hole in the findings record (cch-q4c.2) ---

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
run
if [ "$rc" -ne 0 ] && [ "$(<"$state")" = 1 ] && grep -Fq 'no findings recorded for round(s) 1' "$tmp/err"; then
  pass 'round 2 refused when round 1 has no findings file'
else
  fail 'round 2 refused when round 1 has no findings file' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state
mkdir -p "$(dirname "$state")"
printf '2\n' > "$state"
seed_prior_findings 1
run
if [ "$rc" -ne 0 ] && grep -Fq 'no findings recorded for round(s) 2' "$tmp/err"; then
  pass 'round 3 refused when only round 1 has findings'
else
  fail 'round 3 refused when only round 1 has findings' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
make_mutant 's/\[ -n "$missing" \]/false/'
run
# Without the guard the run gets past the refusal and dies reading the absent findings file, so
# assert BOTH that the refusal is gone and that the failure moved to the unguarded read.
if ! grep -Fq 'no findings recorded for round(s)' "$tmp/err" && grep -Fq 'r1-findings.md' "$tmp/err"; then
  pass 'missing-prior-findings refusal source mutation goes red'
else
  fail 'missing-prior-findings refusal source mutation goes red' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi
runner="$tool"

# --- recorded gate evidence is carried or its absence is stated (cch-q4c.2) ---

reset_state
printf '%s\n' 'noise' 'VERIFY RESULT: PASS sha=abc1234 tree=def5678' 'CODE QUALITY RESULT: PASS sha=abc1234 tree=def5678 covered=test,lint' 'more noise' > "$tmp/evidence.txt"
run --evidence-file "$tmp/evidence.txt"
if [ "$rc" -eq 0 ] && grep -Fq 'VERIFY RESULT: PASS sha=abc1234 tree=def5678' "$tmp/dispatched-prompt" && ! grep -Fq 'noise' "$tmp/dispatched-prompt"; then
  pass 'evidence-file gate records reach the prompt without their surrounding log'
else
  fail 'evidence-file gate records reach the prompt without their surrounding log' "rc=$rc"
fi

reset_state
run
if [ "$rc" -eq 0 ] && grep -Fq 'No deterministic gate record was supplied' "$tmp/dispatched-prompt"; then
  pass 'absent gate evidence is a stated gap, not a silent omission'
else
  fail 'absent gate evidence is a stated gap, not a silent omission' "rc=$rc"
fi

reset_state
run --evidence-file "$tmp/does-not-exist.txt"
if [ "$rc" -ne 0 ] && [ ! -e "$state" ] && grep -Fq 'does not exist' "$tmp/err"; then
  pass 'a missing evidence file refuses rather than reporting no records'
else
  fail 'a missing evidence file refuses rather than reporting no records' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state
printf '%s\n' 'VERIFY RESULT: PASS sha=abc1234 tree=def5678' > "$tmp/evidence.txt"
make_mutant 's/evidence_section="$records"/evidence_section="REDACTED"/'
run --evidence-file "$tmp/evidence.txt"
if [ "$rc" -eq 0 ] && ! grep -Fq 'VERIFY RESULT: PASS sha=abc1234' "$tmp/dispatched-prompt"; then
  pass 'evidence-carrying source mutation goes red'
else
  fail 'evidence-carrying source mutation goes red' "rc=$rc"
fi
runner="$tool"

# --- a fresh reviewer says why it is fresh (cch-q4c.3) ---

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
seed_prior_findings 1
printf 'reviewer-thread\n' > "$state.thread"
RR_NEWEST_THREAD='fixer-thread' run
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -Fq 'the plugin resumes only the newest thread'; then
  pass 'a superseded reviewer thread reports why the round is fresh'
else
  fail 'a superseded reviewer thread reports why the round is fresh' "rc=$rc output=$output"
fi

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
seed_prior_findings 1
printf 'reviewer-thread\n' > "$state.thread"
make_mutant 's/REVIEW ROUND: the plugin resumes only the newest thread/REVIEW ROUND: silently fresh/'
RR_NEWEST_THREAD='fixer-thread' run
if [ "$rc" -eq 0 ] && ! printf '%s' "$output" | grep -Fq 'the plugin resumes only the newest thread'; then
  pass 'fresh-reviewer disclosure source mutation goes red'
else
  fail 'fresh-reviewer disclosure source mutation goes red' "rc=$rc"
fi
runner="$tool"

# --- the budget counts looks at one scope (cch-q4c.1) ---

reset_state
run
printf 'fix\n' > "$repo/file.txt"
git -C "$repo" commit -am 'fix(core): close the round-1 finding' -q
seed_prior_findings 1
run
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 2 ]; then
  pass 'a fix commit keeps the scope stamp and advances the round'
else
  fail 'a fix commit keeps the scope stamp and advances the round' "rc=$rc counter=$(<"$state" 2>/dev/null || true) err=$(<"$tmp/err" 2>/dev/null || true)"
fi

printf 'feature\n' > "$repo/file.txt"
git -C "$repo" commit -am 'feat(core): add a second capability to the branch' -q
seed_prior_findings 2
run
if [ "$rc" -ne 0 ] && [ "$(<"$state")" = 2 ] && grep -Fq 'the reviewed scope changed' "$tmp/err"; then
  pass 'a feat commit refuses the next round until the scope change is declared'
else
  fail 'a feat commit refuses the next round until the scope change is declared' "rc=$rc counter=$(<"$state" 2>/dev/null || true) err=$(<"$tmp/err" 2>/dev/null || true)"
fi

run --scope-changed 'second capability added; acceptance restated'
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 1 ] && printf '%s' "$output" | grep -Fq 'scope changed since round 2' && printf '%s' "$output" | grep -Fq 'ROUND 1/3'; then
  pass 'a declared scope change archives prior rounds and restarts the budget'
else
  fail 'a declared scope change archives prior rounds and restarts the budget' "rc=$rc counter=$(<"$state" 2>/dev/null || true) output=$output"
fi

if compgen -G "$state.scope-*/$slug-r1-findings.md" > /dev/null && compgen -G "$state.scope-*/$slug" > /dev/null; then
  pass 'the archived scope keeps its counter and findings'
else
  fail 'the archived scope keeps its counter and findings' "archive=$(ls -d "$state".scope-* 2>/dev/null || true)"
fi

reset_state
run
printf 'feature-two\n' > "$repo/file.txt"
git -C "$repo" commit -am 'feat(core): a third capability' -q
seed_prior_findings 1
make_mutant 's/\[ "$recorded_stamp" != "$stamp" \]/false/'
run
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 2 ]; then
  pass 'scope-change refusal source mutation goes red'
else
  fail 'scope-change refusal source mutation goes red' "rc=$rc counter=$(<"$state" 2>/dev/null || true)"
fi
runner="$tool"

# --- round 1 review fixes -----------------------------------------------------------------------

# BLOCKER: a dispatch failure after an accepted scope change must not destroy the live record.
reset_state
run
printf 'grown\n' > "$repo/file.txt"
git -C "$repo" commit -am 'feat(core): grow the branch again' -q
seed_prior_findings 1
cat > "$tmp/bin/codex-dispatch.sh" <<'DISPATCH'
#!/usr/bin/env bash
exit 7
DISPATCH
chmod +x "$tmp/bin/codex-dispatch.sh"
run --scope-changed 'grown, acceptance restated'
if [ "$rc" -ne 0 ] && [ "$(<"$state")" = 1 ] && [ -f "$state-r1-findings.md" ] && ! compgen -G "$state.scope-*" > /dev/null; then
  pass 'a failed dispatch after a scope change leaves the live counter and findings in place'
else
  fail 'a failed dispatch after a scope change leaves the live counter and findings in place' "rc=$rc counter=$(<"$state" 2>/dev/null || true) archive=$(ls -d "$state".scope-* 2>/dev/null || true)"
fi
cat > "$tmp/bin/codex-dispatch.sh" <<'DISPATCH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$RR_TMP/dispatch-argv"
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--prompt-file' ]; then
    cp "$2" "$RR_TMP/dispatched-prompt"
    break
  fi
  shift
done
printf '{"jobId":"review-job","logFile":"%s","waitCommand":"scripts/codex-wait.sh review-job --cwd /repo"}\n' "$RR_JOB_LOG"
DISPATCH
chmod +x "$tmp/bin/codex-dispatch.sh"

reset_state
run
printf 'grown-two\n' > "$repo/file.txt"
git -C "$repo" commit -am 'feat(core): grow once more' -q
seed_prior_findings 1
make_mutant 's/^    archive_pending=$recorded_stamp$/    archive_pending=$recorded_stamp; archive_scope_state "$recorded_stamp" >\/dev\/null/'
cat > "$tmp/bin/codex-dispatch.sh" <<'DISPATCH'
#!/usr/bin/env bash
exit 7
DISPATCH
chmod +x "$tmp/bin/codex-dispatch.sh"
run --scope-changed 'grown'
runner="$tool"
if [ -f "$state" ] || [ -f "$state-r1-findings.md" ]; then
  fail 'deferred-archive source mutation goes red' "the mutant kept the live record after a failed dispatch"
else
  pass 'deferred-archive source mutation goes red'
fi
cat > "$tmp/bin/codex-dispatch.sh" <<'DISPATCH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$RR_TMP/dispatch-argv"
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--prompt-file' ]; then
    cp "$2" "$RR_TMP/dispatched-prompt"
    break
  fi
  shift
done
printf '{"jobId":"review-job","logFile":"%s","waitCommand":"scripts/codex-wait.sh review-job --cwd /repo"}\n' "$RR_JOB_LOG"
DISPATCH
chmod +x "$tmp/bin/codex-dispatch.sh"

# MAJOR: an unresolvable base must be named, not reported as an empty scope.
reset_state
set +e
(cd "$repo" && PATH="$tmp/bin:$PATH" RR_TMP="$tmp" RR_JOB_LOG="$job_log" REVIEW_ROUND_JOB_RECORD="$job_record" REVIEW_ROUND_ACCEPTANCE='AC' bash "$tool" no-such-ref-xyz) > "$tmp/out" 2> "$tmp/err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ ! -e "$state" ] && grep -Fq 'is not a commit this worktree can resolve' "$tmp/err"; then
  pass 'an unresolvable base ref is refused by name'
else
  fail 'an unresolvable base ref is refused by name' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state
# `:` keeps the mutant parseable — a mutant that is a syntax error proves nothing, because the
# absent message would then be absent for any file-breaking edit at all.
make_mutant 's/^git rev-parse --verify --quiet "$base^{commit}" >\/dev\/null || {/: || {/'
set +e
(cd "$repo" && PATH="$tmp/bin:$PATH" RR_TMP="$tmp" RR_JOB_LOG="$job_log" REVIEW_ROUND_JOB_RECORD="$job_record" REVIEW_ROUND_ACCEPTANCE='AC' bash "$runner" no-such-ref-xyz) > "$tmp/out" 2> "$tmp/err"
rc=$?
set -e
runner="$tool"
if ! grep -Fq 'is not a commit this worktree can resolve' "$tmp/err"; then
  pass 'base-validation source mutation goes red'
else
  fail 'base-validation source mutation goes red' "err=$(<"$tmp/err" 2>/dev/null || true)"
fi

# MAJOR: the --bead path is the documented primary input; it had no coverage at all.
cat > "$tmp/bin/bd" <<'BD'
#!/usr/bin/env bash
case "$2" in
  bead-with)
    printf '%s\n' 'DESCRIPTION' 'Some description.' 'ACCEPTANCE CRITERIA' 'The gate refuses a blind dispatch.' 'MUST NOT REGRESS' 'The counter stays per scope.' 'NOTES' 'unrelated trailing note' ;;
  bead-without)
    printf '%s\n' 'DESCRIPTION' 'Some description.' 'NOTES' 'no criteria here' ;;
esac
BD
chmod +x "$tmp/bin/bd"

reset_state
RR_ACCEPTANCE= run --bead bead-with
if [ "$rc" -eq 0 ] && grep -Fq 'The gate refuses a blind dispatch.' "$tmp/dispatched-prompt" && grep -Fq 'The counter stays per scope.' "$tmp/dispatched-prompt" && ! grep -Fq 'unrelated trailing note' "$tmp/dispatched-prompt"; then
  pass 'bead acceptance criteria survive an all-caps line inside the body'
else
  fail 'bead acceptance criteria survive an all-caps line inside the body' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

reset_state
RR_ACCEPTANCE= run --bead bead-without
if [ "$rc" -ne 0 ] && [ ! -e "$state" ] && grep -Fq 'no acceptance criteria resolved' "$tmp/err"; then
  pass 'a bead with no acceptance section refuses the round'
else
  fail 'a bead with no acceptance section refuses the round' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state
make_mutant 's/found \&\& \/\^(DESCRIPTION|DESIGN|NOTES|ACCEPTANCE CRITERIA|PARENT|CHILDREN|DEPENDS ON|BLOCKS|RELATED|LABELS|COMMENTS|ATTACHMENTS|HISTORY)\[\[:space:\]\]\*\$\//found \&\& \/^[A-Z][A-Z _-]+$\//'
RR_ACCEPTANCE= run --bead bead-with
runner="$tool"
if [ "$rc" -eq 0 ] && ! grep -Fq 'The counter stays per scope.' "$tmp/dispatched-prompt"; then
  pass 'bead-heading terminator source mutation goes red'
else
  fail 'bead-heading terminator source mutation goes red' "rc=$rc"
fi
rm -f "$tmp/bin/bd"

# MINOR: returning to a previously reviewed scope must not overwrite that scope's archive.
# The scope must genuinely REPEAT for this to test anything. Reverting a commit adds a subject and
# produces a third distinct stamp, so the acceptance text is toggled instead: A, B, A, B archives
# stamp A twice and the second one must land beside the first.
repeat_scopes() {  # repeat_scopes -> archive directory count
  reset_state
  RR_ACCEPTANCE='AC-ONE' run
  printf '%s\n' 'first A findings' > "$state-r1-findings.md"
  RR_ACCEPTANCE='AC-TWO' run --scope-changed 'to B'
  printf '%s\n' 'first B findings' > "$state-r1-findings.md"
  RR_ACCEPTANCE='AC-ONE' run --scope-changed 'back to A'
  printf '%s\n' 'second A findings' > "$state-r1-findings.md"
  RR_ACCEPTANCE='AC-TWO' run --scope-changed 'to B again'
}

repeat_scopes
archives=$(ls -d "$state".scope-* 2>/dev/null || true)
archive_count=$(printf '%s\n' "$archives" | grep -c . || true)
first_a=$(cat "$state".scope-*/"$(basename "$state")"-r1-findings.md 2>/dev/null | grep -c 'first A findings' || true)
second_a=$(cat "$state".scope-*/"$(basename "$state")"-r1-findings.md 2>/dev/null | grep -c 'second A findings' || true)
if [ "$archive_count" = 3 ] && [ "$first_a" = 1 ] && [ "$second_a" = 1 ]; then
  pass 'a repeated scope archives beside its predecessor instead of overwriting it'
else
  fail 'a repeated scope archives beside its predecessor instead of overwriting it' "count=$archive_count firstA=$first_a secondA=$second_a archives=$archives"
fi

make_mutant 's/^  while \[ -e "$archive" \]; do$/  while false; do/'
repeat_scopes
runner="$tool"
archive_count=$(ls -d "$state".scope-* 2>/dev/null | grep -c . || true)
first_a=$(cat "$state".scope-*/"$(basename "$state")"-r1-findings.md 2>/dev/null | grep -c 'first A findings' || true)
if [ "$archive_count" != 3 ] || [ "$first_a" != 1 ]; then
  pass 'archive-collision source mutation goes red'
else
  fail 'archive-collision source mutation goes red' "the mutant kept three archives and both A findings"
fi

# MINOR: --dry-run must report the counter on disk, not the value an accepted scope change zeroed.
reset_state
run
printf 'dry\n' > "$repo/file.txt"
git -C "$repo" commit -am 'feat(core): dry-run scope' -q
seed_prior_findings 1
run --scope-changed 'grew' --dry-run
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 1 ] && grep -Fq 'Counter on disk: 1' "$tmp/out"; then
  pass 'a dry run after a scope change reports the counter that is actually on disk'
else
  fail 'a dry run after a scope change reports the counter that is actually on disk' "rc=$rc counter=$(<"$state" 2>/dev/null || true) out=$(<"$tmp/out" 2>/dev/null || true)"
fi

make_mutant 's/    "$(read_round)" "$round"/    "$previous" "$round"/'
run --scope-changed 'grew' --dry-run
runner="$tool"
if ! grep -Fq 'Counter on disk: 1' "$tmp/out"; then
  pass 'dry-run counter source mutation goes red'
else
  fail 'dry-run counter source mutation goes red' "out=$(<"$tmp/out" 2>/dev/null || true)"
fi

if [ "$failures" -eq 0 ]; then printf '%s\n' 'REVIEW ROUND SELFTEST: PASS'; completed=1; exit 0; fi
printf '%s\n' 'REVIEW ROUND SELFTEST: FAIL'; completed=1; exit 1
