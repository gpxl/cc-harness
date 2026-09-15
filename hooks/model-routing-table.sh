# Sourceable Model Routing data for hooks. Bash 3.2-compatible: parallel arrays only.

MODEL_ROUTING_KEYS=(
  architecture
  build
  probe
  mechanical
)
MODEL_ROUTING_LABELS=(
  architecture/design
  build/implementation
  probe/exploration
  mechanical
)
MODEL_ROUTING_DESCRIPTIONS=(
  'ADRs, system design, novel abstractions, hard trade-offs'
  'coding, refactors, tests, eval scenarios, debugging'
  'codebase surveys, read-only investigation, light passes'
  'precise known-outcome small UI edits, refactors, fixes, focused tests, and utilities with clear checks'
)
MODEL_ROUTING_CODEX=(
  gpt-6-astra
  gpt-5.6-terra
  gpt-5.6-luna
  gpt-5.3-codex-spark
)
MODEL_ROUTING_EFFORT=(
  xhigh
  high
  medium
  low
)
# Space-delimited because every fallback slug is a single shell word.
MODEL_ROUTING_CLAUDE_FALLBACKS=(
  'claude-fable-5-1 claude-opus-5'
  claude-opus-5
  claude-sonnet-5
  claude-sonnet-5
)
# Mentioned in the markdown table as the build tier's same-level sibling, but
# not selected as a routing tier.
MODEL_ROUTING_TABLE_REFERENCED_CODEX=(
  gpt-5.6-sol
)

MODEL_ROUTING_NEWLINE='
'

model_routing_index_for_key() {
  local sought="$1"
  local index
  for ((index = 0; index < ${#MODEL_ROUTING_KEYS[@]}; index++)); do
    if [ "${MODEL_ROUTING_KEYS[$index]}" = "$sought" ]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

model_routing_value_is_json_safe() {
  local value="$1"
  case "$value" in
    ''|*\"*|*\\*|*"$MODEL_ROUTING_NEWLINE"*) return 1 ;;
  esac
}

model_routing_table_valid() {
  local index fallback
  [ "${#MODEL_ROUTING_KEYS[@]}" -eq 4 ] || return 1
  [ "${#MODEL_ROUTING_LABELS[@]}" -eq 4 ] || return 1
  [ "${#MODEL_ROUTING_DESCRIPTIONS[@]}" -eq 4 ] || return 1
  [ "${#MODEL_ROUTING_CODEX[@]}" -eq 4 ] || return 1
  [ "${#MODEL_ROUTING_EFFORT[@]}" -eq 4 ] || return 1
  [ "${#MODEL_ROUTING_CLAUDE_FALLBACKS[@]}" -eq 4 ] || return 1

  for ((index = 0; index < ${#MODEL_ROUTING_KEYS[@]}; index++)); do
    case "${MODEL_ROUTING_KEYS[$index]}" in
      architecture|build|probe|mechanical) ;;
      *) return 1 ;;
    esac
    model_routing_value_is_json_safe "${MODEL_ROUTING_KEYS[$index]}" || return 1
    model_routing_value_is_json_safe "${MODEL_ROUTING_LABELS[$index]}" || return 1
    model_routing_value_is_json_safe "${MODEL_ROUTING_DESCRIPTIONS[$index]}" || return 1
    model_routing_value_is_json_safe "${MODEL_ROUTING_CODEX[$index]}" || return 1
    model_routing_value_is_json_safe "${MODEL_ROUTING_EFFORT[$index]}" || return 1
    for fallback in ${MODEL_ROUTING_CLAUDE_FALLBACKS[$index]}; do
      model_routing_value_is_json_safe "$fallback" || return 1
    done
  done
  for fallback in "${MODEL_ROUTING_TABLE_REFERENCED_CODEX[@]}"; do
    model_routing_value_is_json_safe "$fallback" || return 1
  done
}
