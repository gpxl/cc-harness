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
  claude-sonnet-5-5
  claude-sonnet-5-5
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

# Plan classification is MARKER-GATED. A plan is mechanical only when the planner wrote exactly
# one "Work class: mechanical" line (outside code fences) AND the plan survives two checks that
# can only force build: a veto (any architecture or build signal anywhere in the plan) and an
# anchored step grammar (every non-heading, non-context, non-verification step must match one of
# a few mechanical forms in full). Presence-based keyword guessing is open by construction, so no
# keyword list decides "mechanical"; no marker means build. Negation ("no architecture change")
# is deliberately not handled: over-escalating is the safe direction.
MODEL_ROUTING_BUILD_SIGNALS='implement|fix|bug|refactor|feature|design|persistence|debug|root cause|race condition|investigate|rewrite|rewritten|algorithm|migrat|schema|column|read-path|replace|switch|overhaul|extract|new (module|endpoint|service|layer|cache)|(^|[^a-z])(add|port)(s|ed|ing)?([^a-z]|$)|(add|write|new|failing) [a-z ]*tests?|logic|wir(e|ing)|integration|retry'
MODEL_ROUTING_ARCH_SIGNALS='(^|[^a-z])adrs?([^a-z]|$)|system design|architecture|novel abstraction|trade-?off'

# Classify one plan step: verify | mechanical | other. A step is verification only if the WHOLE
# step matches the anchored grammar; leftover text ("... after migrating callers") is "other".
model_routing_step_class() {
  local step="$1" pkg ver item_v items lockf tool sep verify_re target pair from to
  step=$(printf '%s' "$step" | sed -E 's/^(then|and|finally) //')
  tool='(yarn |npm run |pnpm )?(lint|typecheck|build|tests?|ci)'
  sep='(, and |, | and )'
  verify_re="^(verify|run|confirm)( with)? (the )?${tool}(${sep}(the )?${tool})*( to confirm)?$"
  if printf '%s' "$step" | grep -Eq "$verify_re"; then
    printf '%s\n' verify; return 0
  fi
  pkg='(@[a-z0-9-]+/)?[a-z0-9][a-z0-9._-]*'
  ver='v?[0-9][0-9a-z.*^~-]*'
  # A bump item names the package AND its target version; bare words are not packages.
  item_v="(the )?${pkg}( (from )?${ver} (to|->) ${ver}| to ${ver})"
  items="${item_v}(( and |, | and the |, and )${item_v})*( \(patch\))?"
  lockf='(yarn\.lock|package-lock\.json|pnpm-lock\.yaml|lockfiles?)'
  # Edit targets are a single path-like token plus an optional closed noun: no verbs or clauses.
  target='[a-z0-9_./-]+( (docs|documentation|page|file|files|comments))?'
  rename_re='^rename (the )?[a-z0-9_-]+( to [a-z0-9_-]+)?$'
  if printf '%s' "$step" | grep -Eq "^bump ${items}$"; then
    # A major-version change needs code changes: build, not mechanical.
    for pair in $(printf '%s' "$step" | grep -Eo "${ver} (to|->) ${ver}" | sed -E 's/ (to|->) /@/'); do
      from=${pair%%@*}; to=${pair#*@}
      from=${from#v}; to=${to#v}
      [ "${from%%.*}" = "${to%%.*}" ] || { printf '%s\n' other; return 0; }
    done
    printf '%s\n' mechanical; return 0
  fi
  if printf '%s' "$step" | grep -Eq "^bump (all |the )?((three|two|four|five|vulnerable|affected|flagged|[0-9]+) )?(packages|dependencies|deps)( to (their|the latest) (patch|minor) versions?)?$|^bump (the )?(patch|minor) versions of ${pkg}( and ${pkg})?$|^apply (the )?patch-level (version )?(bumps|updates)$|^(regenerate|refresh|delete|remove)( the)?( (stale|unused|old))? ${lockf}( and ${lockf})*( files?)?( after the (dependabot )?bump)?$|^(run )?(yarn|npm|pnpm) (install|update)$|^(run )?yarn up -r( ${pkg})?( on the vulnerable packages)?$|^fix (a |the |some )?(typos?|formatting)( in (the )?${target})?$|^update (the )?copy on (the )?[a-z0-9-]+( page)?$|${rename_re}"; then
    printf '%s\n' mechanical; return 0
  fi
  printf '%s\n' other
}

# A step that does not match whole may be a comma list of steps ("delete lockfiles, run yarn
# install, verify with lint"): each piece must itself be verification or mechanical.
model_routing_step_or_clauses_class() {
  local step="$1" class piece any_mech=0
  class=$(model_routing_step_class "$step")
  if [ "$class" != other ]; then printf '%s\n' "$class"; return 0; fi
  case "$step" in *', '*) ;; *) printf '%s\n' other; return 0 ;; esac
  while IFS= read -r piece; do
    piece=$(printf '%s' "$piece" | sed -E 's/^[[:space:]]+//')
    class=$(model_routing_step_class "$piece")
    [ "$class" != other ] || { printf '%s\n' other; return 0; }
    [ "$class" = mechanical ] && any_mech=1
  done <<EOF4
$(printf '%s' "$step" | awk '{ gsub(/, /, "\n"); print }')
EOF4
  if [ "$any_mech" = 1 ]; then printf '%s\n' mechanical; else printf '%s\n' verify; fi
}

