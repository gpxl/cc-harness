#!/usr/bin/env bash
# Resolve the installed openai-codex plugin without pinning its cache version.
set -euo pipefail

cache_dir="${CODEX_PLUGIN_CACHE_DIR:-${HOME}/.claude/plugins/cache/openai-codex/codex}"

absolute_dir() {
  (
    CDPATH='' cd -- "$1"
    pwd -P
  )
}

prerelease_greater() {
  local left="$1"
  local right="$2"
  local left_part right_part

  [ -z "$left" ] && return 0
  [ -z "$right" ] && return 1

  while :; do
    left_part="${left%%.*}"
    right_part="${right%%.*}"

    if [[ "$left_part" =~ ^[0-9]+$ ]] && [[ "$right_part" =~ ^[0-9]+$ ]]; then
      if [ "$left_part" -gt "$right_part" ]; then
        return 0
      elif [ "$left_part" -lt "$right_part" ]; then
        return 1
      fi
    elif [[ "$left_part" =~ ^[0-9]+$ ]]; then
      return 1
    elif [[ "$right_part" =~ ^[0-9]+$ ]]; then
      return 0
    elif [[ "$left_part" > "$right_part" ]]; then
      return 0
    elif [[ "$left_part" < "$right_part" ]]; then
      return 1
    fi

    if [ "$left" = "$left_part" ] || [ "$right" = "$right_part" ]; then
      [ "$left" != "$left_part" ] && return 0
      return 1
    fi
    left="${left#*.}"
    right="${right#*.}"
  done
}

semver_greater() {
  local major="$1"
  local minor="$2"
  local patch="$3"
  local prerelease="$4"
  local best_major="$5"
  local best_minor="$6"
  local best_patch="$7"
  local best_prerelease="$8"

  if [ "$major" -ne "$best_major" ]; then
    [ "$major" -gt "$best_major" ]
    return
  fi
  if [ "$minor" -ne "$best_minor" ]; then
    [ "$minor" -gt "$best_minor" ]
    return
  fi
  if [ "$patch" -ne "$best_patch" ]; then
    [ "$patch" -gt "$best_patch" ]
    return
  fi
  prerelease_greater "$prerelease" "$best_prerelease"
}

if [ -n "${CODEX_PLUGIN:-}" ] && [ -f "${CODEX_PLUGIN}/scripts/codex-companion.mjs" ]; then
  absolute_dir "$CODEX_PLUGIN"
  exit 0
fi

best_dir=''
best_major=0
best_minor=0
best_patch=0
best_prerelease=''

for candidate in "$cache_dir"/*; do
  [ -d "$candidate" ] || continue
  [ -f "$candidate/scripts/codex-companion.mjs" ] || continue

  version="${candidate##*/}"
  if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z.-]+))?(\+[0-9A-Za-z.-]+)?$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    prerelease="${BASH_REMATCH[5]:-}"
  else
    continue
  fi

  if [ -z "$best_dir" ] || semver_greater "$major" "$minor" "$patch" "$prerelease" "$best_major" "$best_minor" "$best_patch" "$best_prerelease"; then
    best_dir="$candidate"
    best_major="$major"
    best_minor="$minor"
    best_patch="$patch"
    best_prerelease="$prerelease"
  fi
done

if [ -n "$best_dir" ]; then
  absolute_dir "$best_dir"
  exit 0
fi

printf '%s\n' "Codex plugin root not found in $cache_dir" >&2
exit 1
