#!/usr/bin/env bash
# Hermetic regression test for scripts/retro-evidence.sh.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
report="$root/scripts/retro-evidence.sh"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/retro-evidence-selftest.XXXXXX") || exit 1
completed=0
trap 'st=$?; rm -rf "$tmp_root"; [ "$completed" = 1 ] || st=1; exit $st' EXIT HUP INT TERM

failures=0
pass() { printf '%s: PASS\n' "$1"; }
fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
section_body() {
  printf '%s\n' "$1" | awk -v heading="$2" '$0 == heading { found=1; next } found && /^## / { exit } found { print }'
}

fixture_repo="$tmp_root/harness"
ledger="$tmp_root/acks"
ledger_two="$tmp_root/acks-two"
missing_ledger="$tmp_root/missing-acks"
loop_root="$tmp_root/loop-transcripts"
routing_root="$tmp_root/routing-transcripts"
empty_ledger="$tmp_root/empty-acks"
fake_bin="$tmp_root/bin"
mkdir -p "$fixture_repo/scripts" "$loop_root" "$routing_root" "$fake_bin"
touch "$empty_ledger"
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in auth) exit 0 ;; pr) printf "%s\\n" "[]" ;; *) exit 1 ;; esac' > "$fake_bin/gh"
chmod 755 "$fake_bin/gh"

git -C "$fixture_repo" init -q
git -C "$fixture_repo" config user.name 'Retro Evidence Selftest'
git -C "$fixture_repo" config user.email 'retro-evidence-selftest@example.test'
git -C "$fixture_repo" remote add origin git@github.com:fixture/retro-harness.git
printf '%s\n' '# fixture change' > "$fixture_repo/scripts/fixture.sh"
git -C "$fixture_repo" add scripts/fixture.sh
GIT_AUTHOR_DATE='2026-09-02T12:00:00Z' GIT_COMMITTER_DATE='2026-09-02T12:00:00Z' \
  git -C "$fixture_repo" commit -qm 'fixture: script change'

printf '%s\n' \
  'branch-review	1111111	2026-09-02T10:00:00Z	rounds=4 verdict=GO open_blockers=0 classes=security user_decision="authorize one extra round"' > "$ledger"
printf '%s\n' \
  'branch-review	2222222	2026-09-03T11:00:00Z	rounds=2 verdict=NO-GO open_blockers=1 classes=integrity' \
  'branch-review	3333333	2026-09-04T12:00:00Z	rounds=not-a-number verdict=GO open_blockers=0 classes=coverage' \
  'branch-review	4444444	2026-09-04T12:00:00Z	GO after 2 rounds; classes 1-lifetime/ordering/cancellation.' \
  'branch-review	5555555	2026-09-05T00:00:00Z	GO after 2 rounds; classes 1-lifetime/ordering/cancellation.' \
  'merge-gate	6666666	2026-09-05T12:00:00Z	ignored' > "$ledger_two"

run_report() {
  (cd "$fixture_repo" && \
    PATH='/usr/bin:/bin' \
    LOOP_REPORT_ROOT="$loop_root" \
    ROUTING_REPORT_ROOT="$routing_root" \
    bash "$report" --since 2026-09-01 --acks "$ledger" --acks "$ledger_two") 2>&1
}

