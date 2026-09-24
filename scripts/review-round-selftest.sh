#!/usr/bin/env bash
# Hermetic regression test for review-round.sh; the fake dispatcher never reaches Codex.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tool="$root/scripts/review-round.sh"
sample_log="$root/scripts/testdata/review-job-sample.log"
coverage_log="$root/scripts/testdata/review-job-coverage-sample.log"
coverage_loose_log="$root/scripts/testdata/review-job-coverage-loose-sample.log"
coverage_inline_log="$root/scripts/testdata/review-job-coverage-inline-sample.log"
coverage_partial_log="$root/scripts/testdata/review-job-coverage-partial-sample.log"
bullets_log="$root/scripts/testdata/review-job-bullets-sample.log"
numbered_log="$root/scripts/testdata/review-job-numbered-sample.log"
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
expected=$(sed -n '/] Final output$/,$p' "$sample_log" | sed '1d; s/[[:space:]]*$//')
expected=$(printf '%s\n' "$expected" \
  "COVERAGE: (none recorded — this round's report carried no coverage map, so its gaps are unknown)" \
  'Dispositions:')
if [ "$rc" -eq 0 ] && [ "$(<"$findings")" = "$expected" ]; then
  pass 'collect writes the expected findings from the captured job log'
else
  fail 'collect writes the expected findings from the captured job log' "rc=$rc findings=$(<"$findings" 2>/dev/null || true)"
fi

# ---- pre-review self-check (cch-q4c.4) -------------------------------------------------------
# It must spend no budget, write no round state, and hand round 1 what it found.
reset_state
write_job_log
run --self-check
self_review_state="$state-r0-self-review.md"
if [ "$rc" -eq 0 ] &&
  grep -Fq 'PRE-REVIEW SELF-CHECK' "$tmp/dispatched-prompt" &&
  grep -Fq 'five risk classes' "$tmp/dispatched-prompt" &&
  [ ! -e "$state" ] && [ ! -e "$state.scope" ] && [ ! -e "$state.thread" ] &&
  [ -f "$state.self-check.job" ]; then
  pass 'self-check dispatches an author-side pass and writes no round state'
else
  fail 'self-check dispatches an author-side pass and writes no round state' \
    "rc=$rc counter=$(<"$state" 2>/dev/null || echo absent) prompt=$(head -3 "$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

run_subcommand --collect review-job --round 0
if [ "$rc" -eq 0 ] && [ -f "$self_review_state" ] && [ ! -e "$state" ]; then
  pass 'collect --round 0 records the self-review without touching the counter'
else
  fail 'collect --round 0 records the self-review without touching the counter' \
    "rc=$rc file=$(<"$self_review_state" 2>/dev/null || echo absent) counter=$(<"$state" 2>/dev/null || echo absent)"
fi

# A re-collect of the SAME job is idempotent; a SECOND self-check is refused rather than silently
# handing back the first pass's file, which is how a pre-fix self-review reached round 1 while the
# second pass's findings vanished (round 1 of this branch, MAJOR 3).
run_subcommand --collect review-job --round 0
if [ "$rc" -eq 0 ]; then
  pass 'collecting the same self-check twice is idempotent'
else
  fail 'collecting the same self-check twice is idempotent' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

printf 'second-self-check-job\n' > "$state.self-check.job"
run_subcommand --collect second-self-check-job --round 0
if [ "$rc" -ne 0 ] && grep -Fq 'already holds an earlier self-check' "$tmp/err"; then
  pass 'a second self-check will not silently overwrite the first record'
else
  fail 'a second self-check will not silently overwrite the first record' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi
printf 'review-job\n' > "$state.self-check.job"

# Round 1 must actually READ it — an r0 file nothing inlines is a file nobody wrote for a reason.
run
if [ "$rc" -eq 0 ] &&
  grep -Fq 'Author self-review and dispositions' "$tmp/dispatched-prompt" &&
  grep -Fq 'MAJOR — Fresh R2/R3 reviewers receive no prior findings' "$tmp/dispatched-prompt"; then
  pass 'round 1 inlines the recorded self-review'
else
  fail 'round 1 inlines the recorded self-review' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

# Round-flags mean nothing to a self-check and are refused rather than ignored.
reset_state
write_job_log
run --self-check --user-approved 'the owner said so'
if [ "$rc" -ne 0 ] && grep -Fq 'mean nothing to a self-check' "$tmp/err"; then
  pass 'self-check refuses flags that only a budgeted round can honour'
else
  fail 'self-check refuses flags that only a budgeted round can honour' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state
write_job_log
run --self-check --dry-run
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -Fq 'which is not a round' && ! printf '%s' "$output" | grep -Fq 'next round would be 0'; then
  pass 'a dry-run self-check does not report itself as round 0'
else
  fail 'a dry-run self-check does not report itself as round 0' "rc=$rc output=$output"
fi

# Absent, it is a STATED gap, not silence.
reset_state
write_job_log
run
if [ "$rc" -eq 0 ] && grep -Fq 'No author self-check was recorded' "$tmp/dispatched-prompt"; then
  pass 'a missing self-check is stated in the round-1 prompt'
