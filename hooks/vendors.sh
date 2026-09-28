#!/usr/bin/env bash
# Model vendor switch resolver. Bash 3.2-compatible.
#
# Sourced: defines vendor_state / vendor_enabled / vendor_source.
# Run:     `bash hooks/vendors.sh` prints every known vendor's resolved state and where it came from.
#
# Resolution, later wins per vendor:
#   1. ${CC_HARNESS_VENDORS_FILE:-<this dir>/vendors.conf}            tracked default
#   2. ${CC_HARNESS_VENDORS_LOCAL:-$HOME/.claude/private/vendors.conf} machine-local override
# A vendor no file names, or names with a value other than enabled/disabled, is disabled: an
# external vendor is routed to only on positive evidence. anthropic is always enabled.

vendors_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

vendors_files() {
  printf '%s\n' "${CC_HARNESS_VENDORS_FILE:-$vendors_dir/vendors.conf}"
  printf '%s\n' "${CC_HARNESS_VENDORS_LOCAL:-${HOME:-}/.claude/private/vendors.conf}"
}

# Prints "<state>|<file>" for the last line naming the vendor, or nothing.
vendors_lookup() {
  local sought="$1" file line key value found=''
  while IFS= read -r file; do
    [ -r "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      case "$line" in *=*) ;; *) continue ;; esac
      key=${line%%=*}
      value=${line#*=}
      [ "$key" = "$sought" ] || continue
      case "$value" in
        enabled|disabled) found="$value|$file" ;;
        *) found="disabled|$file" ;;
      esac
    done < "$file"
  done < <(vendors_files)
  [ -n "$found" ] && printf '%s\n' "$found"
  return 0
}

vendor_state() {
  local found
  if [ "$1" = anthropic ]; then
    printf '%s\n' enabled
    return 0
  fi
  found=$(vendors_lookup "$1")
  printf '%s\n' "${found%%|*}" | sed 's/^$/disabled/'
}

vendor_enabled() {
  [ "$(vendor_state "$1")" = enabled ]
}

vendor_source() {
  local found
  if [ "$1" = anthropic ]; then
    printf '%s\n' '(always enabled)'
    return 0
  fi
  found=$(vendors_lookup "$1")
  if [ -n "$found" ]; then
    printf '%s\n' "${found#*|}"
  else
    printf '%s\n' '(not configured)'
  fi
}

vendors_known() {
  local file line
  {
    printf '%s\n' anthropic
    while IFS= read -r file; do
      [ -r "$file" ] || continue
      while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}
        line=$(printf '%s' "$line" | tr -d '[:space:]')
        case "$line" in *=*) printf '%s\n' "${line%%=*}" ;; esac
      done < "$file"
    done < <(vendors_files)
  } | awk '!seen[$0]++'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  while IFS= read -r vendor; do
    printf '%s=%s  (%s)\n' "$vendor" "$(vendor_state "$vendor")" "$(vendor_source "$vendor")"
  done < <(vendors_known)
fi