if output=$(run_report); then
  expected_row='| 1111111 | 2026-09-02T10:00:00Z | 4 | GO | 0 | security | yes | ok |'
  if contains "$output" "$expected_row"; then
    pass 'parsed acknowledgement columns'
  else
    fail 'parsed acknowledgement columns' 'expected non-zero fixture values were not all present'
  fi
  if contains "$output" 'Summary: 5 acks (2 ok, 1 legacy, 2 malformed); max rounds: 4; over 3 rounds: 1; NO-GO: 1.'; then
    pass 'acknowledgement status counters'
  else
    fail 'acknowledgement status counters' 'mixed fixture status counts or ok-only aggregates did not reconcile'
  fi
  if contains "$output" '| 3333333 | 2026-09-04T12:00:00Z |  |  |  |  |  | malformed |'; then
    pass 'invalid field acknowledgement is malformed before cutover'
  else
    fail 'invalid field acknowledgement is malformed before cutover' 'field syntax with an invalid value was not malformed'
  fi
  if contains "$output" '| 4444444 | 2026-09-04T12:00:00Z |  |  |  |  |  | legacy |'; then
    pass 'pre-cutover prose acknowledgement is legacy'
  else
    fail 'pre-cutover prose acknowledgement is legacy' 'legacy row did not retain empty machine fields'
  fi
  if contains "$output" '| 5555555 | 2026-09-05T00:00:00Z |  |  |  |  |  | malformed |'; then
    pass 'post-cutover prose acknowledgement is malformed'
  else
    fail 'post-cutover prose acknowledgement is malformed' 'post-cutover prose was not malformed'
  fi
  if contains "$output" 'Aggregate metrics (max rounds, over 3 rounds, NO-GO) are computed over ok rows only.' && contains "$output" 'Legacy rows predate the field format and carry no machine comparison.'; then
    pass 'acknowledgement comparison limits are explicit'
  else
    fail 'acknowledgement comparison limits are explicit' 'ok-only metrics or legacy limitation prose was absent'
  fi
  if contains "$output" '## Harness changes in the window' && contains "$output" 'fixture: script change'; then
    pass 'harness change fixture'
  else
    fail 'harness change fixture' 'throwaway repository change was not reported'
  fi
  if contains "$output" '## Not measured' && contains "$output" 'acknowledgements recorded before the field cutover are not machine-comparable'; then
    pass 'not measured present'
  else
    fail 'not measured present' 'fixed limits section was absent'
  fi
else
  fail 'fixture report runs' 'report exited non-zero'
fi

if output=$(cd "$fixture_repo" && PATH='/usr/bin:/bin' LOOP_REPORT_ROOT="$loop_root" ROUTING_REPORT_ROOT="$routing_root" bash "$report" --since 2026-09-01 --repo fixture/one --repo fixture/two 2>&1); then
  if contains "$output" '  - fixture/one' && contains "$output" '  - fixture/two'; then
    pass 'repeatable repositories'
  else
    fail 'repeatable repositories' 'both repositories were not listed separately'
  fi
else
  fail 'repeatable repositories' 'repeatable repository report exited non-zero'
fi

if output=$(cd "$fixture_repo" && PATH="$fake_bin:/usr/bin:/bin" LOOP_REPORT_ROOT="$loop_root" ROUTING_REPORT_ROOT="$routing_root" bash "$report" --since 2026-09-05 --repo fixture/empty --acks "$empty_ledger" 2>&1); then
  for heading in '## Merged pull requests' '## Branch-review acknowledgements' '## Harness changes in the window'; do
    body=$(section_body "$output" "$heading")
    if [ -n "$body" ] && contains "$body" 'none in window.'; then
      pass "empty ${heading#\#\# } section is explicit"
    else
      fail "empty ${heading#\#\# } section is explicit" 'section body did not contain none in window'
    fi
  done
else
  fail 'empty sections report runs' 'empty-section fixture report exited non-zero'
fi

if output=$(cd "$fixture_repo" && PATH='/usr/bin:/bin' LOOP_REPORT_ROOT="$loop_root" ROUTING_REPORT_ROOT="$routing_root" bash "$report" --since 2026-09-01 --acks "$missing_ledger" 2>&1); then
  if contains "$output" "WARNING: acknowledgement ledger missing: $missing_ledger" && contains "$output" '## Not measured'; then
    pass 'missing acknowledgement ledger warns and succeeds'
  else
    fail 'missing acknowledgement ledger warns and succeeds' 'warning or fixed section was absent'
  fi
else
  fail 'missing acknowledgement ledger warns and succeeds' 'missing ledger made report fail'
fi

if output=$(cd "$fixture_repo" && bash "$report" --since 2026-09-01 --days 7 2>&1); then
  fail 'mutually exclusive window flags' 'both flags exited zero'
elif [ "$?" -eq 2 ] && contains "$output" 'Usage:'; then
  pass 'mutually exclusive window flags'
else
  fail 'mutually exclusive window flags' 'both flags did not exit 2 with usage'
fi

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'RETRO EVIDENCE SELFTEST: PASS'
  completed=1; exit 0
fi
printf '%s\n' 'RETRO EVIDENCE SELFTEST: FAIL'
completed=1; exit 1
