#!/usr/bin/env bash
# Assemble measured retrospective evidence; it deliberately does not draw conclusions.
set -u

# StemLab commit 49c8eff made acknowledgement fields mandatory on this date.
REVIEW_ACK_FIELD_CUTOVER=2026-09-05

usage() {
  printf '%s\n' 'Usage: scripts/retro-evidence.sh [--since YYYY-MM-DD | --days N] [--repo <owner/name> ...] [--acks <path> ...] [--out <file>] [--selftest]' >&2
}

script_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$script_root")
# review-ack-check.sh exposes these helpers when sourced; do not duplicate its field regexes.
. "$script_root/scripts/review-ack-check.sh"

days=7
since=''
days_set=false
selftest=false
out=''
repos=''
ack_paths=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --days) [ "$#" -ge 2 ] || { usage; exit 2; }; days=$2; days_set=true; shift 2 ;;
    --since) [ "$#" -ge 2 ] || { usage; exit 2; }; since=$2; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || { usage; exit 2; }; repos="${repos}${repos:+$'\n'}$2"; shift 2 ;;
    --acks) [ "$#" -ge 2 ] || { usage; exit 2; }; ack_paths="${ack_paths}${ack_paths:+$'\n'}$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || { usage; exit 2; }; out=$2; shift 2 ;;
    --selftest) selftest=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [ "$selftest" = true ]; then
  [ -z "$since" ] && [ "$days_set" = false ] && [ -z "$repos" ] && [ -z "$ack_paths" ] && [ -z "$out" ] || { usage; exit 2; }
  exec bash "$script_root/scripts/retro-evidence-selftest.sh"
fi
if [ -n "$since" ] && [ "$days_set" = true ]; then usage; exit 2; fi
case "$days" in ''|*[!0-9]*|0) usage; exit 2 ;; esac
if [ -n "$since" ]; then case "$since" in ????-??-??) ;; *) usage; exit 2 ;; esac; fi

utc_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
days_ago() {
  if date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ'
  elif date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'
  else
    return 1
  fi
}

end=$(utc_now) || exit 1
if [ -n "$since" ]; then start="${since}T00:00:00Z"; else start=$(days_ago "$days") || exit 1; fi
start_day=${start%%T*}
end_day=${end%%T*}

