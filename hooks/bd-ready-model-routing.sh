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

context='Model Routing (~/.claude/CLAUDE.md): /codex:rescue is the default delegation route. For each issue listed by `bd ready`, suggest a Codex model by its type/title: '
for ((index = 0; index < ${#MODEL_ROUTING_KEYS[@]}; index++)); do
  context="$context${MODEL_ROUTING_LABELS[$index]} (${MODEL_ROUTING_DESCRIPTIONS[$index]}) -> ${MODEL_ROUTING_CODEX[$index]} at ${MODEL_ROUTING_EFFORT[$index]}"
  if [ "$index" -lt $((${#MODEL_ROUTING_KEYS[@]} - 1)) ]; then
    context="$context; "
  fi
done
architecture_index=$(model_routing_index_for_key architecture) || exit 0
build_index=$(model_routing_index_for_key build) || exit 0
probe_index=$(model_routing_index_for_key probe) || exit 0
mechanical_index=$(model_routing_index_for_key mechanical) || exit 0
context="$context. The Claude column is fallback only when Codex is genuinely unavailable: ${MODEL_ROUTING_LABELS[$architecture_index]} ${MODEL_ROUTING_CLAUDE_FALLBACKS[$architecture_index]%% *} then ${MODEL_ROUTING_CLAUDE_FALLBACKS[$architecture_index]#* }, ${MODEL_ROUTING_KEYS[$build_index]} ${MODEL_ROUTING_CLAUDE_FALLBACKS[$build_index]}, ${MODEL_ROUTING_KEYS[$probe_index]}/${MODEL_ROUTING_KEYS[$mechanical_index]} ${MODEL_ROUTING_CLAUDE_FALLBACKS[$probe_index]}. This governs the dev-driving model, not any repo's EVAL_MODEL."
case "$context" in
  *\"*|*\\*|*"$MODEL_ROUTING_NEWLINE"*) exit 0 ;;
esac
printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"$context\"}}"
