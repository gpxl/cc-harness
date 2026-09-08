#!/usr/bin/env bash
# PostToolUse hook (matcher: ExitPlanMode). The plan-to-build transition is a
# Codex-first gate, not a request to change the Claude session model.
set -euo pipefail
trap 'exit 0' ERR

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
data_file="$root/model-routing-table.sh"
if [ ! -r "$data_file" ] || ! . "$data_file" || ! model_routing_table_valid; then
  exit 0
fi

build_index=$(model_routing_index_for_key build) || exit 0
fallback_ids=()
fallback_count=0
for ((index = 0; index < ${#MODEL_ROUTING_KEYS[@]}; index++)); do
  for fallback in ${MODEL_ROUTING_CLAUDE_FALLBACKS[$index]}; do
    seen=0
    for ((fallback_index = 0; fallback_index < fallback_count; fallback_index++)); do
      [ "${fallback_ids[$fallback_index]}" = "$fallback" ] && seen=1
    done
    if [ "$seen" -eq 0 ]; then
      fallback_ids[$fallback_count]="$fallback"
      fallback_count=$((fallback_count + 1))
    fi
  done
done
fallback_text=''
for ((index = 0; index < fallback_count; index++)); do
  if [ "$index" -eq 0 ]; then
    fallback_text="${fallback_ids[$index]}"
  elif [ "$index" -eq $((fallback_count - 1)) ]; then
    fallback_text="$fallback_text, and ${fallback_ids[$index]}"
  else
    fallback_text="$fallback_text, ${fallback_ids[$index]}"
  fi
done
context="MODEL ROUTING GATE (~/.claude/CLAUDE.md, mismatch protocol): the plan was just approved, so the work type is ${MODEL_ROUTING_LABELS[$build_index]}. STOP before implementing and delegate through /codex:rescue: use ${MODEL_ROUTING_CODEX[$build_index]} at ${MODEL_ROUTING_EFFORT[$build_index]} effort. Check both axes: (1) is Codex-delegable work about to be done inline anyway? (2) for work that is genuinely irreducible in Claude, does the session/subagent model match the fallback column? On a mismatch, STOP: delegate to Codex, ask the user to run /model <correct-id>, or use an explicit model override. Never proceed inline after merely mentioning the mismatch. Current Claude fallback ids are $fallback_text; they apply only when Codex is genuinely unavailable."
case "$context" in
  *\"*|*\\*|*"$MODEL_ROUTING_NEWLINE"*) exit 0 ;;
esac
printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"$context\"}}"
