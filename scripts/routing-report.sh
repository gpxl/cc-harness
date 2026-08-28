#!/usr/bin/env bash
# Measure observed Codex-first routing from Claude Code transcript text.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/routing-report.sh [--days N] [--since YYYY-MM-DD] [--json]' >&2
}

days=1
since=''
json=false
report_root="${ROUTING_REPORT_ROOT:-${HOME:-}/.claude/projects}"
reference=''
file_list=''

cleanup() {
  [ -z "$reference" ] || rm -f "$reference"
  [ -z "$file_list" ] || rm -f "$file_list"
}
trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --days)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      days="$2"
      shift 2
      ;;
    --since)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      since="$2"
      shift 2
      ;;
    --json)
      json=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

case "$days" in
  ''|*[!0-9]*|0) usage; exit 64 ;;
esac

if [ -n "$since" ]; then
  case "$since" in
    ????-??-??) ;;
    *) usage; exit 64 ;;
  esac
  reference=$(mktemp "${TMPDIR:-/tmp}/routing-report-reference.XXXXXX") || exit 1
  since_stamp=$(printf '%s' "$since" | tr -d '-')0000
  if ! touch -t "$since_stamp" "$reference"; then
    printf 'Invalid --since date: %s\n' "$since" >&2
    exit 64
  fi
  window_label="since $since"
else
  window_label="last $days day(s)"
fi

file_list=$(mktemp "${TMPDIR:-/tmp}/routing-report-files.XXXXXX") || exit 1
if [ -d "$report_root" ]; then
  if [ -n "$since" ]; then
    find "$report_root" -type f -name '*.jsonl' -newer "$reference" -print0 > "$file_list"
  else
    find "$report_root" -type f -name '*.jsonl' -mtime "-$days" -print0 > "$file_list"
  fi
fi

files_scanned=0
while IFS= read -r -d '' transcript; do
  files_scanned=$((files_scanned + 1))
done < "$file_list"

count_ereg() {
  local pattern="$1"
  local matches count
  matches=$(mktemp "${TMPDIR:-/tmp}/routing-report-matches.XXXXXX") || return 1
  xargs -0 grep -Eho "$pattern" < "$file_list" > "$matches" 2>/dev/null || true
  count=$(wc -l < "$matches")
  rm -f "$matches"
  printf '%s\n' "$(printf '%s' "$count" | tr -d '[:space:]')"
}

count_fixed() {
  local phrase="$1"
  local matches count
  matches=$(mktemp "${TMPDIR:-/tmp}/routing-report-matches.XXXXXX") || return 1
  xargs -0 grep -Fho "$phrase" < "$file_list" > "$matches" 2>/dev/null || true
  count=$(wc -l < "$matches")
  rm -f "$matches"
  printf '%s\n' "$(printf '%s' "$count" | tr -d '[:space:]')"
}

print_text() {
  printf 'Window: %s\n' "$window_label"
  printf 'Files scanned: %s\n' "$files_scanned"
  if [ "$files_scanned" -eq 0 ]; then
    printf '%s\n' 'NO DATA'
    printf '%s\n' 'Counts are occurrence counts over transcript text, not a semantic audit.'
    return
  fi
  printf 'Codex delegations: %s\n' "$codex_delegations"
  printf 'Claude-side delegable subagents: %s\n' "$delegable_claude"
  printf 'Claude-side non-delegable subagents: %s\n' "$non_delegable_claude"
  printf 'Hook fires: %s\n' "$hook_fires"
  if [ "$denominator" -eq 0 ]; then
    printf '%s\n' 'Delegation rate: unknown (no delegable work seen; 0/0)'
  else
    printf 'Delegation rate: %s%% (%s/%s)\n' "$rate" "$codex_delegations" "$denominator"
  fi
  printf '%s\n' 'Counts are occurrence counts over transcript text, not a semantic audit.'
}

print_json() {
  if [ "$files_scanned" -eq 0 ]; then
    printf '{"window":"%s","files_scanned":0,"status":"NO DATA","footer":"Counts are occurrence counts over transcript text, not a semantic audit."}\n' "$window_label"
    return
  fi
  if [ "$denominator" -eq 0 ]; then
    printf '{"window":"%s","files_scanned":%s,"codex_delegations":%s,"claude_delegable_subagents":%s,"claude_non_delegable_subagents":%s,"hook_fires":%s,"delegation_rate":{"status":"unknown","percentage":null,"numerator":0,"denominator":0,"message":"no delegable work seen"},"footer":"Counts are occurrence counts over transcript text, not a semantic audit."}\n' "$window_label" "$files_scanned" "$codex_delegations" "$delegable_claude" "$non_delegable_claude" "$hook_fires"
    return
  fi
  printf '{"window":"%s","files_scanned":%s,"codex_delegations":%s,"claude_delegable_subagents":%s,"claude_non_delegable_subagents":%s,"hook_fires":%s,"delegation_rate":{"status":"known","percentage":%s,"numerator":%s,"denominator":%s},"footer":"Counts are occurrence counts over transcript text, not a semantic audit."}\n' "$window_label" "$files_scanned" "$codex_delegations" "$delegable_claude" "$non_delegable_claude" "$hook_fires" "$rate" "$codex_delegations" "$denominator"
}

if [ "$files_scanned" -eq 0 ]; then
  if [ "$json" = true ]; then
    print_json
  else
    print_text
  fi
  exit 2
fi

codex_rescues=$(count_ereg '"subagent_type"[[:space:]]*:[[:space:]]*"codex:codex-rescue"')
direct_companion_tasks=$(count_ereg '"tool_input"[[:space:]]*:[[:space:]]*\{[^}]*"command"[[:space:]]*:[[:space:]]*"[^"]*codex-companion\.mjs[^[:space:]]*[[:space:]]+task')
codex_delegations=$((codex_rescues + direct_companion_tasks))
delegable_claude=$(count_ereg '"subagent_type"[[:space:]]*:[[:space:]]*"(general-purpose|Explore|Plan)"')
non_delegable_claude=$(count_ereg '"subagent_type"[[:space:]]*:[[:space:]]*"(commit|code-quality|test-writer|pr-monitor|release|verification|statusline-setup)"')
hook_fires=$(count_fixed 'Under the Codex-first budget rule')
denominator=$((codex_delegations + delegable_claude))
rate=''
if [ "$denominator" -gt 0 ]; then
  rate=$(awk -v numerator="$codex_delegations" -v total="$denominator" 'BEGIN { printf "%.1f", (numerator * 100) / total }')
fi

if [ "$json" = true ]; then
  print_json
else
  print_text
fi
