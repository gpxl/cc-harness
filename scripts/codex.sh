#!/usr/bin/env bash
# Supported entry point for the installed openai-codex plugin companion.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if ! plugin_root=$(bash "$script_dir/codex-plugin-root.sh" 2>/dev/null); then
  printf '%s\n' 'Codex plugin not found — run /codex:setup or install the openai-codex plugin' >&2
  exit 1
fi

exec node "$plugin_root/scripts/codex-companion.mjs" "$@"