else
  fail 'a missing self-check is stated in the round-1 prompt' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

# The self-check is a PRE-round pass: once a round has been dispatched it is refused, so it can
# never be used to reset or launder a branch already under review.
reset_state
write_job_log
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
printf '%s\n' 'MAJOR: seeded r1 finding' 'VERDICT: NO-GO' 'Dispositions: fixed' > "$state-r1-findings.md"
run --self-check
if [ "$rc" -ne 0 ]; then
  pass 'self-check is refused once a round has been dispatched'
else
  fail 'self-check is refused once a round has been dispatched' "rc=$rc"
fi

reset_state
write_job_log
make_mutant 's/Author self-review and dispositions/Author self-review absent/'
run_subcommand --collect review-job --round 0 >/dev/null 2>&1 || true
run
if [ "$rc" -ne 0 ] || ! grep -Fq 'Author self-review and dispositions' "$tmp/dispatched-prompt" 2>/dev/null; then
  pass 'self-review inlining source mutation goes red'
else
  fail 'self-review inlining source mutation goes red' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi
runner="$tool"

# ---- coverage map round-trip (cch-q4c.5) ----------------------------------------------------
# The sample is the same captured reviewer log as above with a COVERAGE block added by hand: the
# contract is new, so no reviewer has yet been prompted for one. What is real is the log shape
# around it — the Final output framing, the trailing verdict lines — which is what the extractor
# actually has to survive.
use_coverage_log() { cp "$coverage_log" "$job_log"; }

reset_state
use_coverage_log
run_subcommand --collect review-job --round 1
coverage_findings="$state-r1-findings.md"
if [ "$rc" -eq 0 ] &&
  grep -Fqx 'COVERAGE:' "$coverage_findings" &&
  grep -q '^traced=scripts/review-round.sh' "$coverage_findings" &&
  grep -q '^not-traced=docs/reference/review-round-scripts.md' "$coverage_findings"; then
  pass 'collect carries the coverage map into the findings file'
else
  fail 'collect carries the coverage map into the findings file' "rc=$rc findings=$(<"$coverage_findings" 2>/dev/null || true)"
fi
# Keep what collect actually produced: the later rows then feed the NEXT round exactly the file
# this pipeline writes, not a hand-made stand-in that could drift from it.
coverage_findings_fixture="$tmp/r1-coverage-findings.md"
cp "$coverage_findings" "$coverage_findings_fixture"

reset_state
use_coverage_log
make_mutant 's/append("COVERAGE:")/append("NEVER-MATCHES:")/'
run_subcommand --collect review-job --round 1
if [ "$rc" -ne 0 ] || ! grep -Fqx 'COVERAGE:' "$state-r1-findings.md" 2>/dev/null; then
  pass 'coverage-extraction source mutation goes red'
else
  fail 'coverage-extraction source mutation goes red' "rc=$rc findings=$(<"$state-r1-findings.md" 2>/dev/null || true)"
fi
runner="$tool"

# Shapes a real reviewer writes that the first parser dropped SILENTLY while keeping the header,
# so the next round was told nobody recorded a gap (round 1 of this branch, MAJOR 1).
reset_state
cp "$coverage_loose_log" "$job_log"
run_subcommand --collect review-job --round 1
loose_findings="$state-r1-findings.md"
if [ "$rc" -eq 0 ] &&
  grep -q '^traced=scripts/review-round.sh' "$loose_findings" &&
  grep -q '^not-traced=docs/reference/review-round-scripts.md' "$loose_findings" &&
  grep -q 'out of reach from this diff' "$loose_findings" &&
  ! grep -q 'none recorded' "$loose_findings"; then
  pass 'a map with blank lines and a wrapped field survives collection'
else
  fail 'a map with blank lines and a wrapped field survives collection' "rc=$rc findings=$(<"$loose_findings" 2>/dev/null || true)"
fi

reset_state
cp "$coverage_inline_log" "$job_log"
run_subcommand --collect review-job --round 1
inline_findings="$state-r1-findings.md"
if [ "$rc" -eq 0 ] &&
  grep -q '^traced=scripts/review-round.sh' "$inline_findings" &&
  grep -q '^not-traced=docs/reference/review-round-scripts.md' "$inline_findings"; then
  pass 'a one-line coverage map is split into its fields'
else
  fail 'a one-line coverage map is split into its fields' "rc=$rc findings=$(<"$inline_findings" 2>/dev/null || true)"
fi

# A header with no fields is a PARTIAL map. Keying the backstop on the header let it read as a
# complete one, which is how "the reviewer named no gap" and "the parser lost it" became the same
# answer — the instrument failure this feature exists to remove.
reset_state
cp "$coverage_partial_log" "$job_log"
run_subcommand --collect review-job --round 1
partial_findings="$state-r1-findings.md"
if [ "$rc" -eq 0 ] && grep -q 'COVERAGE: (incomplete' "$partial_findings"; then
  pass 'a coverage header with no fields is recorded as incomplete'
else
  fail 'a coverage header with no fields is recorded as incomplete' "rc=$rc findings=$(<"$partial_findings" 2>/dev/null || true)"
