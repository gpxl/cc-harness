#!/usr/bin/env bash
set -euo pipefail

# cc-harness installer
# Symlinks agents/, rules/, hooks/, and the global CLAUDE.md into ~/.claude/ so
# they're loaded globally by Claude Code.

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
# Set CC_HARNESS_CLAUDE_DIR to install into a non-default Claude directory.
CLAUDE_DIR="${CC_HARNESS_CLAUDE_DIR:-${HOME}/.claude}"

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

# Link a single file. Unlike link_dir the repo path and the installed name
# differ (global/CLAUDE.md → ~/.claude/CLAUDE.md), so both are passed in.
#
# An existing REAL file is backed up, never clobbered: ~/.claude/CLAUDE.md is
# the user's live global instructions, and this installer must not be able to
# destroy content that exists nowhere else.
link_file() {
  local rel_source="$1"
  local name="$2"
  local source="${HARNESS_DIR}/${rel_source}"
  local target="${CLAUDE_DIR}/${name}"

  if [ -L "${target}" ]; then
    local existing
    existing="$(readlink "${target}")"
    if [ "${existing}" = "${source}" ]; then
      echo "  ${name}   already linked (no change)"
      return
    fi
    echo "  ${name}   repointing symlink: ${existing} → ${source}"
    rm "${target}"
  elif [ -f "${target}" ]; then
    local backup="${target}.backup.$(date +%Y%m%d%H%M%S)"
    echo "  ${name}   existing file backed up to ${backup}"
    mv "${target}" "${backup}"
  fi

  ln -s "${source}" "${target}"
  echo "  ${name}   linked ✓"
}

echo "Linking directories..."
link_dir "agents"
link_dir "rules"
link_dir "hooks"
link_dir "scripts"

echo ""
echo "Registering hook commands..."
CC_HARNESS_CLAUDE_DIR="${CLAUDE_DIR}" bash "${HARNESS_DIR}/hooks/install-hooks.sh"
if ! CC_HARNESS_CLAUDE_DIR="${CLAUDE_DIR}" bash "${HARNESS_DIR}/hooks/install-hooks.sh" --check; then
  echo "ERROR: hook registration verification failed." >&2
  exit 1
fi

echo ""
echo "Linking global CLAUDE.md..."
link_file "global/CLAUDE.md" "CLAUDE.md"

echo ""
echo "Done. Global agents, rules, hooks, scripts, hook registrations, and CLAUDE.md are now active."
echo ""
echo "Next steps:"
echo "  1. Add an '## Agent Config' table to each project's CLAUDE.md"
echo "     (see templates/agent-config.md for the template)"
echo "  2. Remove any per-project agents that duplicate the global ones"
echo "  3. Run 'claude' in any project — the agents, routing hooks, and scripts will be active"
echo ""
echo "To uninstall: ./uninstall.sh"
