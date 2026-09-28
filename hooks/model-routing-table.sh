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
  gpt-6-sol
  gpt-6-luna
  gpt-6-luna
)
# Codex reasoning effort per tier (also what scripts/sync-codex-agents.sh writes into roles).
MODEL_ROUTING_EFFORT=(
  xhigh
  high
  medium
  low
)
# Claude effort per tier. Kept separate because effort names do not mean the same amount of
# thinking across models: Opus 5.5 at medium matches Opus 5 at high on coding, and thinks more
# per level (Anthropic's Opus 5.5 prompting guide). xhigh/max only where a gain was measured.
MODEL_ROUTING_CLAUDE_EFFORT=(
  high
  medium
  medium
  low
)
# Space-delimited because every fallback slug is a single shell word.
MODEL_ROUTING_CLAUDE_FALLBACKS=(
  'claude-fable-5-1 claude-opus-5-5'
  claude-opus-5-5
  claude-sonnet-5
  claude-sonnet-5
)
MODEL_ROUTING_NEWLINE='
'

# Vendor columns in routing preference order. The first vendor that hooks/vendors.sh reports
# enabled is the PRIMARY route for every tier; a disabled vendor is never recommended. Adding a
# vendor: one MODEL_ROUTING_<COLUMN> array above, one entry in each array below, and one line in
# hooks/vendors.conf. anthropic stays last: it is the always-enabled floor.
MODEL_ROUTING_VENDORS=(
  openai
  anthropic
)
MODEL_ROUTING_VENDOR_COLUMNS=(
  MODEL_ROUTING_CODEX
  MODEL_ROUTING_CLAUDE_FALLBACKS
)
# Effort column for each vendor, parallel to MODEL_ROUTING_VENDOR_COLUMNS.
MODEL_ROUTING_VENDOR_EFFORT_COLUMNS=(
  MODEL_ROUTING_EFFORT
  MODEL_ROUTING_CLAUDE_EFFORT
)
MODEL_ROUTING_VENDOR_ROUTES=(
  /codex:rescue
  'Claude itself (the session model, or an Agent model: override)'
)

model_routing_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ -r "$model_routing_dir/vendors.sh" ]; then
  . "$model_routing_dir/vendors.sh"
fi

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

# Index into MODEL_ROUTING_VENDORS of the first enabled vendor.
# Fails when hooks/vendors.sh is absent: no resolver means no vendor may be recommended.
model_routing_primary_vendor_index() {
  local index
  command -v vendor_enabled >/dev/null 2>&1 || return 1
  for ((index = 0; index < ${#MODEL_ROUTING_VENDORS[@]}; index++)); do
    if vendor_enabled "${MODEL_ROUTING_VENDORS[$index]}"; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

# Space-separated model ids for <vendor index> <tier index>, most preferred first.
model_routing_models() {
  local ref="${MODEL_ROUTING_VENDOR_COLUMNS[$1]}[$2]"
  printf '%s\n' "${!ref}"
}

# Effort level for <vendor index> <tier index>.
model_routing_effort() {
  local ref="${MODEL_ROUTING_VENDOR_EFFORT_COLUMNS[$1]}[$2]"
  printf '%s\n' "${!ref}"
}

# Comma-separated list of disabled vendors, or "none".
model_routing_disabled_vendors() {
  local index text=''
  for ((index = 0; index < ${#MODEL_ROUTING_VENDORS[@]}; index++)); do
    if ! vendor_enabled "${MODEL_ROUTING_VENDORS[$index]}"; then
      text="${text:+$text, }${MODEL_ROUTING_VENDORS[$index]}"
    fi
  done
  printf '%s\n' "${text:-none}"
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
  [ "${#MODEL_ROUTING_CLAUDE_EFFORT[@]}" -eq 4 ] || return 1
  [ "${#MODEL_ROUTING_VENDOR_EFFORT_COLUMNS[@]}" -eq "${#MODEL_ROUTING_VENDORS[@]}" ] || return 1
  [ "${#MODEL_ROUTING_CLAUDE_FALLBACKS[@]}" -eq 4 ] || return 1
  [ "${#MODEL_ROUTING_VENDORS[@]}" -ge 1 ] || return 1
  [ "${#MODEL_ROUTING_VENDOR_COLUMNS[@]}" -eq "${#MODEL_ROUTING_VENDORS[@]}" ] || return 1
  [ "${#MODEL_ROUTING_VENDOR_ROUTES[@]}" -eq "${#MODEL_ROUTING_VENDORS[@]}" ] || return 1
  [ "${MODEL_ROUTING_VENDORS[$((${#MODEL_ROUTING_VENDORS[@]} - 1))]}" = anthropic ] || return 1
  for ((index = 0; index < ${#MODEL_ROUTING_VENDORS[@]}; index++)); do
    model_routing_value_is_json_safe "${MODEL_ROUTING_VENDORS[$index]}" || return 1
    model_routing_value_is_json_safe "${MODEL_ROUTING_VENDOR_ROUTES[$index]}" || return 1
    # Validated before the eval below: a column must be a plain MODEL_ROUTING_ identifier.
    case "${MODEL_ROUTING_VENDOR_COLUMNS[$index]}" in
      MODEL_ROUTING_*[!A-Z0-9_]*|MODEL_ROUTING_) return 1 ;;
      MODEL_ROUTING_*) ;;
      *) return 1 ;;
    esac
    eval "fallback=\${#${MODEL_ROUTING_VENDOR_COLUMNS[$index]}[@]}" 2>/dev/null || return 1
    [ "$fallback" = 4 ] || return 1
    case "${MODEL_ROUTING_VENDOR_EFFORT_COLUMNS[$index]}" in
      MODEL_ROUTING_*[!A-Z0-9_]*|MODEL_ROUTING_) return 1 ;;
      MODEL_ROUTING_*) ;;
      *) return 1 ;;
    esac
    eval "fallback=\${#${MODEL_ROUTING_VENDOR_EFFORT_COLUMNS[$index]}[@]}" 2>/dev/null || return 1
    [ "$fallback" = 4 ] || return 1
  done

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
    model_routing_value_is_json_safe "${MODEL_ROUTING_CLAUDE_EFFORT[$index]}" || return 1
    for fallback in ${MODEL_ROUTING_CLAUDE_FALLBACKS[$index]}; do
      model_routing_value_is_json_safe "$fallback" || return 1
    done
  done
}