if [ -z "$repos" ]; then
  origin=$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null || true)
  case "$origin" in
    git@github.com:*.git) repos=${origin#git@github.com:}; repos=${repos%.git} ;;
    https://github.com/*.git) repos=${origin#https://github.com/}; repos=${repos%.git} ;;
    https://github.com/*) repos=${origin#https://github.com/} ;;
  esac
fi

md_cell() { printf '%s' "$1" | tr '\n' ' ' | sed 's/|/\\|/g'; }

emit_window() {
  printf '%s\n' '## Window'
  printf '%s\n' "- Start: $start" "- End: $end"
  if [ -n "$repos" ]; then
    printf '%s\n' '- Repos:'
    while IFS= read -r repo; do printf '%s\n' "  - $repo"; done <<EOF
$repos
EOF
  else
    printf '%s\n' '- Repos: none resolved from origin remote.'
  fi
  if [ -n "$ack_paths" ]; then
    printf '%s\n' '- Ack ledgers:'
    while IFS= read -r path; do
      if [ -f "$path" ]; then printf '%s\n' "  - read: $path"; else printf '%s\n' "  - missing: $path"; fi
    done <<EOF
$ack_paths
EOF
  else
    printf '%s\n' '- Ack ledgers: none provided.'
  fi
  printf '\n'
}

render_prs() {
  python3 - "$1" "$start" "$end" "$2" <<'PY'
import datetime as dt
import json
import sys

repo, start, end, path = sys.argv[1:]
start_at = dt.datetime.fromisoformat(start.replace("Z", "+00:00"))
end_at = dt.datetime.fromisoformat(end.replace("Z", "+00:00"))
for pr in json.load(open(path, encoding="utf-8")):
    created = dt.datetime.fromisoformat(pr["createdAt"].replace("Z", "+00:00"))
    merged = dt.datetime.fromisoformat(pr["mergedAt"].replace("Z", "+00:00"))
    if start_at <= merged <= end_at:
        title = pr["title"].replace("|", "\\|").replace("\n", " ")
        hours = (merged - created).total_seconds() / 3600
        lines = pr.get("additions", 0) + pr.get("deletions", 0)
        print("ROW\t| {} | #{} | {} | {:.1f} | {} |".format(repo, pr["number"], title, hours, lines))
        print("HOURS\t{:.1f}".format(hours))
PY
}

emit_prs() {
  local auth_log pr_data data rc repo count median
  printf '%s\n' '## Merged pull requests'
  if ! command -v gh >/dev/null 2>&1; then printf '%s\n\n' 'WARNING: gh unavailable; merged pull requests not measured.'; return; fi
  auth_log=$(mktemp "${TMPDIR:-/tmp}/retro-evidence-gh-auth.XXXXXX") || return
  gh auth status > "$auth_log" 2>&1; rc=$?
  rm -f "$auth_log"
  if [ "$rc" -ne 0 ]; then printf '%s\n\n' 'WARNING: gh unavailable or unauthenticated; merged pull requests not measured.'; return; fi
  if [ -z "$repos" ]; then printf '%s\n\n' 'none in window (no repository resolved).'; return; fi
  data=$(mktemp "${TMPDIR:-/tmp}/retro-evidence-prs.XXXXXX") || return
  : > "$data"
  while IFS= read -r repo; do
    pr_data=$(mktemp "${TMPDIR:-/tmp}/retro-evidence-pr-json.XXXXXX") || continue
    gh pr list --repo "$repo" --state merged --limit 1000 --json number,title,createdAt,mergedAt,additions,deletions > "$pr_data" 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'WARNING: unable to read merged pull requests for %s (exit %s).\n' "$repo" "$rc"
    elif ! render_prs "$repo" "$pr_data" >> "$data"; then
      printf 'WARNING: unable to parse merged pull requests for %s.\n' "$repo"
    fi
    rm -f "$pr_data"
  done <<EOF
$repos
EOF
  if [ ! -s "$data" ]; then printf '%s\n\n' 'none in window.'; rm -f "$data"; return; fi
  printf '%s\n' '| Repo | Number | Title | Hours open | Lines changed |'
  printf '%s\n' '| --- | ---: | --- | ---: | ---: |'
  sed -n 's/^ROW\t//p' "$data"
  count=$(sed -n 's/^ROW\t//p' "$data" | wc -l | tr -d '[:space:]')
  median=$(sed -n 's/^HOURS\t//p' "$data" | sort -n | awk '{ values[NR]=$1 } END { if (NR % 2) printf "%.1f", values[(NR+1)/2]; else printf "%.1f", (values[NR/2]+values[NR/2+1])/2 }')
  printf '%s\n\n' "Rows: $count. Median hours open: $median."
  rm -f "$data"
}

ack_is_malformed() {
  local note=$1 rounds verdict blockers classes field
  for field in rounds verdict open_blockers classes user_decision; do [ "$(review_ack_field_count "$note" "$field")" -le 1 ] || return 0; done
  rounds=$(review_ack_field "$note" rounds); verdict=$(review_ack_field "$note" verdict)
  blockers=$(review_ack_field "$note" open_blockers); classes=$(review_ack_field "$note" classes)
  [ -n "$rounds" ] && [ -n "$verdict" ] && [ -n "$blockers" ] && [ -n "$classes" ] || return 0
  case "$rounds" in *[!0-9]*) return 0 ;; esac
  case "$blockers" in *[!0-9]*) return 0 ;; esac
  case "$verdict" in GO|NO-GO) return 1 ;; *) return 0 ;; esac
}

ack_has_field_syntax() {
  local note=$1 pattern
  pattern='(^|[[:space:]])(rounds|verdict|open_blockers|classes|user_decision)='
  [[ "$note" =~ $pattern ]]
}

ack_status() {
  local note=$1 stamp_day=$2 extra=$3
  if [ -n "$extra" ]; then printf '%s' 'malformed'; return; fi
  if ! ack_has_field_syntax "$note" && [ "$stamp_day" \< "$REVIEW_ACK_FIELD_CUTOVER" ]; then
    printf '%s' 'legacy'
  elif ack_is_malformed "$note"; then
    printf '%s' 'malformed'
  else
    printf '%s' 'ok'
  fi
}