fi

reset_state
write_job_log
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
printf '%s\n' 'MAJOR: hand-written r1 finding' 'VERDICT: NO-GO' 'Dispositions: fixed' > "$state-r1-findings.md"
run
if [ "$rc" -eq 0 ] && grep -Fq 'round 1: no coverage map was recorded' "$tmp/dispatched-prompt"; then
  pass 'a hand-written findings file reads as unknown gaps, not as no gaps'
else
  fail 'a hand-written findings file reads as unknown gaps, not as no gaps' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

# A recorded gap becomes the NEXT round's target; that is the whole point of recording it.
reset_state
write_job_log
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
cp "$coverage_findings_fixture" "$state-r1-findings.md"
run
if [ "$rc" -eq 0 ] &&
  grep -Fq 'What earlier rounds recorded as NOT traced' "$tmp/dispatched-prompt" &&
  grep -Fq 'round 1: not-traced=docs/reference/review-round-scripts.md' "$tmp/dispatched-prompt"; then
  pass 'R2 prompt targets what round 1 did not trace'
else
  fail 'R2 prompt targets what round 1 did not trace' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

reset_state
write_job_log
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
cp "$coverage_findings_fixture" "$state-r1-findings.md"
make_mutant "s|not-traced\[\[:space:\]\]\*=|no-such-field[[:space:]]*=|"
run
if [ "$rc" -ne 0 ] || ! grep -Fq 'round 1: not-traced=docs/reference' "$tmp/dispatched-prompt" 2>/dev/null; then
  pass 'not-traced carry-forward source mutation goes red'
else
  fail 'not-traced carry-forward source mutation goes red' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi
runner="$tool"

# A findings file that QUOTES the coverage format inside a fence is showing an example, not
# recording a gap. Round 1 of this branch quoted a reviewer log to demonstrate a parsing defect and
# its invented path was carried into round 2's prompt as a real target — a fabricated gap, in the
# mechanism built to stop fabricated coverage claims.
reset_state
write_job_log
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
{
  printf '%s\n' 'MAJOR: the extractor drops a map with a blank line in it'
  printf '%s\n' 'Reviewer log that reproduces it:'
  printf '%s\n' '```'
  printf '%s\n' 'COVERAGE:'
  printf '%s\n' 'traced=scripts/a.sh'
  printf '%s\n' 'not-traced=scripts/invented-example.sh — ran out of budget, never opened it'
  printf '%s\n' '```'
  printf '%s\n' 'VERDICT: NO-GO'
  printf '%s\n' 'COVERAGE:'
  printf '%s\n' 'traced=scripts/review-round.sh'
  printf '%s\n' 'not-traced=docs/reference/review-round-scripts.md — budget'
} > "$state-r1-findings.md"
run
if [ "$rc" -eq 0 ] &&
  grep -Fq 'round 1: not-traced=docs/reference/review-round-scripts.md' "$tmp/dispatched-prompt" &&
  ! grep -Fq 'round 1: not-traced=scripts/invented-example.sh' "$tmp/dispatched-prompt"; then
  pass 'a not-traced line quoted inside a fence is not carried forward as a real gap'
else
  fail 'a not-traced line quoted inside a fence is not carried forward as a real gap' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

# ...and a file whose ONLY map is quoted recorded nothing, so it must read as unknown gaps. If the
# presence test and the extraction read fences differently, this file tests as mapped and then
# carries nothing forward — the reassuring wording for a round that mapped nothing.
reset_state
write_job_log
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
{
  printf '%s\n' 'MAJOR: hand-written r1 finding that only quotes the format'
  printf '%s\n' '```'
  printf '%s\n' 'not-traced=scripts/invented-example.sh — example only'
  printf '%s\n' '```'
  printf '%s\n' 'VERDICT: NO-GO'
} > "$state-r1-findings.md"
run
if [ "$rc" -eq 0 ] &&
  grep -Fq 'round 1: no coverage map was recorded' "$tmp/dispatched-prompt" &&
  ! grep -Fq 'round 1: not-traced=scripts/invented-example.sh' "$tmp/dispatched-prompt"; then
  pass 'a file whose only coverage map is fenced reads as unknown gaps'
else
  fail 'a file whose only coverage map is fenced reads as unknown gaps' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

# NEGATIVE CONTROL: stop skipping fences and the quoted example comes back as a target.
reset_state
write_job_log
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
{
  printf '%s\n' 'MAJOR: the extractor drops a map with a blank line in it'
  printf '%s\n' '```'
  printf '%s\n' 'not-traced=scripts/invented-example.sh — ran out of budget, never opened it'
  printf '%s\n' '```'
  printf '%s\n' 'VERDICT: NO-GO'
  printf '%s\n' 'COVERAGE:'
  printf '%s\n' 'traced=scripts/review-round.sh'
  printf '%s\n' 'not-traced=docs/reference/review-round-scripts.md — budget'
} > "$state-r1-findings.md"
make_mutant "s|fence = !fence; next|next|"
run
if [ "$rc" -ne 0 ] || grep -Fq 'round 1: not-traced=scripts/invented-example.sh' "$tmp/dispatched-prompt" 2>/dev/null; then
  pass 'fence-skipping source mutation goes red'
