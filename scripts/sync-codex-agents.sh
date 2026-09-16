#!/usr/bin/env bash
# Render tracked native Codex roles from templates and the shared routing table.
set -euo pipefail

# Resolve the PHYSICAL script directory before taking its parent. Installed, this script is reached
# through ~/.claude/scripts, a symlink to the repository's scripts/: a logical `cd .../scripts/..`
# lands in ~/.claude, and every repository-relative path below then points at a directory that does
# not hold them (cch-u9w).
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
routing_table="$root/hooks/model-routing-table.sh"
output_dir="$root/codex/agents"
templates_dir="$root/codex/agent-templates"
check_only=0
expected_roles=(harness_explorer harness_runner harness_spark harness_worker harness_analyst harness_reviewer)

usage() {
  printf '%s\n' 'Usage: scripts/sync-codex-agents.sh [--check] [--routing-table <path>] [--templates-dir <path>] [--output-dir <path>]'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check_only=1 ;;
    --routing-table) routing_table="${2:?missing value for --routing-table}"; shift ;;
    --templates-dir) templates_dir="${2:?missing value for --templates-dir}"; shift ;;
    --output-dir) output_dir="${2:?missing value for --output-dir}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[ -f "$routing_table" ] || { printf 'routing table not found: %s\n' "$routing_table" >&2; exit 1; }
# shellcheck source=hooks/model-routing-table.sh
. "$routing_table"
model_routing_table_valid || { printf '%s\n' 'invalid model routing table' >&2; exit 1; }

[ -d "$templates_dir" ] || { printf 'role template directory not found: %s\n' "$templates_dir" >&2; exit 1; }
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/cc-harness-codex-agent-sync.XXXXXX") || exit 1
trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM
failures=0

render_template() {
  local template="$1"
  local destination="$2"
  local key index model effort
  key=$(sed -n 's/^# routing_key: \([a-z][a-z_]*\)$/\1/p' "$template")
  [ -n "$key" ] || { printf 'missing routing key: %s\n' "$template" >&2; return 1; }
  index=$(model_routing_index_for_key "$key") || { printf 'unknown routing key %s in %s\n' "$key" "$template" >&2; return 1; }
  model=${MODEL_ROUTING_CODEX[$index]}
  effort=${MODEL_ROUTING_EFFORT[$index]}
  model_routing_value_is_json_safe "$model" && model_routing_value_is_json_safe "$effort" || return 1
  sed -e "s|@@MODEL@@|$model|g" -e "s|@@EFFORT@@|$effort|g" "$template" > "$destination"
  if grep -F '@@' "$destination" >/dev/null; then
    printf 'unresolved template value: %s\n' "$template" >&2
    return 1
  fi
}

template_count=0
for template in "$templates_dir"/*.toml.in; do
  [ -f "$template" ] || continue
  template_count=$((template_count + 1))
  name=$(basename "$template" .toml.in)
  known=0
  for role in "${expected_roles[@]}"; do [ "$name" = "$role" ] && known=1; done
  [ "$known" -eq 1 ] || { printf 'unexpected role template: %s\n' "$template" >&2; failures=$((failures + 1)); }
done
[ "$template_count" -eq "${#expected_roles[@]}" ] || { printf 'incomplete role template catalog: expected %s, found %s\n' "${#expected_roles[@]}" "$template_count" >&2; failures=$((failures + 1)); }

for name in "${expected_roles[@]}"; do
  template="$templates_dir/$name.toml.in"
  if [ ! -f "$template" ]; then
    printf 'missing role template: %s\n' "$template" >&2
    failures=$((failures + 1))
    continue
  fi
  rendered="$tmp_root/$name.toml"
  render_template "$template" "$rendered" || { failures=$((failures + 1)); continue; }
  grep -Fqx "name = \"$name\"" "$rendered" || { printf 'role template name mismatch: %s\n' "$template" >&2; failures=$((failures + 1)); continue; }
  target="$output_dir/$name.toml"
  if [ "$check_only" -eq 1 ]; then
    if [ ! -f "$target" ] || ! cmp -s "$rendered" "$target"; then
      printf 'stale generated role: %s\n' "$target" >&2
      failures=$((failures + 1))
    fi
  else
    mkdir -p "$output_dir"
    cp "$rendered" "$target"
  fi
done

[ "$failures" -eq 0 ] || exit 1
printf '%s\n' "Codex roles $([ "$check_only" -eq 1 ] && printf checked || printf generated): $output_dir"
