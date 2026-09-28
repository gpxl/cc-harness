#!/usr/bin/env bash
# Supported entry point for the installed openai-codex plugin companion.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Vendor switch (hooks/vendors.conf): refuse to start new Codex work while openai is disabled.
# status/result/cancel/setup stay available so jobs already in flight can still be managed.
case "${1:-}" in
  task|review|adversarial-review)
    vendors_sh="${CC_HARNESS_VENDORS_SH:-$script_dir/../hooks/vendors.sh}"
    if [ ! -r "$vendors_sh" ] || ! . "$vendors_sh" || ! vendor_enabled openai; then
      printf '%s\n' "codex.sh: vendor 'openai' is disabled by the vendor switch — refusing '$1'. Check: bash ~/.claude/hooks/vendors.sh; re-enable in hooks/vendors.conf or ~/.claude/private/vendors.conf." >&2
      exit 3
    fi
    ;;
esac

if ! plugin_root=$(bash "$script_dir/codex-plugin-root.sh" 2>/dev/null); then
  printf '%s\n' 'Codex plugin not found — run /codex:setup or install the openai-codex plugin' >&2
  exit 1
fi

exec node "$plugin_root/scripts/codex-companion.mjs" "$@"
