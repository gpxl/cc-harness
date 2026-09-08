#!/usr/bin/env bash
# Hermetic behavioral checks for native Codex role generation, installation, and project health.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
generator="$root/scripts/sync-codex-agents.sh"
checker="$root/scripts/codex-routing-check.sh"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/cc-harness-codex-routing.XXXXXX") || exit 1
failures=0
completed=0
trap 'st=$?; rm -rf "$tmp_root"; [ "$completed" = 1 ] || st=1; exit $st' EXIT HUP INT TERM

fail() { printf '%s\n' "$*" >&2; return 1; }
record() { "$@" || failures=$((failures + 1)); return 0; }

roles=(harness_explorer harness_runner harness_worker harness_analyst harness_reviewer)

roles_follow_routing_table() {
  local probe build architecture
  # shellcheck source=hooks/model-routing-table.sh
  . "$root/hooks/model-routing-table.sh"
  probe=$(model_routing_index_for_key probe) || return 1
  build=$(model_routing_index_for_key build) || return 1
  architecture=$(model_routing_index_for_key architecture) || return 1
  "$generator" --check || return 1
  grep -Fqx "model = \"${MODEL_ROUTING_CODEX[$probe]}\"" "$root/codex/agents/harness_explorer.toml" || return 1
  grep -Fqx "model_reasoning_effort = \"${MODEL_ROUTING_EFFORT[$probe]}\"" "$root/codex/agents/harness_runner.toml" || return 1
  grep -Fqx "model = \"${MODEL_ROUTING_CODEX[$build]}\"" "$root/codex/agents/harness_worker.toml" || return 1
  grep -Fqx "model = \"${MODEL_ROUTING_CODEX[$architecture]}\"" "$root/codex/agents/harness_analyst.toml" || return 1
  grep -Fqx 'sandbox_mode = "read-only"' "$root/codex/agents/harness_reviewer.toml"
}

stale_generated_output_is_rejected() {
  local fixture_table="$tmp_root/model-routing-table.sh" build build_model
  local generated="$tmp_root/generated"
  # shellcheck source=hooks/model-routing-table.sh
  . "$root/hooks/model-routing-table.sh"
  build=$(model_routing_index_for_key build) || return 1
  build_model=${MODEL_ROUTING_CODEX[$build]}
  cp "$root/hooks/model-routing-table.sh" "$fixture_table" || return 1
  "$generator" --routing-table "$fixture_table" --output-dir "$generated" || return 1
  sed -i.bak "s/$build_model/gpt-test-terra/" "$fixture_table" || return 1
  if "$generator" --check --routing-table "$fixture_table" --output-dir "$generated" >"$tmp_root/stale.out" 2>&1; then
    return 1
  fi
  grep -F 'stale generated role' "$tmp_root/stale.out" >/dev/null
}

missing_role_template_is_rejected() {
  local templates="$tmp_root/templates"
  cp -R "$root/codex/agent-templates" "$templates" || return 1
  rm "$templates/harness_worker.toml.in" || return 1
  if "$generator" --check --templates-dir "$templates" >"$tmp_root/missing-template.out" 2>&1; then
    return 1
  fi
  grep -F 'missing role template' "$tmp_root/missing-template.out" >/dev/null
}

install_is_idempotent_and_preserves_personal_state() {
  local home="$tmp_root/home"
  local claude="$home/.claude"
  local codex="$home/.codex"
  local role
  mkdir -p "$claude" "$codex/agents" || return 1
  printf '%s\n' 'personal instructions' > "$codex/AGENTS.md" || return 1
  printf '%s\n' 'personal config' > "$codex/config.toml" || return 1
  printf '%s\n' 'private agent' > "$codex/agents/private.toml" || return 1
  HOME="$home" CC_HARNESS_CLAUDE_DIR="$claude" CC_HARNESS_CODEX_DIR="$codex" bash "$root/install.sh" >"$tmp_root/install.out" 2>&1 || return 1
  [ -L "$codex/AGENTS.md" ] && [ "$(readlink "$codex/AGENTS.md")" = "$root/global/CLAUDE.md" ] || return 1
  for role in "${roles[@]}"; do
    [ -L "$codex/agents/$role.toml" ] && [ "$(readlink "$codex/agents/$role.toml")" = "$root/codex/agents/$role.toml" ] || return 1
  done
  cmp -s <(printf '%s\n' 'personal config') "$codex/config.toml" || return 1
  cmp -s <(printf '%s\n' 'private agent') "$codex/agents/private.toml" || return 1
  HOME="$home" CC_HARNESS_CLAUDE_DIR="$claude" CC_HARNESS_CODEX_DIR="$codex" bash "$root/install.sh" >"$tmp_root/install-repeat.out" 2>&1 || return 1
  "$checker" --codex-dir "$codex" >"$tmp_root/installed-check.out" 2>&1 || return 1
  HOME="$home" CC_HARNESS_CLAUDE_DIR="$claude" CC_HARNESS_CODEX_DIR="$codex" bash "$root/uninstall.sh" >"$tmp_root/uninstall.out" 2>&1 || return 1
  [ ! -L "$codex/AGENTS.md" ] || return 1
  cmp -s <(printf '%s\n' 'personal instructions') "$codex/AGENTS.md" || return 1
  [ -f "$codex/agents/private.toml" ] && cmp -s <(printf '%s\n' 'private agent') "$codex/agents/private.toml" || return 1
  [ -f "$codex/config.toml" ] && cmp -s <(printf '%s\n' 'personal config') "$codex/config.toml" || return 1
  for role in "${roles[@]}"; do [ ! -e "$codex/agents/$role.toml" ] || return 1; done
}

