#!/usr/bin/env bash
set -euo pipefail

# cc-harness installer
# Symlinks agents/ and rules/ into ~/.claude/ so they're loaded globally by Claude Code.

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"

echo "cc-harness installer"
echo "========================"
echo "Source:  ${HARNESS_DIR}"
echo "Target:  ${CLAUDE_DIR}"
echo ""

# Ensure ~/.claude/ exists
mkdir -p "${CLAUDE_DIR}"

link_dir() {
  local name="$1"
  local source="${HARNESS_DIR}/${name}"
  local target="${CLAUDE_DIR}/${name}"

  if [ -L "${target}" ]; then
    local existing
    existing="$(readlink "${target}")"
    if [ "${existing}" = "${source}" ]; then
      echo "  ${name}/  already linked (no change)"
      return
    fi
    echo "  ${name}/  repointing symlink: ${existing} → ${source}"
    rm "${target}"
  elif [ -d "${target}" ]; then
    local backup="${target}.backup.$(date +%Y%m%d%H%M%S)"
    echo "  ${name}/  existing directory backed up to ${backup}"
    mv "${target}" "${backup}"
  fi

  ln -s "${source}" "${target}"
  echo "  ${name}/  linked ✓"
}

echo "Linking directories..."
link_dir "agents"
link_dir "rules"

echo ""
echo "Done. Global agents and rules are now active."
echo ""
echo "Next steps:"
echo "  1. Add an '## Agent Config' table to each project's CLAUDE.md"
echo "     (see templates/agent-config.md for the template)"
echo "  2. Remove any per-project agents that duplicate the global ones"
echo "  3. Run 'claude' in any project — the agents will be available"
echo ""
echo "To uninstall: ./uninstall.sh"