emit_acks() {
  local rows path gate sha stamp note extra stamp_day rounds verdict blockers classes decision decision_cell status count=0 ok_count=0 legacy_count=0 malformed_count=0 max_rounds=0 over_three=0 no_go=0
  printf '%s\n' '## Branch-review acknowledgements'
  rows=$(mktemp "${TMPDIR:-/tmp}/retro-evidence-acks.XXXXXX") || return
  : > "$rows"
  if [ -z "$ack_paths" ]; then printf '%s\n\n' 'none in window (no acknowledgement ledgers provided).'; rm -f "$rows"; return; fi
  while IFS= read -r path; do
    if [ ! -f "$path" ]; then printf 'WARNING: acknowledgement ledger missing: %s\n' "$path"; continue; fi
    while IFS="$(printf '\t')" read -r gate sha stamp note extra; do
      [ "$gate" = 'branch-review' ] || continue
      stamp_day=${stamp%%T*}
      case "$stamp" in ????-??-??T*) ;; *) count=$((count + 1)); malformed_count=$((malformed_count + 1)); printf '| %s | %s | malformed |  |  |  |  | malformed |\n' "$(md_cell "$sha")" "$(md_cell "$stamp")" >> "$rows"; continue ;; esac
      if [ "$stamp_day" \< "$start_day" ] || [ "$stamp_day" \> "$end_day" ]; then continue; fi
      count=$((count + 1))
      status=$(ack_status "$note" "$stamp_day" "$extra")
      case "$status" in
        legacy)
          legacy_count=$((legacy_count + 1))
          printf '| %s | %s |  |  |  |  |  | legacy |\n' "$(md_cell "$sha")" "$(md_cell "$stamp")" >> "$rows"
          continue
          ;;
        malformed)
          malformed_count=$((malformed_count + 1))
          printf '| %s | %s |  |  |  |  |  | malformed |\n' "$(md_cell "$sha")" "$(md_cell "$stamp")" >> "$rows"
          continue
          ;;
      esac
      ok_count=$((ok_count + 1))
      rounds=$(review_ack_field "$note" rounds); verdict=$(review_ack_field "$note" verdict)
      blockers=$(review_ack_field "$note" open_blockers); classes=$(review_ack_field "$note" classes); decision=$(review_ack_field "$note" user_decision)
      [ -n "$decision" ] && decision_cell=yes || decision_cell=no
      [ "$rounds" -gt "$max_rounds" ] && max_rounds=$rounds
      [ "$rounds" -gt 3 ] && over_three=$((over_three + 1))
      [ "$verdict" = 'NO-GO' ] && no_go=$((no_go + 1))
      printf '| %s | %s | %s | %s | %s | %s | %s | ok |\n' "$(md_cell "$sha")" "$(md_cell "$stamp")" "$rounds" "$verdict" "$blockers" "$(md_cell "$classes")" "$decision_cell" >> "$rows"
    done < "$path"
  done <<EOF
$ack_paths
EOF
  if [ "$count" -eq 0 ]; then printf '%s\n\n' 'none in window.'; rm -f "$rows"; return; fi
  printf '%s\n' '| SHA | Recorded at | Rounds | Verdict | Open blockers | Classes | User decision | Status |'
  printf '%s\n' '| --- | --- | ---: | --- | ---: | --- | --- | --- |'
  cat "$rows"
  printf '%s\n' 'Aggregate metrics (max rounds, over 3 rounds, NO-GO) are computed over ok rows only.'
  [ "$legacy_count" -eq 0 ] || printf '%s\n' 'Legacy rows predate the field format and carry no machine comparison.'
  printf '%s\n\n' "Summary: $count acks ($ok_count ok, $legacy_count legacy, $malformed_count malformed); max rounds: $max_rounds; over 3 rounds: $over_three; NO-GO: $no_go."
  rm -f "$rows"
}

emit_counters() {
  local report output rc
  printf '%s\n' '## Loop and routing counters'
  for report in loop-report routing-report; do
    printf '%s\n' "### ${report%-report} report"
    if [ -n "$since" ]; then output=$(bash "$script_root/scripts/$report.sh" --since "$since" 2>&1); else output=$(bash "$script_root/scripts/$report.sh" --days "$days" 2>&1); fi
    rc=$?
    if [ -n "$output" ]; then printf '%s\n' "$output"; else printf '%s\n' 'none in window.'; fi
    [ "$rc" -eq 0 ] || printf 'WARNING: %s.sh exited %s.\n' "$report" "$rc"
  done
  printf '\n'
}

emit_changes() {
  local changes sha date subject dirs
  printf '%s\n' '## Harness changes in the window'
  changes=$(mktemp "${TMPDIR:-/tmp}/retro-evidence-changes.XXXXXX") || return
  git -C "$repo_root" log --since="$start" --format='%h%x09%as%x09%s' -- rules global agents hooks scripts > "$changes"
  if [ ! -s "$changes" ]; then printf '%s\n\n' 'none in window.'; rm -f "$changes"; return; fi
  printf '%s\n' '| SHA | Date | Subject | Touched dirs |'
  printf '%s\n' '| --- | --- | --- | --- |'
  while IFS="$(printf '\t')" read -r sha date subject; do
    dirs=$(git -C "$repo_root" diff-tree --no-commit-id --name-only -r "$sha" -- rules global agents hooks scripts | awk -F/ 'NF { seen[$1]=1 } END { sep=""; for (dir in seen) { printf "%s%s", sep, dir; sep=", " } }')
    printf '| %s | %s | %s | %s |\n' "$sha" "$date" "$(md_cell "$subject")" "$(md_cell "$dirs")"
  done < "$changes"
  rm -f "$changes"
  printf '\n'
}

emit_not_measured() {
  printf '%s\n' '## Not measured'
  printf '%s\n' '- token or dollar cost' '- whether a review round was useful' '- causality between any change and any metric' '- whether ledger claims ("fresh reviewer", "negative control ran") were replayed' '- acknowledgements recorded before the field cutover are not machine-comparable'
}

emit_report() { emit_window; emit_prs; emit_acks; emit_counters; emit_changes; emit_not_measured; }

if [ -n "$out" ]; then emit_report > "$out" || exit 1; printf '%s\n' "$out"; else emit_report; fi