role_collision_causes_no_partial_install() {
  local home="$tmp_root/collision-home"
  local claude="$home/.claude"
  local codex="$home/.codex"
  mkdir -p "$claude" "$codex/agents" || return 1
  printf '%s\n' 'do not replace' > "$codex/agents/harness_worker.toml" || return 1
  if HOME="$home" CC_HARNESS_CLAUDE_DIR="$claude" CC_HARNESS_CODEX_DIR="$codex" bash "$root/install.sh" >"$tmp_root/collision.out" 2>&1; then
    return 1
  fi
  grep -F 'Codex managed target conflict' "$tmp_root/collision.out" >/dev/null || return 1
  [ ! -e "$codex/AGENTS.md" ] && [ ! -e "$codex/agents/harness_explorer.toml" ]
}

foreign_symlinks_are_restored_or_left_alone() {
  local home="$tmp_root/foreign-home"
  local claude="$home/.claude"
  local codex="$home/.codex"
  local prior="$tmp_root/prior-agents.md"
  local replacement="$tmp_root/replacement-worker.toml"
  mkdir -p "$claude" "$codex/agents" || return 1
  printf '%s\n' 'prior instructions' > "$prior" || return 1
  printf '%s\n' 'replacement worker' > "$replacement" || return 1
  ln -s "$prior" "$codex/AGENTS.md" || return 1
  HOME="$home" CC_HARNESS_CLAUDE_DIR="$claude" CC_HARNESS_CODEX_DIR="$codex" bash "$root/install.sh" >"$tmp_root/foreign-install.out" 2>&1 || return 1
  rm "$codex/agents/harness_worker.toml" || return 1
  ln -s "$replacement" "$codex/agents/harness_worker.toml" || return 1
  HOME="$home" CC_HARNESS_CLAUDE_DIR="$claude" CC_HARNESS_CODEX_DIR="$codex" bash "$root/uninstall.sh" >"$tmp_root/foreign-uninstall.out" 2>&1 || return 1
  [ -L "$codex/AGENTS.md" ] && [ "$(readlink "$codex/AGENTS.md")" = "$prior" ] || return 1
  [ -L "$codex/agents/harness_worker.toml" ] && [ "$(readlink "$codex/agents/harness_worker.toml")" = "$replacement" ]
}

project_shadow_and_link_drift_are_reported() {
  local home="$tmp_root/check-home"
  local codex="$home/.codex"
  local project="$tmp_root/project"
  mkdir -p "$codex/agents" "$project/.codex/agents" || return 1
  printf '%s\n' '# project instructions' > "$project/AGENTS.md" || return 1
  printf '%s\n' 'name = "explorer"' > "$project/.codex/agents/explorer.toml" || return 1
  printf '%s\n' '[agents]' > "$project/.codex/config.toml" || return 1
  if "$checker" --codex-dir "$codex" --project "$project" >"$tmp_root/check.out" 2>&1; then
    return 1
  fi
  grep -F 'missing managed role link' "$tmp_root/check.out" >/dev/null || return 1
  grep -F 'legacy project role copy' "$tmp_root/check.out" >/dev/null || return 1
}

record roles_follow_routing_table
record stale_generated_output_is_rejected
record missing_role_template_is_rejected
record install_is_idempotent_and_preserves_personal_state
record role_collision_causes_no_partial_install
record foreign_symlinks_are_restored_or_left_alone
record project_shadow_and_link_drift_are_reported

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'CODEX ROUTING SELFTEST: PASS'
  completed=1; exit 0
fi
printf '%s\n' 'CODEX ROUTING SELFTEST: FAIL'
completed=1; exit 1
