#!/usr/bin/env bash
set -euo pipefail

# cc-harness installer
# Symlinks agents/, rules/, hooks/, and the global CLAUDE.md into ~/.claude/ so
# they're loaded globally by Claude Code.

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
# Set CC_HARNESS_CLAUDE_DIR to install into a non-default Claude directory.
CLAUDE_DIR="${CC_HARNESS_CLAUDE_DIR:-${HOME}/.claude}"
# Set CC_HARNESS_CODEX_DIR to install native Codex roles into a non-default directory.
# Deliberately do not read CODEX_HOME: fake-HOME tests must never reach a live Codex home.
CODEX_DIR="${CC_HARNESS_CODEX_DIR:-${HOME}/.codex}"
CODEX_ROLES=(harness_explorer harness_runner harness_spark harness_worker harness_analyst harness_reviewer)

echo "cc-harness installer"
echo "========================"
echo "Source:  ${HARNESS_DIR}"
echo "Target:  ${CLAUDE_DIR}"
echo "Codex:   ${CODEX_DIR}"
echo ""

codex_conflict() {
  printf 'Codex managed target conflict: %s\n' "$1" >&2
  return 1
}

codex_backup_path() {
  local target="$1"
  local base candidate suffix
  base="${target}.backup.$(date +%Y%m%d%H%M%S)"
  candidate="$base"
  suffix=0
  while [ -e "$candidate" ] || [ -L "$candidate" ]; do
    suffix=$((suffix + 1))
    candidate=$(printf '%s.%04d' "$base" "$suffix")
  done
  printf '%s\n' "$candidate"
}

codex_role_name() {
  python3 "${HARNESS_DIR}/scripts/codex-toml-inspect.py" role-name "$1"
}

# Check every native Codex destination before changing either user configuration.
# Role names are reserved by this harness only; a personal role with the same name is
# never overwritten.  The global AGENTS.md may be safely backed up and restored.
preflight_codex_targets() {
  local role target source agent name override
  override="${CODEX_DIR}/AGENTS.override.md"
  if [ -s "$override" ]; then
    codex_conflict "active global instruction override: $override (empty or remove it before activating shared routing)"
    return 1
  fi
  if [ -e "${CODEX_DIR}/agents" ] || [ -L "${CODEX_DIR}/agents" ]; then
    [ -d "${CODEX_DIR}/agents" ] && [ ! -L "${CODEX_DIR}/agents" ] || { codex_conflict "${CODEX_DIR}/agents (expected directory)"; return 1; }
  fi
  if [ -d "${CODEX_DIR}/AGENTS.md" ]; then
    codex_conflict "${CODEX_DIR}/AGENTS.md (unsupported directory)"
    return 1
  fi
  for role in "${CODEX_ROLES[@]}"; do
    target="${CODEX_DIR}/agents/${role}.toml"
    source="${HARNESS_DIR}/codex/agents/${role}.toml"
    if [ -e "$target" ] || [ -L "$target" ]; then
      if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
        continue
      fi
      codex_conflict "$target"
      return 1
    fi
  done
  if [ -d "${CODEX_DIR}/agents" ]; then
    while IFS= read -r agent; do
      if ! name=$(codex_role_name "$agent"); then
        codex_conflict "unable to inspect agent TOML: $agent"
        return 1
      fi
      for role in "${CODEX_ROLES[@]}"; do
        if [ "$name" = "$role" ]; then
          target="${CODEX_DIR}/agents/${role}.toml"
          source="${HARNESS_DIR}/codex/agents/${role}.toml"
          if [ "$agent" != "$target" ] || [ ! -L "$target" ] || [ "$(readlink "$target")" != "$source" ]; then
            codex_conflict "semantic role collision: $agent declares $name"
            return 1
          fi
        fi
      done
    done < <(find -L "${CODEX_DIR}/agents" -type f -name '*.toml' -print)
  fi
}

link_codex_global() {
  local source="${HARNESS_DIR}/global/CLAUDE.md"
  local target="${CODEX_DIR}/AGENTS.md"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
    echo "  AGENTS.md   already linked (no change)"
    return
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    local backup
    backup=$(codex_backup_path "$target")
    echo "  AGENTS.md   existing target backed up to ${backup}"
    mv "$target" "$backup"
  fi
  ln -s "$source" "$target"
  echo "  AGENTS.md   linked ✓"
}

link_codex_role() {
  local role="$1"
  local source="${HARNESS_DIR}/codex/agents/${role}.toml"
  local target="${CODEX_DIR}/agents/${role}.toml"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
    echo "  ${role}.toml   already linked (no change)"
    return
  fi
  ln -s "$source" "$target"
  echo "  ${role}.toml   linked ✓"
}

# Generated files are tracked: fail before touching home directories when a routing-table
# change was not rendered into the native Codex role catalog.
bash "${HARNESS_DIR}/scripts/sync-codex-agents.sh" --check
preflight_codex_targets

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
echo "Linking native Codex instructions and roles..."
mkdir -p "${CODEX_DIR}/agents"
link_codex_global
for role in "${CODEX_ROLES[@]}"; do
  link_codex_role "$role"
done

echo ""
echo "Done. Global agents, rules, hooks, scripts, hook registrations, CLAUDE.md, and native Codex roles are now active."
echo ""
echo "Next steps:"
echo "  1. Add an '## Agent Config' table to each project's CLAUDE.md"
echo "     (see templates/agent-config.md for the template)"
echo "  2. Remove any per-project agents that duplicate the global ones"
echo "  3. Run 'claude' in any project — the agents, routing hooks, and scripts will be active"
echo ""
echo "To uninstall: ./uninstall.sh"
