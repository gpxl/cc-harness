#!/usr/bin/env bash
set -euo pipefail

# cc-harness uninstaller
# Removes symlinks from ~/.claude/ and restores the most recent backup of each.
# Does not delete backed-up directories.

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
# Set CC_HARNESS_CLAUDE_DIR to uninstall from a non-default Claude directory.
CLAUDE_DIR="${CC_HARNESS_CLAUDE_DIR:-${HOME}/.claude}"
CODEX_DIR="${CC_HARNESS_CODEX_DIR:-${HOME}/.codex}"
CODEX_ROLES=(harness_explorer harness_runner harness_spark harness_worker harness_analyst harness_reviewer)

echo "cc-harness uninstaller"
echo "========================="

unlink_dir() {
  local name="$1"
  local source="${HARNESS_DIR}/${name}"
  local target="${CLAUDE_DIR}/${name}"

  if [ -L "${target}" ]; then
    local existing
    existing="$(readlink "${target}")"
    if [ "${existing}" = "${source}" ]; then
      rm "${target}"
      echo "  ${name}/  unlinked ✓"

      # Restore backup if one exists
      local latest_backup
      latest_backup="$(ls -d "${target}".backup.* 2>/dev/null | sort | tail -1 || true)"
      if [ -n "${latest_backup}" ]; then
        mv "${latest_backup}" "${target}"
        echo "  ${name}/  restored from backup"
      fi
    else
      echo "  ${name}/  symlink points elsewhere (${existing}), skipping"
    fi
  elif [ -d "${target}" ]; then
    echo "  ${name}/  is a regular directory, not a symlink — skipping"
  else
    echo "  ${name}/  not found — nothing to do"
  fi
}

# Symmetric counterpart to install.sh's link_file: unlink, then restore the
# most recent backup so the user's pre-install CLAUDE.md comes back.
unlink_file() {
  local rel_source="$1"
  local name="$2"
  local source="${HARNESS_DIR}/${rel_source}"
  local target="${CLAUDE_DIR}/${name}"

  if [ -L "${target}" ]; then
    local existing
    existing="$(readlink "${target}")"
    if [ "${existing}" = "${source}" ]; then
      rm "${target}"
      echo "  ${name}   unlinked ✓"

      # Restore backup if one exists
      local latest_backup
      latest_backup="$(ls "${target}".backup.* 2>/dev/null | sort | tail -1 || true)"
      if [ -n "${latest_backup}" ]; then
        mv "${latest_backup}" "${target}"
        echo "  ${name}   restored from backup"
      fi
    else
      echo "  ${name}   symlink points elsewhere (${existing}), skipping"
    fi
  elif [ -f "${target}" ]; then
    echo "  ${name}   is a regular file, not a symlink — skipping"
  else
    echo "  ${name}   not found — nothing to do"
  fi
}

unlink_codex_global() {
  local source="${HARNESS_DIR}/global/CLAUDE.md"
  local target="${CODEX_DIR}/AGENTS.md"
  if [ -L "$target" ]; then
    if [ "$(readlink "$target")" != "$source" ]; then
      echo "  AGENTS.md   symlink points elsewhere ($(readlink "$target")), skipping"
      return
    fi
    rm "$target"
    echo "  AGENTS.md   unlinked ✓"
    local latest_backup
    latest_backup="$(ls "${target}".backup.* 2>/dev/null | sort | tail -1 || true)"
    if [ -n "$latest_backup" ]; then
      mv "$latest_backup" "$target"
      echo "  AGENTS.md   restored from backup"
    fi
  elif [ -e "$target" ]; then
    echo "  AGENTS.md   is not a harness symlink, skipping"
  else
    echo "  AGENTS.md   not found — nothing to do"
  fi
}

unlink_codex_role() {
  local role="$1"
  local source="${HARNESS_DIR}/codex/agents/${role}.toml"
  local target="${CODEX_DIR}/agents/${role}.toml"
  if [ -L "$target" ]; then
    if [ "$(readlink "$target")" = "$source" ]; then
      rm "$target"
      echo "  ${role}.toml   unlinked ✓"
    else
      echo "  ${role}.toml   symlink points elsewhere ($(readlink "$target")), skipping"
    fi
  elif [ -e "$target" ]; then
    echo "  ${role}.toml   is not a harness symlink, skipping"
  else
    echo "  ${role}.toml   not found — nothing to do"
  fi
}

echo "Removing symlinks..."
unlink_dir "agents"
unlink_dir "rules"
unlink_dir "scripts"
echo ""
echo "Removing hook registrations..."
CC_HARNESS_CLAUDE_DIR="${CLAUDE_DIR}" bash "${HARNESS_DIR}/hooks/install-hooks.sh" --remove
unlink_dir "hooks"
unlink_file "global/CLAUDE.md" "CLAUDE.md"

echo ""
echo "Removing native Codex instructions and roles..."
unlink_codex_global
for role in "${CODEX_ROLES[@]}"; do
  unlink_codex_role "$role"
done

echo ""
echo "Done. Global agents, rules, hooks, scripts, hook registrations, CLAUDE.md, and native Codex roles have been removed."