else
  fail 'fence-skipping source mutation goes red' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi
runner="$tool"

# A round that recorded NO map must not read as "nothing was skipped".
reset_state
write_job_log
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
printf '%s\n' 'MAJOR: seeded r1 finding' 'VERDICT: NO-GO' \
  "COVERAGE: (none recorded — this round's report carried no coverage map, so its gaps are unknown)" \
  'Dispositions: fixed' > "$state-r1-findings.md"
run
if [ "$rc" -eq 0 ] && grep -Fq 'round 1: no coverage map was recorded' "$tmp/dispatched-prompt"; then
  pass 'a round with no coverage map is stated as an unknown gap, not silence'
else
  fail 'a round with no coverage map is stated as an unknown gap, not silence' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

write_job_log

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

# The self-check's record archives with the rest. Its file name does not match the findings glob,
# so leaving it behind handed the NEW scope's round 1 a pass over a diff that no longer exists
# (round 1 of this branch, MAJOR 2).
printf '%s\n' 'MAJOR: stale self-review from the old scope' 'VERDICT: NO-GO' > "$state-r0-self-review.md"
printf 'old-self-check-job\n' > "$state.self-check.job"
printf 'old-self-check-job\n' > "$state.r0-collected.job"
printf 'grown again\n' > "$repo/file.txt"
git -C "$repo" commit -am 'feat(core): add a third capability to the branch' -q
seed_prior_findings 1
run --scope-changed 'third capability added; acceptance restated'
if [ "$rc" -eq 0 ] &&
  [ ! -e "$state-r0-self-review.md" ] && [ ! -e "$state.self-check.job" ] && [ ! -e "$state.r0-collected.job" ] &&
  compgen -G "$state.scope-*/$slug-r0-self-review.md" > /dev/null &&
  ! grep -Fq 'stale self-review from the old scope' "$tmp/dispatched-prompt"; then
  pass 'a scope change archives the self-review instead of inlining it into the new scope'
else
  fail 'a scope change archives the self-review instead of inlining it into the new scope' \
    "rc=$rc live=$(ls "$state"-r0-self-review.md "$state".self-check.job 2>/dev/null || echo gone)"
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
make_mutant 's/^      archive_pending=$recorded_stamp$/      archive_pending=$recorded_stamp; archive_scope_state "$recorded_stamp" >\/dev\/null/'
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

# --- cch-48i: the refusal must say WHICH half of the stamp moved -------------------------------

# Only the acceptance text moves: same commits, so the counter must be kept, not restarted.
reset_state
RR_ACCEPTANCE='Ship the thing.' run
RR_ACCEPTANCE='Ship the thing, please.' run
if [ "$rc" -ne 0 ] && grep -Fq 'the acceptance text changed since round 1, but the commits did not' "$tmp/err" && [ "$(<"$state")" = 1 ]; then
  pass 'an acceptance-only change is refused as such, naming the half that moved'
else
  fail 'an acceptance-only change is refused as such, naming the half that moved' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

seed_prior_findings 1
RR_ACCEPTANCE='Ship the thing, please.' run --acceptance-reworded 'typo'
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 2 ] && ! compgen -G "$state.scope-*" > /dev/null; then
  pass 'a declared rewording keeps the counter and archives nothing'
else
  fail 'a declared rewording keeps the counter and archives nothing' "rc=$rc counter=$(<"$state" 2>/dev/null || true) archives=$(ls -d "$state".scope-* 2>/dev/null || true)"
fi

# The same wording change, declared instead as a real redefinition, still restarts the budget.
reset_state
RR_ACCEPTANCE='Ship the thing.' run
seed_prior_findings 1
RR_ACCEPTANCE='Ship a different thing.' run --scope-changed 'the definition of done really changed'
if [ "$rc" -eq 0 ] && [ "$(<"$state")" = 1 ] && compgen -G "$state.scope-*" > /dev/null; then
  pass 'an acceptance change declared as a scope change still restarts the budget'
else
  fail 'an acceptance change declared as a scope change still restarts the budget' "rc=$rc counter=$(<"$state" 2>/dev/null || true)"
fi

# Only the commits move: the refusal must not offer the rewording flag, which would not apply.
reset_state
RR_ACCEPTANCE='Ship the thing.' run
printf 'more\n' > "$repo/file.txt"
git -C "$repo" commit -am 'feat(core): a new capability' -q
seed_prior_findings 1
RR_ACCEPTANCE='Ship the thing.' run
if [ "$rc" -ne 0 ] && grep -Fq 'What moved: the scope-changing commits below.' "$tmp/err" && ! grep -Fq 'acceptance-reworded' "$tmp/err"; then
  pass 'a commits-only change names the commits and does not offer the rewording flag'
else
  fail 'a commits-only change names the commits and does not offer the rewording flag' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

