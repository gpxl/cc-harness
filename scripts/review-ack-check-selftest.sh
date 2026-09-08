#!/usr/bin/env bash
# Hermetic regression test for review-ack-check.sh.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tool="$root/scripts/review-ack-check.sh"
completed=0
trap 'status=$?; [ "$completed" = 1 ] || status=1; exit "$status"' EXIT HUP INT TERM
failures=0
pass() { printf '%s: PASS\n' "$1"; }
fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }
expect() {
  local name=$1 expected=$2 note=$3 expected_output=${4:-} forbidden_output=${5:-} forbidden_present=false
  output=$(bash "$tool" "$note" 2>&1); rc=$?
  if [ -n "$forbidden_output" ]; then
    case "$output" in *"$forbidden_output"*) forbidden_present=true ;; esac
  fi
  if [ "$rc" -eq "$expected" ] && { [ -z "$expected_output" ] || printf '%s' "$output" | grep -Fq "$expected_output"; } && [ "$forbidden_present" = false ]; then
    pass "$name"
  else
    fail "$name" "rc=$rc output=$output"
  fi
}

expect 'GO/0 without user decision passes' 0 'rounds=3 verdict=GO open_blockers=0 classes=1'
expect 'unknown verdict fails' 1 'rounds=3 verdict=MAYBE open_blockers=0 classes=1' 'invalid verdict='
expect 'duplicate rounds fail' 1 'rounds=3 rounds=3 verdict=GO open_blockers=0 classes=1' 'duplicate rounds='
expect 'non-numeric rounds fail' 1 'rounds=three verdict=GO open_blockers=0 classes=1' 'invalid rounds='
expect 'zero rounds fail' 1 'rounds=0 verdict=GO open_blockers=0 classes=1' 'invalid rounds='
expect 'invalid classes fail' 1 'rounds=3 verdict=GO open_blockers=0 classes=banana' 'invalid classes='
expect 'round 4 without decision fails' 1 'rounds=4 verdict=GO open_blockers=0 classes=1'
expect 'round 4 with quoted user decision passes' 0 'rounds=4 verdict=GO open_blockers=0 classes=3 user_decision="2 (authorize one more round)"' 'user_decision="2 (authorize one more round)"'
expect 'unquoted multi-word user decision fails without truncation' 1 'rounds=4 verdict=NO-GO open_blockers=2 classes=3 user_decision=merge anyway' 'invalid user_decision=' 'user_decision="merge"'
expect 'NO-GO without decision fails' 1 'rounds=3 verdict=NO-GO open_blockers=0 classes=1'
expect 'open blocker without decision fails' 1 'rounds=3 verdict=GO open_blockers=1 classes=1'
expect 'missing fields fail' 1 'rounds=3 verdict=GO classes=1'
expect 'NO-GO with decision passes' 0 'rounds=3 verdict=NO-GO open_blockers=1 user_decision="merge with disclosure" classes=1'
if [ "$failures" -eq 0 ]; then printf '%s\n' 'REVIEW ACK CHECK SELFTEST: PASS'; completed=1; exit 0; fi
printf '%s\n' 'REVIEW ACK CHECK SELFTEST: FAIL'; completed=1; exit 1
