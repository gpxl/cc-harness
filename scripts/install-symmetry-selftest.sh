#!/usr/bin/env bash
# Hermetic regression test for install.sh/uninstall.sh symmetry.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
failures=0
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/cc-harness-install-symmetry.XXXXXX") || exit 1
trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM

fail() {
  printf '%s\n' "$*" >&2
  return 1
}

extract_link_dirs() {
  sed -nE 's/^[[:space:]]*link_dir[[:space:]]+"([^"]+)".*/\1/p' "$1" | sort -u
}

extract_unlink_dirs() {
  sed -nE 's/^[[:space:]]*unlink_dir[[:space:]]+"([^"]+)".*/\1/p' "$1" | sort -u
}

extract_link_files() {
  sed -nE 's/^[[:space:]]*link_file[[:space:]]+"[^"]+"[[:space:]]+"([^"]+)".*/\1/p' "$1" | sort -u
}

extract_unlink_files() {
  sed -nE 's/^[[:space:]]*unlink_file[[:space:]]+"[^"]+"[[:space:]]+"([^"]+)".*/\1/p' "$1" | sort -u
}

compare_sets() {
  local kind="$1"
  local installed="$2"
  local removed="$3"
  local missing extra
  missing=$(comm -23 "$installed" "$removed")
  extra=$(comm -13 "$installed" "$removed")
  if [ -n "$missing" ]; then
    printf 'Missing %s: %s\n' "$kind" "$(printf '%s' "$missing" | tr '\n' ' ')" >&2
    return 1
  fi
  if [ -n "$extra" ]; then
    printf 'Unexpected %s: %s\n' "$kind" "$(printf '%s' "$extra" | tr '\n' ' ')" >&2
    return 1
  fi
}

check_symmetry() {
  local installer="$1"
  local uninstaller="$2"
  local installed_dirs="$tmp_root/installed-dirs"
  local removed_dirs="$tmp_root/removed-dirs"
  local installed_files="$tmp_root/installed-files"
  local removed_files="$tmp_root/removed-files"

  extract_link_dirs "$installer" > "$installed_dirs"
  extract_unlink_dirs "$uninstaller" > "$removed_dirs"
  extract_link_files "$installer" > "$installed_files"
  extract_unlink_files "$uninstaller" > "$removed_files"

  compare_sets 'unlink_dir entries' "$installed_dirs" "$removed_dirs" || return 1
  compare_sets 'unlink_file entries' "$installed_files" "$removed_files"
}

linked_sources_exist() {
  local source name
  while IFS='|' read -r source name; do
    [ -e "$root/$source" ] || fail "Missing linked source: $source" || return 1
  done < <(
    {
      sed -nE 's/^[[:space:]]*link_dir[[:space:]]+"([^"]+)".*/\1|\1/p' "$root/install.sh"
      sed -nE 's/^[[:space:]]*link_file[[:space:]]+"([^"]+)"[[:space:]]+"([^"]+)".*/\1|\2/p' "$root/install.sh"
    }
  )
}

end_to_end_cycle() {
  local fake_home="$tmp_root/home"
  local fake_claude="$fake_home/.claude"
  local original_scripts="$tmp_root/original-scripts"
  local backup
  local name
  local git_snapshot_target

  mkdir -p "$fake_claude/scripts/nested" || return 1
  printf '%s\n' 'sentinel' > "$fake_claude/scripts/sentinel.txt" || return 1
  printf '%s\n' 'nested sentinel' > "$fake_claude/scripts/nested/sentinel.txt" || return 1
  cp -R "$fake_claude/scripts" "$original_scripts" || return 1
  [ -L "$root/scripts/git-snapshot" ] || fail "Missing $root/scripts/git-snapshot: it is a gitignored, machine-local symlink, so a fresh worktree never has it — recreate it from the main checkout (ln -s \"\$(readlink <main>/scripts/git-snapshot)\" scripts/git-snapshot) before running this selftest" || return 1
  git_snapshot_target=$(readlink "$root/scripts/git-snapshot") || return 1

  HOME="$fake_home" CC_HARNESS_CLAUDE_DIR="$fake_claude" bash "$root/install.sh" > "$tmp_root/install.out" 2>&1 || return 1
  [ -L "$fake_claude/scripts" ] || return 1
  backup=$(ls -d "$fake_claude/scripts".backup.* 2>/dev/null | sort | tail -1 || true)
  [ -n "$backup" ] && diff -ru "$original_scripts" "$backup" >/dev/null || return 1

  HOME="$fake_home" CC_HARNESS_CLAUDE_DIR="$fake_claude" bash "$root/uninstall.sh" > "$tmp_root/uninstall.out" 2>&1 || return 1
  while IFS= read -r name; do
    [ ! -L "$fake_claude/$name" ] || return 1
  done < <(
    extract_link_dirs "$root/install.sh"
    extract_link_files "$root/install.sh"
  )
  [ -d "$fake_claude/scripts" ] && diff -ru "$original_scripts" "$fake_claude/scripts" >/dev/null || return 1
  [ -L "$root/scripts/git-snapshot" ] && [ "$(readlink "$root/scripts/git-snapshot")" = "$git_snapshot_target" ]
}

negative_control_fails() {
  local mutated="$tmp_root/uninstall-without-scripts.sh"
  local output
  sed '/^[[:space:]]*unlink_dir[[:space:]]*"scripts"[[:space:]]*$/d' "$root/uninstall.sh" > "$mutated" || return 1
  if output=$(check_symmetry "$root/install.sh" "$mutated" 2>&1); then
    return 1
  fi
  printf '%s' "$output" | grep -F 'Missing unlink_dir entries: scripts' >/dev/null
}

record() {
  if "$@"; then
    return 0
  fi
  failures=$((failures + 1))
  return 0
}

record check_symmetry "$root/install.sh" "$root/uninstall.sh"
record linked_sources_exist
record end_to_end_cycle
record negative_control_fails

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'INSTALL SYMMETRY SELFTEST: PASS'
  exit 0
fi

printf '%s\n' 'INSTALL SYMMETRY SELFTEST: FAIL'
exit 1