# Both halves move: the refusal says so rather than reporting only one.
reset_state
RR_ACCEPTANCE='Ship the thing.' run
printf 'more-two\n' > "$repo/file.txt"
git -C "$repo" commit -am 'feat(core): another capability' -q
seed_prior_findings 1
RR_ACCEPTANCE='Ship something else entirely.' run
if [ "$rc" -ne 0 ] && grep -Fq 'the acceptance text, as well as the commits' "$tmp/err"; then
  pass 'when both halves move the refusal says so'
else
  fail 'when both halves move the refusal says so' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

# The negative control: with one combined digest the halves cannot be told apart, which is the
# defect this change removes — an acceptance-only edit then reads as an enlarged scope.
reset_state
# Returning nothing from stamp_field is what a single combined digest amounts to: neither half
# can be read back, so no refusal can say which one moved.
make_mutant 's/^stamp_field() {/stamp_field() { return 0;/'
RR_ACCEPTANCE='Ship the thing.' run
RR_ACCEPTANCE='Ship the thing, please.' run
runner="$tool"
if ! grep -Fq 'the acceptance text changed since round 1, but the commits did not' "$tmp/err"; then
  pass 'combining the two digests source mutation goes red'
else
  fail 'combining the two digests source mutation goes red' "the mutant still attributed the change"
fi

# --- cch-k6d: carried gate records must be marked fresh or stale against this worktree ---------

reset_state
fresh_tree=$( cd "$repo" && ( export GIT_INDEX_FILE; GIT_INDEX_FILE=$(mktemp -u); git read-tree HEAD >/dev/null 2>&1; git add -A >/dev/null 2>&1; git rev-parse --short "$(git write-tree)"; rm -f "$GIT_INDEX_FILE" ) )
printf 'VERIFY RESULT: PASS sha=deadbee tree=%s\n' "$fresh_tree" > "$tmp/evidence-fresh.txt"
run --evidence-file "$tmp/evidence-fresh.txt"
if [ "$rc" -eq 0 ] && grep -Fq '[fresh: measured on this exact worktree]' "$tmp/dispatched-prompt"; then
  pass 'a gate record measured on this worktree is carried as fresh'
else
  fail 'a gate record measured on this worktree is carried as fresh' "rc=$rc"
fi

reset_state
printf 'VERIFY RESULT: PASS sha=deadbee tree=0000000\n' > "$tmp/evidence-stale.txt"
run --evidence-file "$tmp/evidence-stale.txt"
if [ "$rc" -eq 0 ] && grep -Fq 'STALE: measured on tree 0000000' "$tmp/dispatched-prompt" && grep -Fq 'treat it as no evidence' "$tmp/dispatched-prompt"; then
  pass 'a gate record from another tree is carried as stale, not as evidence'
else
  fail 'a gate record from another tree is carried as stale, not as evidence' "rc=$rc"
fi

# A record with no tree= cannot be tied to any content, which is a third state and not "fresh".
reset_state
printf 'VERIFY RESULT: PASS sha=deadbee\n' > "$tmp/evidence-untied.txt"
run --evidence-file "$tmp/evidence-untied.txt"
if [ "$rc" -eq 0 ] && grep -Fq 'UNVERIFIABLE: no tree=' "$tmp/dispatched-prompt"; then
  pass 'a gate record with no tree= is carried as unverifiable'
else
  fail 'a gate record with no tree= is carried as unverifiable' "rc=$rc"
fi

# An edit after the record was written must flip the same record from fresh to stale.
reset_state
run --evidence-file "$tmp/evidence-fresh.txt"
printf 'edited after the gate ran\n' >> "$repo/file.txt"
seed_prior_findings 1
run --evidence-file "$tmp/evidence-fresh.txt"
if [ "$rc" -eq 0 ] && grep -Fq 'STALE: measured on tree' "$tmp/dispatched-prompt"; then
  pass 'editing the worktree after the record was written makes that record stale'
else
  fail 'editing the worktree after the record was written makes that record stale' "rc=$rc prompt=$(grep -F 'VERIFY RESULT' "$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

reset_state
make_mutant 's/^  current=$(working_tree_hash)$/  current=""/'
run --evidence-file "$tmp/evidence-stale.txt"
runner="$tool"
if ! grep -Fq 'STALE: measured on tree 0000000' "$tmp/dispatched-prompt"; then
  pass 'stale-evidence detection source mutation goes red'
else
  fail 'stale-evidence detection source mutation goes red' 'the mutant still marked the record stale'
fi

# --- cch-aif: a reviewer that writes findings as bold bullets must not lose every title --------

use_bullets_log() { cp "$bullets_log" "$job_log"; }

reset_state
use_bullets_log
run_subcommand --collect review-job --round 1
collected=$(<"$state-r1-findings.md")
if [ "$rc" -eq 0 ] \
  && printf '%s' "$collected" | grep -Fq '**BLOCKER — src/cache/store.ts:120**' \
  && printf '%s' "$collected" | grep -Fq '**MAJOR — src/cache/eviction.ts:64**' \
  && printf '%s' "$collected" | grep -Fq '**MINOR: src/cache/index.ts:9**' \
  && printf '%s' "$collected" | grep -Fqx 'VERDICT: NO-GO'; then
  pass 'collect keeps bold-bullet findings, not just the verdict'
