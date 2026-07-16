#!/usr/bin/env bash
set -euo pipefail

# cc-harness uninstaller
# Removes symlinks from ~/.claude/ and restores the most recent backup of each.
# Does not delete backed-up directories.

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"

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

echo "Removing symlinks..."
unlink_dir "agents"
unlink_dir "rules"
unlink_file "global/CLAUDE.md" "CLAUDE.md"

echo ""
echo "Done. Global agents, rules, and CLAUDE.md have been removed."