# Classify an approved plan's text by difficulty: architecture | build | mechanical.
# Hidden or unchecked text fails closed: any code fence, any heading or colon line outside a
# closed benign list, and any context prose outside a closed sentence form all force build.
model_routing_classify_plan() {
  local text line body kept='' markers=0 mech_markers=0 mech_steps=0
  local step class marker_re benign title_words ctx_re
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '\r')
  [ -n "$text" ] || { printf '%s\n' build; return 0; }
  if printf '%s' "$text" | grep -Eq "$MODEL_ROUTING_ARCH_SIGNALS"; then
    printf '%s\n' architecture; return 0
  fi
  # Fenced content is unchecked text; an unclosed fence hides everything after it.
  if printf '%s' "$text" | grep -Eq '^[[:space:]]*(```|~~~)'; then
    printf '%s\n' build; return 0
  fi
  marker_re='^[[:space:]]*(\*\*)?work class:(\*\*)?[[:space:]]*mechanical[[:space:]]*$'
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -Eq '^[[:space:]]*(\*\*)?work class:'; then
      markers=$((markers + 1))
      printf '%s' "$line" | grep -Eq "$marker_re" && mech_markers=$((mech_markers + 1))
      continue
    fi
    kept="${kept}${line}
"
  done <<EOF
$text
EOF
  [ "$markers" = 1 ] && [ "$mech_markers" = 1 ] || { printf '%s\n' build; return 0; }
  # Veto: any build signal anywhere in the plan, context included, forces build.
  # The one exempt phrasing is a typo/formatting fix, which is a copy edit, not a bug fix.
  if printf '%s' "$kept" | sed -E 's/fix(es)? (a |the |some )?(typos?|formatting)/ /g' | grep -Eq "$MODEL_ROUTING_BUILD_SIGNALS"; then
    printf '%s\n' build; return 0
  fi
  benign='^(plan|steps?|context|summary|background|verification|overview|changes)$'
  title_words='(patch|minor|security|dependency|dependencies|lockfile|lockfiles|version|versions|update|updates|bump|bumps|copy|typo|typos|rename|renames|cleanup|refresh|and|of|for)'
  ctx_re='^(dependabot|renovate) (flagged|reported|opened)( (three|two|four|five|several|[0-9]+|patch|minor|patch-level|security|dependency|dependencies|updates?|alerts?|vulnerabilities|advisories|in|the|web|monorepo|repo|repository|for|and))+\.?$'
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -n "$line" ] || continue
    case "$line" in
      '#'*)
        body=$(printf '%s' "$line" | sed -E 's/^#+[[:space:]]*//')
        printf '%s' "$body" | grep -Eq "$benign|^plan: ${title_words}( ${title_words}){0,5}\$" || { printf '%s\n' build; return 0; }
        continue ;;
      *:)
        body=${line%:}
        printf '%s' "$body" | grep -Eq "$benign" || { printf '%s\n' build; return 0; }
        continue ;;
    esac
    line=$(printf '%s' "$line" | sed -E 's/^([-*]|[0-9]+[.)])[[:space:]]+//; s/^plan: //')
    printf '%s' "$line" | grep -Eq "$ctx_re" && continue
    while IFS= read -r step; do
      step=$(printf '%s' "$step" | sed -E 's/^[[:space:]]+//; s/[.[:space:]]+$//')
      [ -n "$step" ] || continue
      class=$(model_routing_step_or_clauses_class "$step")
      [ "$class" = verify ] && continue
      [ "$class" = mechanical ] || { printf '%s\n' build; return 0; }
      mech_steps=$((mech_steps + 1))
    done <<EOF2
$(printf '%s' "$line" | awk '{ gsub(/(; | — |\. )/, "\n"); print }')
EOF2
  done <<EOF3
$kept
EOF3
  if [ "$mech_steps" -gt 0 ]; then printf '%s\n' mechanical
  else printf '%s\n' build
  fi
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
