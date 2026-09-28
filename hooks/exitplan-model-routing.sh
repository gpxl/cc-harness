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
primary=$(model_routing_primary_vendor_index) || exit 0
vendor=${MODEL_ROUTING_VENDORS[$primary]}
build_models=$(model_routing_models "$primary" "$build_index")
disabled=$(model_routing_disabled_vendors)
if [ "$vendor" = anthropic ]; then
  context="MODEL ROUTING GATE (~/.claude/CLAUDE.md, mismatch protocol): the plan was just approved, so the work type is ${MODEL_ROUTING_LABELS[$build_index]}. Disabled vendors in the vendor switch (bash ~/.claude/hooks/vendors.sh): $disabled. Do NOT dispatch /codex:rescue or any other disabled vendor's route. Implement in Claude on ${build_models// / then } at ${MODEL_ROUTING_EFFORT[$build_index]} effort. Check that the session/subagent model matches; on a mismatch, STOP: ask the user to run /model <correct-id> or use an explicit Agent model override. Never proceed inline on the wrong model after merely mentioning the mismatch."
else
  fallback_text=''
  for ((vendor_index = primary + 1; vendor_index < ${#MODEL_ROUTING_VENDORS[@]}; vendor_index++)); do
    vendor_enabled "${MODEL_ROUTING_VENDORS[$vendor_index]}" || continue
    for ((index = 0; index < ${#MODEL_ROUTING_KEYS[@]}; index++)); do
      for fallback in $(model_routing_models "$vendor_index" "$index"); do
        case " $fallback_text " in *" $fallback, "*|*" $fallback "*) continue ;; esac
        fallback_text="${fallback_text:+$fallback_text, }$fallback"
      done
    done
  done
  context="MODEL ROUTING GATE (~/.claude/CLAUDE.md, mismatch protocol): the plan was just approved, so the work type is ${MODEL_ROUTING_LABELS[$build_index]}. STOP before implementing and delegate to $vendor through ${MODEL_ROUTING_VENDOR_ROUTES[$primary]}: use ${build_models// / then } at ${MODEL_ROUTING_EFFORT[$build_index]} effort. Check both axes: (1) is delegable work about to be done inline anyway? (2) for work that is genuinely irreducible in Claude, does the session/subagent model match the fallback column? On a mismatch, STOP: delegate, ask the user to run /model <correct-id>, or use an explicit model override. Never proceed inline after merely mentioning the mismatch. Current fallback ids are ${fallback_text:-none}; they apply only when $vendor is genuinely unavailable. Disabled vendors: $disabled."
fi
case "$context" in
  *\"*|*\\*|*"$MODEL_ROUTING_NEWLINE"*) exit 0 ;;
esac
printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"$context\"}}"
