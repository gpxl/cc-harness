#!/usr/bin/env bash
# PostToolUse hook (matcher: Bash). Fires ONLY when the executed command actually
# invokes `bd ready`, injecting a reminder to tag each ready issue with a
# suggested model per the Model Routing policy in ~/.claude/CLAUDE.md.
#
# Self-gating: reads the tool input on stdin and exits silently unless the command
# is a `bd ready` invocation. This does NOT rely on the settings.json `if:` filter
# (which does not gate this hook in the installed Claude Code version) — the script
# is the source of truth for when the reminder appears.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
data_file="$root/model-routing-table.sh"

input=$(cat 2>/dev/null || printf '')

# Extract tool_input.command (first quoted value; a `bd ready` command has no
# inner quotes, so [^"]* captures it cleanly).
cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

# Match `bd ready` as a command token: at the start, or after a shell separator
# (; & |) or whitespace, and followed by whitespace or end. So `bd readyfoo`,
# `abd ready`, or an unrelated mention of the phrase does not trigger it.
if ! printf '%s' "$cmd" | grep -Eq '(^|[;&|]|[[:space:]])bd[[:space:]]+ready([[:space:]]|$)'; then
  exit 0
fi

if [ ! -r "$data_file" ] || ! . "$data_file" || ! model_routing_table_valid; then
  exit 0
fi

primary=$(model_routing_primary_vendor_index) || exit 0
vendor=${MODEL_ROUTING_VENDORS[$primary]}
context="Model Routing (~/.claude/CLAUDE.md): the primary route is $vendor via ${MODEL_ROUTING_VENDOR_ROUTES[$primary]} (vendor switch: bash ~/.claude/hooks/vendors.sh). Disabled vendors, never to be routed to: $(model_routing_disabled_vendors). For each issue listed by \`bd ready\`, suggest a model by its type/title: "
for ((index = 0; index < ${#MODEL_ROUTING_KEYS[@]}; index++)); do
  models=$(model_routing_models "$primary" "$index")
  context="$context${MODEL_ROUTING_LABELS[$index]} (${MODEL_ROUTING_DESCRIPTIONS[$index]}) -> ${models// / then } at ${MODEL_ROUTING_EFFORT[$index]}"
  if [ "$index" -lt $((${#MODEL_ROUTING_KEYS[@]} - 1)) ]; then
    context="$context; "
  fi
done
context="$context."
for ((vendor_index = primary + 1; vendor_index < ${#MODEL_ROUTING_VENDORS[@]}; vendor_index++)); do
  vendor_enabled "${MODEL_ROUTING_VENDORS[$vendor_index]}" || continue
  context="$context Fallback only when $vendor is genuinely unavailable: ${MODEL_ROUTING_VENDORS[$vendor_index]} ("
  for ((index = 0; index < ${#MODEL_ROUTING_KEYS[@]}; index++)); do
    models=$(model_routing_models "$vendor_index" "$index")
    context="$context${MODEL_ROUTING_KEYS[$index]} ${models// / then }"
    [ "$index" -lt $((${#MODEL_ROUTING_KEYS[@]} - 1)) ] && context="$context, "
  done
  context="$context)."
  break
done
context="$context This governs the dev-driving model, not any repo's EVAL_MODEL."
case "$context" in
  *\"*|*\\*|*"$MODEL_ROUTING_NEWLINE"*) exit 0 ;;
esac
printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"$context\"}}"
