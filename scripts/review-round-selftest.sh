#!/usr/bin/env bash
# Hermetic regression test for review-round.sh; the fake dispatcher never reaches Codex.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tool="$root/scripts/review-round.sh"
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
  printf '%s\n' '{"id":"review-job","threadId":"reviewer-thread"}' > "$job_record"
}

cat > "$tmp/bin/codex-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$RR_TMP/dispatch-argv"
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
  (cd "$repo" && PATH="$tmp/bin:$PATH" RR_TMP="$tmp" RR_JOB_LOG="$job_log" RR_NEWEST_THREAD="${RR_NEWEST_THREAD:-}" REVIEW_ROUND_THREAD_WAIT_SECONDS="${RR_THREAD_WAIT_SECONDS:-30}" bash "$runner" "$base" "$@") > "$tmp/out" 2> "$tmp/err"
  rc=$?
  set -e
  output=$(<"$tmp/out")
}

reset_state() {
  rm -rf "$(dirname "$state")"
  rm -f "$tmp/dispatch-argv"
  write_job_record
}

make_mutant() {
  runner="$tmp/review-round-mutant.sh"
  cp "$tool" "$runner"
  chmod +x "$runner"
  sed -i '' "$1" "$runner"
}

write_job_record
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
run
if [ "$rc" -ne 0 ] && [ "$(<"$state")" = 3 ]; then pass 'round 4 refused without user approval'; else fail 'round 4 refused without user approval' "rc=$rc counter=$(<"$state")"; fi

reset_state
mkdir -p "$(dirname "$state")"
printf '3\n' > "$state"
make_mutant 's/\[ "$round" -ge 4 \] && \[ -z "$user_approved" \]/false/'
run
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 4 ]; then pass 'round-4 refusal source mutation goes red'; else fail 'round-4 refusal source mutation goes red' "rc=$rc counter=$(<"$state" 2>/dev/null || true)"; fi
runner="$tool"

reset_state
mkdir -p "$(dirname "$state")"
printf '3\n' > "$state"
RR_NEWEST_THREAD='other-thread' run --user-approved 'I approve round four'
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 4 ] && [ "$(<"$state.thread")" = reviewer-thread ]; then pass 'round 4 accepted and thread persisted from job record'; else fail 'round 4 accepted and thread persisted from job record' "rc=$rc"; fi

reset_state
mkdir -p "$(dirname "$state")"
printf '3\n' > "$state"
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
printf 'reviewer-thread\n' > "$state.thread"
RR_NEWEST_THREAD='reviewer-thread' run
if [ "$rc" -eq 0 ] && grep -Fqx -- '--resume' "$tmp/dispatch-argv"; then pass 'resume only when newest thread is reviewer thread'; else fail 'resume only when newest thread is reviewer thread' "rc=$rc"; fi

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
printf 'reviewer-thread\n' > "$state.thread"
RR_NEWEST_THREAD='other-thread' run
if [ "$rc" -eq 0 ] && ! grep -Fqx -- '--resume' "$tmp/dispatch-argv"; then pass 'newer non-reviewer thread starts fresh'; else fail 'newer non-reviewer thread starts fresh' "rc=$rc"; fi

reset_state
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
printf 'reviewer-thread\n' > "$state.thread"
make_mutant 's/\[ "$reviewer_thread" = "$newest_thread" \]/true/'
RR_NEWEST_THREAD='other-thread' run
if [ "$rc" -eq 0 ] && grep -Fqx -- '--resume' "$tmp/dispatch-argv"; then pass 'newest-thread resume source mutation goes red'; else fail 'newest-thread resume source mutation goes red' "rc=$rc"; fi
runner="$tool"

if [ "$failures" -eq 0 ]; then printf '%s\n' 'REVIEW ROUND SELFTEST: PASS'; completed=1; exit 0; fi
printf '%s\n' 'REVIEW ROUND SELFTEST: FAIL'; completed=1; exit 1