else
  fail 'collect keeps bold-bullet findings, not just the verdict' "rc=$rc findings=$collected"
fi

reset_state
use_bullets_log
make_mutant 's|in_final { append($0) }|in_final \&\& /^### / { append($0) }|'
run_subcommand --collect review-job --round 1
runner="$tool"
if ! grep -Fq '**BLOCKER — src/cache/store.ts:120**' "$state-r1-findings.md" 2>/dev/null; then
  pass 'bold-bullet full-body source mutation goes red'
else
  fail 'bold-bullet full-body source mutation goes red' 'the mutant still collected the bullet'
fi

reset_state

# The captured report appears under Assistant message and Final output. Only the final copy
# survives, including its prose and numbered findings, so the next round can read them.
use_numbered_log() { cp "$numbered_log" "$job_log"; }

reset_state
use_numbered_log
run_subcommand --collect review-job --round 1
numbered_findings="$state-r1-findings.md"
if [ "$rc" -eq 0 ] &&
  grep -Fq '**Two decision-changing defects remain. I would not ship this branch yet.**' "$numbered_findings" &&
  grep -Fq 'Make every displayed track Keep-capable, or omit tracks that cannot satisfy the Keep contract.' "$numbered_findings" &&
  grep -Fq 'Enter the exhausted state when filtering leaves no tracks and no further page.' "$numbered_findings" &&
  [ "$(grep -Fc 'Make every displayed track Keep-capable, or omit tracks that cannot satisfy the Keep contract.' "$numbered_findings")" -eq 1 ] &&
  [ "$(grep -Fc 'Enter the exhausted state when filtering leaves no tracks and no further page.' "$numbered_findings")" -eq 1 ] &&
  grep -Fqx 'OPEN BLOCKERS: 2' "$numbered_findings" &&
  grep -Fqx 'VERDICT: NO-GO' "$numbered_findings" &&
  grep -Fq 'not-traced=design comp R1/R2 visual parity' "$numbered_findings"; then
  pass 'collect preserves one final copy of both numbered findings'
else
  fail 'collect preserves one final copy of both numbered findings' "rc=$rc findings=$(<"$numbered_findings" 2>/dev/null || true)"
fi

reset_state
use_numbered_log
make_mutant 's|in_final { append($0) }|in_final \&\& /^### / { append($0) }|'
run_subcommand --collect review-job --round 1
runner="$tool"
if [ "$rc" -ne 0 ] || ! grep -Fq 'Make every displayed track Keep-capable, or omit tracks that cannot satisfy the Keep contract.' "$state-r1-findings.md" 2>/dev/null; then
  pass 'numbered findings full-body source mutation goes red'
else
  fail 'numbered findings full-body source mutation goes red' 'the mutant still collected numbered findings'
fi

# A bracketed severity label is report text, not the next timestamped job event.
write_bracketed_finding_log() {
  printf '%s\n' '[2026-09-24T11:28:28.538Z] Final output' \
    '[MAJOR] src/example.sh:3 — bracketed severity finding text' \
    'OPEN BLOCKERS: 1' 'VERDICT: NO-GO' > "$job_log"
}

reset_state
write_bracketed_finding_log
run_subcommand --collect review-job --round 1
if [ "$rc" -eq 0 ] &&
  grep -Fqx '[MAJOR] src/example.sh:3 — bracketed severity finding text' "$state-r1-findings.md" &&
  grep -Fqx 'OPEN BLOCKERS: 1' "$state-r1-findings.md" &&
  grep -Fqx 'VERDICT: NO-GO' "$state-r1-findings.md"; then
  pass 'collect keeps bracketed severity findings through the verdict'
else
  fail 'collect keeps bracketed severity findings through the verdict' "rc=$rc findings=$(<"$state-r1-findings.md" 2>/dev/null || true)"
fi

reset_state
write_bracketed_finding_log
make_mutant 's|^  in_final && .* { flush_field(); in_final = 0; coverage = 0; next }$|  in_final \&\& /^\\[[^]]+\\][[:space:]]/ { flush_field(); in_final = 0; coverage = 0; next }|'
run_subcommand --collect review-job --round 1
runner="$tool"
if [ "$rc" -ne 0 ] ||
  ! grep -Fqx '[MAJOR] src/example.sh:3 — bracketed severity finding text' "$state-r1-findings.md" 2>/dev/null ||
  ! grep -Fqx 'OPEN BLOCKERS: 1' "$state-r1-findings.md" 2>/dev/null ||
  ! grep -Fqx 'VERDICT: NO-GO' "$state-r1-findings.md" 2>/dev/null; then
  pass 'bracketed severity event-boundary source mutation goes red'
else
  fail 'bracketed severity event-boundary source mutation goes red' 'the mutant retained the bracketed finding and verdict'
fi

# An OPEN BLOCKERS count with no finding body would silently erase the reason for NO-GO.
write_empty_blocker_log() {
  printf '%s\n' '[2026-01-01T00:00:00Z] Final output' \
    'COVERAGE:' 'traced=reviewed files' 'not-traced=remaining files' \
    'OPEN BLOCKERS: 1' 'VERDICT: NO-GO' > "$job_log"
}

