#!/usr/bin/env bash
# Refuse review-budget language in a written fix-round prompt.
#
# templates/review-fix-round.md forbids telling an implementation task how much review budget is
# left: the task cannot see the budget, cannot spend it, and answers the pressure by widening its
# own scope — which is how a fix round grows into the thing the next round has to review (measured
# on the 6-round branch, 2026-09-16). The template says so; nothing checked a prompt actually
# written from it. This is that check.
#
# Usage: scripts/fix-prompt-check.sh <prompt-file> [--label <what it is>]
# Exit: 0 clean · 1 budget or countdown phrasing found · 2 setup error (no input).
#
# A missing input is exit 2, never 0: an instrument that cannot see must not report clean
# (rules/verification-integrity.md).
set -uo pipefail

label='fix prompt'
prompt_file=''

while [ $# -gt 0 ]; do
  case $1 in
    --label) label=${2:-}; shift 2 || exit 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) printf 'FIX PROMPT CHECK: unknown argument %s\n' "$1" >&2; exit 2 ;;
    *)
      [ -z "$prompt_file" ] || { printf 'FIX PROMPT CHECK: only one prompt file may be scanned\n' >&2; exit 2; }
      prompt_file=$1
      shift
      ;;
  esac
done

[ -n "$prompt_file" ] || { printf 'FIX PROMPT CHECK: no prompt file given\n' >&2; exit 2; }
if [ ! -f "$prompt_file" ]; then
  printf 'FIX PROMPT CHECK: FAIL (prompt file not found at %s — cannot report clean without it)\n' "$prompt_file" >&2
  exit 2
fi

# Each row is <name>|<extended regex>, matched case-insensitively against the whole line. The names
# are what the failure prints, so the author reads WHICH kind of pressure the line applies rather
# than a regex. Add a row rather than widening one: a row that matches two things cannot say which.
patterns=(
  'countdown|round[[:space:]]+[0-9]+[[:space:]]+(of|/)[[:space:]]*[0-9]+'
  'last-round|(this[[:space:]]+is[[:space:]]+the[[:space:]]+)?(last|final)([[:space:]]+(allowed|permitted|available))?[[:space:]]+round'
  'rounds-left|[0-9]+[[:space:]]+(more[[:space:]]+)?rounds?[[:space:]]+(left|remaining)'
  'rounds-left|(no|one|two|three)[[:space:]]+(more[[:space:]]+)?rounds?[[:space:]]+(left|remaining)'
  'out-of-rounds|(out[[:space:]]+of|no[[:space:]]+more)[[:space:]]+rounds'
  'budget|(review|round)[[:space:]]+budget'
  'budget|budget[[:space:]]+(is[[:space:]]+)?(nearly[[:space:]]+)?(gone|exhausted|spent|up)'
  'last-chance|last[[:space:]]+chance'
)

# Two patterns can match one line (a "review budget" row and a "budget is gone" row both fire on
# "the review budget is nearly gone"), so rows are deduplicated and the count is DISTINCT OFFENDING
# LINES. A count that double-counted would overstate what the author has to fix.
matches=$(
  for row in "${patterns[@]}"; do
    name=${row%%|*}
    regex=${row#*|}
    grep -n -i -E "$regex" -- "$prompt_file" 2>/dev/null | while IFS= read -r line; do
      printf '%s\t%s\t%s\n' "${line%%:*}" "$name" "${line#*:}"
    done
  done | sort -t"$(printf '\t')" -k1,1n -u
)

hits=0
if [ -n "$matches" ]; then
  while IFS=$'\t' read -r lineno name text; do
    [ -n "$lineno" ] || continue
    printf 'FIX PROMPT CHECK: FAIL (%s) %s:%s [%s] %s\n' "$label" "$prompt_file" "$lineno" "$name" "$text" >&2
  done <<< "$matches"
  hits=$(printf '%s\n' "$matches" | cut -f1 | sort -u | wc -l | tr -d ' ')
fi

if [ "$hits" -gt 0 ]; then
  printf 'FIX PROMPT CHECK: FAIL (%s, %s line(s) apply review-budget pressure — templates/review-fix-round.md forbids it)\n' \
    "$label" "$hits" >&2
  exit 1
fi
printf 'FIX PROMPT CHECK: PASS (%s, %s patterns)\n' "$label" "${#patterns[@]}"
exit 0
