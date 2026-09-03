#!/usr/bin/env bash
# Hermetic regression test for scripts/routing-report.sh.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
report="$root/routing-report.sh"
failures=0
run_output=''
run_status=0
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/routing-report-selftest.XXXXXX") || exit 1
# A completion sentinel, not `$?`: on bash 3.2 (the system shell here) a script killed by
# set -e/set -u runs its EXIT trap with $? ALREADY RESET TO 0, so capturing the status in the
# trap is inert — measured. Only positive evidence that the suite reached its own verdict can
# distinguish a real pass from an abort. cch-85b; rules/verification-integrity.md.
completed=0
trap 'st=$?; rm -rf "$tmp_root"; [ "$completed" = 1 ] || st=1; exit $st' EXIT HUP INT TERM

record() {
  if "$@"; then
    return 0
  fi
  failures=$((failures + 1))
  return 0
}

write_fixture() {
  local file="$1"
  shift
  : > "$file"
  while [ "$#" -gt 0 ]; do
    printf '%s\n' "$1" >> "$file"
    shift
  done
}

run_report() {
  local fixture_root="$1"
  shift
  if run_output=$(ROUTING_REPORT_ROOT="$fixture_root" bash "$report" "$@" 2>&1); then
    run_status=0
  else
    run_status=$?
  fi
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

known_root="$tmp_root/known"
quiet_root="$tmp_root/quiet"
empty_root="$tmp_root/empty"
direct_root="$tmp_root/direct"
mkdir -p "$known_root" "$quiet_root" "$empty_root" "$direct_root"

write_fixture "$known_root/known.jsonl" \
  '{"subagent_type":"codex:codex-rescue"}' \
  '{"subagent_type":"general-purpose"}' \
  '{"subagent_type":"Explore"}' \
  '{"subagent_type":"Plan"}' \
  'Under the Codex-first budget rule'
write_fixture "$quiet_root/quiet.jsonl" \
  '{"subagent_type":"commit"}' \
  '{"subagent_type":"code-quality"}'
write_fixture "$direct_root/direct.jsonl" \
  '{"tool_input":{"command":"node /tmp/codex-companion.mjs task --json"}}' \
  '{"subagent_type":"general-purpose"}' \
  '{"subagent_type":"Explore"}' \
  '{"subagent_type":"Plan"}' \
  '{"note":"codex-companion.mjs task outside a tool_input command"}'

known_rate_is_25_percent() {
  run_report "$known_root" --days 1
  [ "$run_status" -eq 0 ] && contains "$run_output" 'Codex delegations: 1' && contains "$run_output" 'Claude-side delegable subagents: 3' && contains "$run_output" 'Hook fires: 1' && contains "$run_output" 'Delegation rate: 25.0% (1/4)'
}

quiet_day_is_unknown() {
  run_report "$quiet_root" --days 1
  [ "$run_status" -eq 0 ] && contains "$run_output" 'Delegation rate: unknown (no delegable work seen; 0/0)' && ! contains "$run_output" 'Delegation rate: 0.0%'
}

empty_root_is_no_data() {
  run_report "$empty_root" --days 1
  [ "$run_status" -eq 2 ] && contains "$run_output" 'NO DATA'
}

non_delegable_does_not_move_ratio() {
  printf '%s\n' '{"subagent_type":"commit"}' '{"subagent_type":"code-quality"}' >> "$known_root/known.jsonl"
  run_report "$known_root" --days 1
  [ "$run_status" -eq 0 ] && contains "$run_output" 'Claude-side non-delegable subagents: 2' && contains "$run_output" 'Delegation rate: 25.0% (1/4)'
}

direct_companion_task_counts_once() {
  run_report "$direct_root" --days 1
  [ "$run_status" -eq 0 ] && contains "$run_output" 'Codex delegations: 1' && contains "$run_output" 'Delegation rate: 25.0% (1/4)'
}

json_rate_is_reconcilable() {
  run_report "$known_root" --days 1 --json
  [ "$run_status" -eq 0 ] && contains "$run_output" '"percentage":25.0,"numerator":1,"denominator":4'
}

since_selects_by_mtime() {
  run_report "$known_root" --since 2000-01-01
  [ "$run_status" -eq 0 ] && contains "$run_output" 'Delegation rate: 25.0% (1/4)' || return 1
  run_report "$known_root" --since 2999-01-01
  [ "$run_status" -eq 2 ] && contains "$run_output" 'NO DATA'
}

wrong_expectation_is_detected() {
  run_report "$known_root" --days 1
  if [ "$run_status" -eq 0 ] && contains "$run_output" 'Delegation rate: 26.0% (1/4)'; then
    return 1
  fi
  return 0
}

record known_rate_is_25_percent
record quiet_day_is_unknown
record empty_root_is_no_data
record non_delegable_does_not_move_ratio
record direct_companion_task_counts_once
record json_rate_is_reconcilable
record since_selects_by_mtime
record wrong_expectation_is_detected

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'ROUTING REPORT SELFTEST: PASS'
  completed=1; completed=1; exit 0
fi

printf '%s\n' 'ROUTING REPORT SELFTEST: FAIL'
completed=1; completed=1; exit 1