reset_state
write_empty_blocker_log
run_subcommand --collect review-job --round 1
if [ "$rc" -ne 0 ] && grep -Fq "$job_log" "$tmp/err" &&
  [ ! -e "$state-r1-findings.md" ] &&
  [ -d "$common/review-rounds" ] && [ -z "$(find "$common/review-rounds" -maxdepth 1 -name ".${slug}-r1-findings.*" -print)" ]; then
  pass 'collect rejects blockers with no finding body and removes its temp'
else
  fail 'collect rejects blockers with no finding body and removes its temp' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state
write_empty_blocker_log
make_mutant "s/^  if awk '/  if false \&\& awk '/"
run_subcommand --collect review-job --round 1
runner="$tool"
if [ "$rc" -eq 0 ] && [ -e "$state-r1-findings.md" ]; then
  pass 'missing finding body guard source mutation goes red'
else
  fail 'missing finding body guard source mutation goes red' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

# Lead-in prose cannot stand in for a labeled finding when blockers remain open.
write_prose_only_blocker_log() {
  printf '%s\n' '[2026-09-24T11:28:28.538Z] Final output' \
    'Two defects remain.' 'COVERAGE:' 'traced=reviewed files' \
    'not-traced=remaining files' 'OPEN BLOCKERS: 1' 'VERDICT: NO-GO' > "$job_log"
}

reset_state
write_prose_only_blocker_log
run_subcommand --collect review-job --round 1
if [ "$rc" -ne 0 ] && grep -Fq "$job_log" "$tmp/err" &&
  [ ! -e "$state-r1-findings.md" ] &&
  [ -z "$(find "$common/review-rounds" -maxdepth 1 -name ".${slug}-r1-findings.*" -print)" ]; then
  pass 'collect rejects prose without a labeled blocker finding'
else
  fail 'collect rejects prose without a labeled blocker finding' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state
write_prose_only_blocker_log
make_mutant '/labeled_body = 1/s|^.*$|    { labeled_body = 1 }|'
run_subcommand --collect review-job --round 1
runner="$tool"
if [ "$rc" -eq 0 ] && [ -e "$state-r1-findings.md" ]; then
  pass 'unlabeled prose finding-guard source mutation goes red'
else
  fail 'unlabeled prose finding-guard source mutation goes red' "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state

# --- cch-g81: a threadId recorded after round 1 finished must still resume at round 2 ---------

seed_late_thread_state() {  # round 1 left a job id but no thread; the record gained one later
  reset_state
  mkdir -p "$(dirname "$state")"
  printf '1\n' > "$state"
  printf 'review-job\n' > "$state.job"
  rm -f "$state.thread"
  printf '%s\n' 'MAJOR: retained r1 finding' 'VERDICT: NO-GO' 'Dispositions: fix it' > "$state-r1-findings.md"
}

seed_late_thread_state
RR_NEWEST_THREAD='reviewer-thread' run
if [ "$rc" -eq 0 ] && grep -Fqx -- '--resume' "$tmp/dispatch-argv"; then
  pass 'a late-recorded threadId resumes the reviewer at round 2'
else
  fail 'a late-recorded threadId resumes the reviewer at round 2' "rc=$rc argv=$(<"$tmp/dispatch-argv" 2>/dev/null || true)"
fi

seed_late_thread_state
make_mutant 's/^    delayed_thread_id=\$(wait_for_thread_id "\$delayed_job_record")$/    delayed_thread_id=""/'
RR_NEWEST_THREAD='reviewer-thread' run
runner="$tool"
if [ "$rc" -ne 0 ] || ! grep -Fqx -- '--resume' "$tmp/dispatch-argv"; then
  pass 'late-threadId source mutation goes red'
else
  fail 'late-threadId source mutation goes red' "rc=$rc argv=$(<"$tmp/dispatch-argv" 2>/dev/null || true)"
fi

reset_state

# --- a pre-split bare-digest stamp must not cost an in-flight branch its counter ---------------

legacy_stamp() {  # legacy_stamp <acceptance> -> the digest format written before the split
  { printf '%s\n' "$1"; printf -- '---\n'; git -C "$repo" log --format=%s "$base..HEAD" \
      | grep -vaE '^(fix|test|docs|chore)(\([^)]*\))?!?:'; } | shasum -a 256 | awk '{print $1}'
}

seed_legacy_scope() {  # seed_legacy_scope <acceptance-used-for-the-stamp>
  reset_state
  mkdir -p "$(dirname "$state")"
  printf '1\n' > "$state"
  printf '%s\n' 'MAJOR: retained r1 finding' 'VERDICT: NO-GO' 'Dispositions: fix it' > "$state-r1-findings.md"
  printf '%s\n' "$(legacy_stamp "$1")" > "$state.scope"
}

seed_legacy_scope 'Ship the bounded review changes.'
run
if [ "$rc" -eq 0 ] \
  && printf '%s' "$output" | grep -Fq 'scope stamp upgraded from the pre-split format' \
  && [ "$(<"$state")" = 2 ] \
  && grep -Fq 'acceptance=' "$state.scope"; then
  pass 'an unchanged pre-split scope stamp is upgraded, not charged a restart'
