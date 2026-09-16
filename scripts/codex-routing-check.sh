#!/usr/bin/env bash
# Check installed shared native Codex roles and optional project-local shadows.
set -euo pipefail

# Resolve the PHYSICAL script directory before taking its parent. Installed, this script is reached
# through ~/.claude/scripts, a symlink to the repository's scripts/: a logical `cd .../scripts/..`
# lands in ~/.claude, and every repository-relative path below then points at a directory that does
# not hold them (cch-u9w).
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
codex_dir="${CC_HARNESS_CODEX_DIR:-${HOME}/.codex}"
project_dir=''
roles=(harness_explorer harness_runner harness_spark harness_worker harness_analyst harness_reviewer)
legacy_roles=(explorer runner worker analyst reviewer)
failures=0

usage() { printf '%s\n' 'Usage: scripts/codex-routing-check.sh [--codex-dir <path>] [--project <path>]'; }
issue() { printf 'CODEX ROUTING CHECK: %s\n' "$1" >&2; failures=$((failures + 1)); }
role_name() { python3 "$root/scripts/codex-toml-inspect.py" role-name "$1"; }
routing_defaults() { python3 "$root/scripts/codex-toml-inspect.py" routing-defaults "$1"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --codex-dir) codex_dir="${2:?missing value for --codex-dir}"; shift ;;
    --project) project_dir="${2:?missing value for --project}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if ! "$root/scripts/sync-codex-agents.sh" --check; then
  issue 'generated role catalog is stale'
fi

inspect_agent_identities() {
  local agents_dir="$1" scope="$2" agent name role expected
  [ -e "$agents_dir" ] || [ -L "$agents_dir" ] || return 0
  if [ ! -d "$agents_dir" ]; then
    issue "unable to inspect agent directory: $agents_dir"
    return 0
  fi
  while IFS= read -r agent; do
    if ! name=$(role_name "$agent"); then
      issue "unable to inspect agent TOML: $agent"
      continue
    fi
    for role in "${roles[@]}"; do
      [ "$name" = "$role" ] || continue
      if [ "$scope" = global ]; then
        expected="$codex_dir/agents/$role.toml"
        if [ "$agent" != "$expected" ] || [ ! -L "$expected" ] || [ "$(readlink "$expected")" != "$root/codex/agents/$role.toml" ]; then
          issue "semantic role collision: $agent declares $name"
        fi
      else
        issue "semantic project role shadow: $agent declares $name"
      fi
    done
    if [ "$scope" = project ]; then
      for role in "${legacy_roles[@]}"; do
        [ "$name" = "$role" ] && issue "legacy project role copy: $agent declares $name"
      done
    fi
  done < <(find -L "$agents_dir" -type f -name '*.toml' -print)
  return 0
}

global_target="$codex_dir/AGENTS.md"
global_source="$root/global/CLAUDE.md"
if [ -s "$codex_dir/AGENTS.override.md" ]; then
  issue "active global instruction override: $codex_dir/AGENTS.override.md (empty or remove it to activate managed AGENTS.md)"
fi
if [ ! -L "$global_target" ]; then
  issue "missing managed global instruction link: $global_target"
elif [ "$(readlink "$global_target")" != "$global_source" ]; then
  issue "managed global instruction link drift: $global_target"
elif [ ! -f "$global_source" ]; then
  issue "missing managed global instruction source: $global_source"
fi

inspect_agent_identities "$codex_dir/agents" global

for role in "${roles[@]}"; do
  target="$codex_dir/agents/$role.toml"
  source="$root/codex/agents/$role.toml"
  if [ ! -f "$source" ]; then
    issue "missing managed role source: $source"
  elif [ ! -L "$target" ]; then
    issue "missing managed role link: $target"
  elif [ "$(readlink "$target")" != "$source" ]; then
    issue "managed role link drift: $target"
  fi
done

if [ -n "$project_dir" ]; then
  [ -d "$project_dir" ] || issue "project directory not found: $project_dir"
  if [ -s "$project_dir/AGENTS.override.md" ]; then
    issue "active project instruction override: $project_dir/AGENTS.override.md (empty or remove it to adopt shared routing)"
  fi
  inspect_agent_identities "$project_dir/.codex/agents" project
  config="$project_dir/.codex/config.toml"
  if [ -e "$config" ] || [ -L "$config" ]; then
    if ! defaults=$(routing_defaults "$config"); then
      issue "unable to inspect project configuration: $config"
    elif [ -n "$defaults" ]; then
      issue "project routing default copy: $config"
    fi
  fi
  if [ -f "$project_dir/AGENTS.md" ] && ! grep -F 'harness_' "$project_dir/AGENTS.md" >/dev/null; then
    issue "project AGENTS.md does not reference shared harness roles: $project_dir/AGENTS.md"
  fi
fi

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'CODEX ROUTING CHECK: PASS'
  exit 0
fi
printf 'CODEX ROUTING CHECK: FAIL (%s issue(s))\n' "$failures" >&2
exit 1
