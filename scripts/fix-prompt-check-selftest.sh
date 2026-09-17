#!/usr/bin/env bash
# Selftest for scripts/fix-prompt-check.sh.
#
# Both directions, and the clean fixture is the REAL template's worked example rather than a
# hand-written one: a prompt written from templates/review-fix-round.md has to pass, so if the
# template ever grows countdown phrasing in the text authors copy, this row goes red there.
set -uo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
check="$script_dir/fix-prompt-check.sh"
template="$root/templates/review-fix-round.md"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/fix-prompt-check-selftest.XXXXXX") || exit 1

completed=0
trap 'st=$?; rm -rf "$tmp_root"; [ "$completed" = 1 ] || st=1; exit $st' EXIT HUP INT TERM

failures=0
fail() { printf 'FIX PROMPT CHECK SELFTEST: FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

run() {  # run <file> [args...] -> sets run_status, run_output
  local file=$1; shift
  run_output=$(bash "$check" "$file" "$@" 2>&1)
  run_status=$?
}

[ -f "$template" ] || { fail "template not found: $template"; completed=1; exit 1; }

# The worked example is the part of the template an author copies; the "What this template forbids"
# section deliberately QUOTES the phrases under test, so scanning the whole template would be a
# test of the wrong text.
clean="$tmp_root/clean-prompt.md"
awk '/^## Worked example$/ { inside = 1; next } inside && /^## / { exit } inside { print }' "$template" > "$clean"
[ -s "$clean" ] || { fail 'could not extract the worked example from the template'; completed=1; exit 1; }
run "$clean" --label 'template worked example'
[ "$run_status" -eq 0 ] || fail "a prompt written from the template was rejected (exit $run_status): $run_output"

# One row per kind of pressure, each with the line number it must name. Written as
# <expected-line>|<text> so a pattern that matches the wrong line is caught, not just "something
# matched" — a checker that reports the wrong location sends the author to the wrong sentence.
cases=(
  '2|This is the last allowed round, so make it count.'
  '2|Round 3 of 3 — finish everything.'
  '2|You have two rounds remaining.'
  '2|There is 1 round left.'
  '2|We are out of rounds after this.'
  '2|The review budget is nearly gone.'
  '2|This is your last chance to fix it.'
  '2|Round 3/3 — finish everything.'
  '2|This is round 3/3.'
  '2|Rounds remaining: 1'
  '2|Only one review round remains.'
  '2|There is very little budget left.'
  '2|We cannot afford another review round.'
  '2|This is the final pass before we ship.'
  '2|This is your last shot at this.'
  '2|Round 3 of three.'
)

# Ordinary fix-prompt prose that names a round without applying pressure must stay clean — a check
# that fires on "round 2 findings" would be unusable in the prompt it exists to guard.
clean_lines=(
  'You are closing branch-review round 2 findings on feat/x.'
  'These findings came from round 2 of the review.'
  'Report the mutation that proves each test can go red.'
)
for line in "${clean_lines[@]}"; do
  ok="$tmp_root/ok.md"
  printf '%s\n' "$line" > "$ok"
  run "$ok"
  [ "$run_status" -eq 0 ] || fail "ordinary prose was rejected: [$line] -> $run_output"
done
for case_row in "${cases[@]}"; do
  expected_line=${case_row%%|*}
  text=${case_row#*|}
  dirty="$tmp_root/dirty.md"
  printf '%s\n%s\n%s\n' 'You are closing branch-review round 2 findings on feat/x.' "$text" 'Fix each finding and hunt siblings.' > "$dirty"
  run "$dirty" --label 'pressure row'
  if [ "$run_status" -ne 1 ]; then
    fail "budget language was accepted (exit $run_status): $text"
    continue
  fi
  case "$run_output" in
    *"$dirty:$expected_line "*) ;;
    *) fail "the failure did not name line $expected_line for [$text]: $run_output" ;;
  esac
  case "$run_output" in
    *"$text"*) ;;
    *) fail "the failure did not quote the offending line for [$text]: $run_output" ;;
  esac
done

# One line, two matching patterns, must be counted ONCE: an inflated count overstates the work.
double="$tmp_root/double.md"
printf '%s\n' 'The review budget is nearly gone.' > "$double"
run "$double"
case "$run_output" in
  *'1 line(s) apply'*) ;;
  *) fail "a line matching two patterns was not counted once: $run_output" ;;
esac

# An empty input is exit 2 as well: a scan over no bytes is a green that could never be red.
empty="$tmp_root/empty.md"
: > "$empty"
run "$empty"
[ "$run_status" -eq 2 ] || fail "an empty prompt file did not exit 2 (exit $run_status): $run_output"

# A missing input is exit 2, never a clean bill (rules/verification-integrity.md).
run "$tmp_root/not-there.md"
[ "$run_status" -eq 2 ] || fail "a missing prompt file did not exit 2 (exit $run_status): $run_output"

# NEGATIVE CONTROL: delete the countdown pattern from the checker and the countdown row must be
# accepted. Without this the rows above could be passing on some other pattern's match.
mutant="$tmp_root/fix-prompt-check-mutant.sh"
sed "/'countdown|round\[\[:space:\]\]/d" "$check" > "$mutant"
if cmp -s "$mutant" "$check"; then
  fail 'countdown-pattern mutation did not apply'
else
  countdown="$tmp_root/countdown.md"
  printf '%s\n%s\n' 'You are closing branch-review round 2 findings on feat/x.' 'Round 3 of 3 — finish everything.' > "$countdown"
  mutant_output=$(bash "$mutant" "$countdown" 2>&1)
  mutant_status=$?
  [ "$mutant_status" -eq 0 ] || fail "removing the countdown pattern did not let the countdown line through (exit $mutant_status): $mutant_output"
fi

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'FIX PROMPT CHECK SELFTEST: PASS'
  completed=1; exit 0
fi
printf '%s\n' 'FIX PROMPT CHECK SELFTEST: FAIL'
completed=1; exit 1