else
  fail 'an unchanged pre-split scope stamp is upgraded, not charged a restart' \
    "rc=$rc round=$(<"$state" 2>/dev/null || true) out=$output err=$(<"$tmp/err" 2>/dev/null || true)"
fi

seed_legacy_scope 'Ship the bounded review changes.'
make_mutant 's/legacy_scope_stamp "\$goal"/"no-such-digest"/'
run
runner="$tool"
if [ "$rc" -ne 0 ] && grep -Fq 'refused' "$tmp/err"; then
  pass 'pre-split stamp upgrade source mutation goes red'
else
  fail 'pre-split stamp upgrade source mutation goes red' "rc=$rc out=$output"
fi

seed_legacy_scope 'A different definition of done entirely.'
run
if [ "$rc" -ne 0 ] \
  && grep -Fq 'What moved: unknown' "$tmp/err" \
  && ! grep -Fq 'What moved: the scope-changing commits below.' "$tmp/err"; then
  pass 'a pre-split stamp that really moved refuses without claiming which half moved'
else
  fail 'a pre-split stamp that really moved refuses without claiming which half moved' \
    "rc=$rc err=$(<"$tmp/err" 2>/dev/null || true)"
fi

reset_state


# ---------------------------------------------------------------------------
# Reviewer prompt calibration and the POLISH cap.
#
# These rows exist because the defect they pin was invisible for four branches: the rule
# (rules/branch-completion-review.md § Stage 2) mandates an anti-manufacture sentence from R2, and
# the script simply never sent it. Nothing tested what the prompt CONTAINS, so nothing could notice
# a mandated sentence going missing. Assert on the dispatched prompt, not on the source.

# R1 keeps the dig-deeper posture: the first look at a diff is where breadth pays.
reset_state
write_job_log
run
if [ "$rc" -eq 0 ] && ! grep -q '^Do not manufacture severity to seem rigorous\.$' "$tmp/dispatched-prompt"; then
  pass 'round 1 does not carry the R2-only anti-manufacture calibration'
else
  fail 'round 1 does not carry the R2-only anti-manufacture calibration' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

# The cap is NOT R2-gated: an unbounded polish list is backlog on any round.
if [ "$rc" -eq 0 ] &&
  grep -q '^Report at most 3 POLISH findings' "$tmp/dispatched-prompt" &&
  grep -Fq 'DECISION-CHANGING findings are not' "$tmp/dispatched-prompt"; then
  pass 'round 1 carries the POLISH cap and exempts DECISION-CHANGING from it'
else
  fail 'round 1 carries the POLISH cap and exempts DECISION-CHANGING from it' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

# R2 is the round re-reading code it has already judged, so it gets the restraining sentence.
reset_state
write_job_log
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
printf '%s\n' 'MAJOR: seeded r1 finding' 'VERDICT: NO-GO' 'not-traced=docs/ — budget' > "$state-r1-findings.md"
run
if [ "$rc" -eq 0 ] &&
  grep -q '^Do not manufacture severity to seem rigorous\.$' "$tmp/dispatched-prompt" &&
  grep -q '^Report at most 3 POLISH findings' "$tmp/dispatched-prompt"; then
  pass 'round 2 carries the anti-manufacture calibration verbatim'
else
  fail 'round 2 carries the anti-manufacture calibration verbatim' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi

# NEGATIVE CONTROL: delete the sentence from the source and the R2 row must go red.
reset_state
write_job_log
mkdir -p "$(dirname "$state")"
printf '1\n' > "$state"
printf '%s\n' 'MAJOR: seeded r1 finding' 'VERDICT: NO-GO' 'not-traced=docs/ — budget' > "$state-r1-findings.md"
make_mutant "s|Do not manufacture|Feel free to manufacture|"
run
if [ "$rc" -ne 0 ] || ! grep -q '^Do not manufacture severity to seem rigorous\.$' "$tmp/dispatched-prompt" 2>/dev/null; then
  pass 'anti-manufacture calibration source mutation goes red'
else
  fail 'anti-manufacture calibration source mutation goes red' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi
runner="$tool"

# NEGATIVE CONTROL: drop the round guard and R1 wrongly receives the R2-only text.
reset_state
write_job_log
make_mutant 's|\[ "$round" -ge 2 \]; then|[ "$round" -ge 0 ]; then|'
run
if [ "$rc" -ne 0 ] || grep -q '^Do not manufacture severity to seem rigorous\.$' "$tmp/dispatched-prompt" 2>/dev/null; then
  pass 'round-guard source mutation goes red'
else
  fail 'round-guard source mutation goes red' "rc=$rc prompt=$(<"$tmp/dispatched-prompt" 2>/dev/null || true)"
fi
runner="$tool"

if [ "$failures" -eq 0 ]; then printf '%s\n' 'REVIEW ROUND SELFTEST: PASS'; completed=1; exit 0; fi
printf '%s\n' 'REVIEW ROUND SELFTEST: FAIL'; completed=1; exit 1
