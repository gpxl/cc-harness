#!/usr/bin/env bash
# Check installed shared native Codex roles and optional project-local shadows.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
codex_dir="${CC_HARNESS_CODEX_DIR:-${HOME}/.codex}"
project_dir=''
roles=(harness_explorer harness_runner harness_worker harness_analyst harness_reviewer)
legacy_roles=(explorer runner worker analyst reviewer)
failures=0

usage() { printf '%s\n' 'Usage: scripts/codex-routing-check.sh [--codex-dir <path>] [--project <path>]'; }
issue() { printf 'CODEX ROUTING CHECK: %s\n' "$1" >&2; failures=$((failures + 1)); }

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

global_target="$codex_dir/AGENTS.md"
global_source="$root/global/CLAUDE.md"
if [ ! -L "$global_target" ]; then
  issue "missing managed global instruction link: $global_target"
elif [ "$(readlink "$global_target")" != "$global_source" ]; then
  issue "managed global instruction link drift: $global_target"
elif [ ! -f "$global_source" ]; then
  issue "missing managed global instruction source: $global_source"
fi

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
  for role in "${roles[@]}"; do
    target="$project_dir/.codex/agents/$role.toml"
    if [ -e "$target" ] || [ -L "$target" ]; then issue "project role shadow: $target"; fi
  done
  for role in "${legacy_roles[@]}"; do
    target="$project_dir/.codex/agents/$role.toml"
    if [ -e "$target" ] || [ -L "$target" ]; then issue "legacy project role copy: $target"; fi
  done
  if [ -f "$project_dir/.codex/config.toml" ] && grep -Eq '^[[:space:]]*default_subagent_(model|reasoning_effort)[[:space:]]*=' "$project_dir/.codex/config.toml"; then
    issue "project routing default copy: $project_dir/.codex/config.toml"
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
