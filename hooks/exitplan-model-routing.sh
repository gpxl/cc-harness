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

# The approved plan arrives as tool_input.plan on stdin; classify it by difficulty so
# mechanical work is not escalated to the build tier's model. Only a plan carrying the
# planner's 'Work class: mechanical' marker that also passes the veto and step grammar takes the
# cheaper tier; anything else stays on build.
plan_text=$(jq -r '.tool_input.plan // empty' 2>/dev/null || printf '')
work_class=$(model_routing_classify_plan "$plan_text")
tier_key=$work_class
build_index=$(model_routing_index_for_key "$tier_key") || exit 0
build_key_index=$(model_routing_index_for_key build) || exit 0
primary=$(model_routing_primary_vendor_index) || exit 0
vendor=${MODEL_ROUTING_VENDORS[$primary]}
build_models=$(model_routing_models "$primary" "$build_index")
build_effort=$(model_routing_effort "$primary" "$build_index")
disabled=$(model_routing_disabled_vendors)
escalation=''
if [ "$tier_key" = mechanical ]; then
  escalation_models=$(model_routing_models "$primary" "$build_key_index")
  escalation="Escalation trigger: move to ${escalation_models// / then } at $(model_routing_effort "$primary" "$build_key_index") effort only if a lint/typecheck/build/test failure needs real debugging or the plan turns out to need multi-file logic or design; scope that escalation to the step that needed it."
fi
marker_note=''
if [ "$tier_key" != mechanical ]; then
  marker_note="Planning note: the mechanical tier is opt-in. A plan gets it only when the planner wrote the line 'Work class: mechanical', and the planner should write it only for lockfile, dependency-patch, copy or rename style work with a known outcome and an easy check, and omit it otherwise; an unmarked plan is build."
fi
if [ "$vendor" = anthropic ] && [ "$tier_key" = mechanical ]; then
  context="MODEL ROUTING GATE (~/.claude/CLAUDE.md, mismatch protocol): the plan was just approved and reads as ${work_class} work, so the tier is ${MODEL_ROUTING_LABELS[$build_index]}. Disabled vendors in the vendor switch (bash ~/.claude/hooks/vendors.sh): $disabled. Do NOT dispatch /codex:rescue or any other disabled vendor's route. Implement in Claude on ${build_models// / then } at $build_effort effort. A session already on that model is a MATCH, not a mismatch: do NOT stop or ask the user to run /model. A more capable session model is also fine. Only a session below it (for example Haiku) is a mismatch. On that mismatch, STOP: ask the user to run /model <id> or use an Agent model override. $escalation"
elif [ "$vendor" = anthropic ]; then
  context="MODEL ROUTING GATE (~/.claude/CLAUDE.md, mismatch protocol): the plan was just approved, so the work type is ${MODEL_ROUTING_LABELS[$build_index]}. Disabled vendors in the vendor switch (bash ~/.claude/hooks/vendors.sh): $disabled. Do NOT dispatch /codex:rescue or any other disabled vendor's route. Implement in Claude on ${build_models// / then } at $build_effort effort. Check that the session/subagent model matches; on a mismatch, STOP: ask the user to run /model <correct-id> or use an explicit Agent model override. Never proceed inline on the wrong model after merely mentioning the mismatch. $marker_note"
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
  context="MODEL ROUTING GATE (~/.claude/CLAUDE.md, mismatch protocol): the plan was just approved, and reads as ${work_class} work, so the work type is ${MODEL_ROUTING_LABELS[$build_index]}. STOP before implementing and delegate to $vendor through ${MODEL_ROUTING_VENDOR_ROUTES[$primary]}: use ${build_models// / then } at $build_effort effort. Check both axes: (1) is delegable work about to be done inline anyway? (2) for work that is genuinely irreducible in Claude, does the session/subagent model match the fallback column? On a mismatch, STOP: delegate, ask the user to run /model <correct-id>, or use an explicit model override. Never proceed inline after merely mentioning the mismatch. Current fallback ids are ${fallback_text:-none}; they apply only when $vendor is genuinely unavailable. Disabled vendors: $disabled. $escalation $marker_note"
  if [ "$vendor" = openai ]; then
    context="$context Before delegating, Read ~/.claude/rules/model-routing-codex.md (Codex-first mechanics) if it is not already loaded this session."
  fi
fi
case "$context" in
  *\"*|*\\*|*"$MODEL_ROUTING_NEWLINE"*) exit 0 ;;
esac
printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"$context\"}}"
