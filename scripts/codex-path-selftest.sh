#!/usr/bin/env bash
# Regression test for the version-resilient Codex plugin path helpers.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
resolver="$root/codex-plugin-root.sh"
wrapper="$root/codex.sh"
failures=0
output=''
status=0
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-path-selftest.XXXXXX") || exit 1
# A completion sentinel, not `$?`: on bash 3.2 (the system shell here) a script killed by
# set -e/set -u runs its EXIT trap with $? ALREADY RESET TO 0, so capturing the status in the
# trap is inert — measured. Only positive evidence that the suite reached its own verdict can
# distinguish a real pass from an abort. cch-85b; rules/verification-integrity.md.
completed=0
trap 'st=$?; rm -rf "$tmp_root"; [ "$completed" = 1 ] || st=1; exit $st' EXIT HUP INT TERM

record() {
  if "$@"; then
    return 0
  fi
  failures=$((failures + 1))
  return 0
}

make_plugin() {
  local fixture_root="$1"
  local version="$2"
  mkdir -p "$fixture_root/$version/scripts"
  : > "$fixture_root/$version/scripts/codex-companion.mjs"
}

run_resolver() {
  local cache_dir="$1"
  if output=$(CODEX_PLUGIN='' CODEX_PLUGIN_CACHE_DIR="$cache_dir" bash "$resolver" 2>"$tmp_root/resolver.err"); then
    status=0
  else
    status=$?
  fi
}

real_plugin_is_resolved() {
  if output=$(CODEX_PLUGIN='' bash "$resolver" 2>"$tmp_root/real.err"); then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] && [ -d "$output" ] && [ -f "$output/scripts/codex-companion.mjs" ]
}

fixture="$tmp_root/fixture"
empty_fixture="$tmp_root/empty"
mkdir -p "$fixture" "$empty_fixture"
fixture=$(CDPATH='' cd -- "$fixture" && pwd -P)
empty_fixture=$(CDPATH='' cd -- "$empty_fixture" && pwd -P)
make_plugin "$fixture" '1.0.2'
make_plugin "$fixture" '1.0.9'
make_plugin "$fixture" '1.0.10'
mkdir -p "$fixture/9.9.9/scripts"

semver_ordering_prefers_1_0_10() {
  run_resolver "$fixture"
  [ "$status" -eq 0 ] && [ "$output" = "$fixture/1.0.10" ]
}

valid_codex_plugin_override_is_honored() {
  if output=$(CODEX_PLUGIN="$fixture/1.0.2" CODEX_PLUGIN_CACHE_DIR="$empty_fixture" bash "$resolver" 2>"$tmp_root/override.err"); then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] && [ "$output" = "$fixture/1.0.2" ]
}

missing_companion_is_skipped() {
  run_resolver "$fixture"
  [ "$status" -eq 0 ] && [ "$output" != "$fixture/9.9.9" ]
}

empty_cache_fails_without_stdout() {
  run_resolver "$empty_fixture"
  [ "$status" -eq 1 ] && [ -z "$output" ] && [ -s "$tmp_root/resolver.err" ]
}

wrapper_reports_actionable_resolution_failure() {
  if output=$(CODEX_PLUGIN='' CODEX_PLUGIN_CACHE_DIR="$empty_fixture" bash "$wrapper" setup --json 2>"$tmp_root/wrapper.err"); then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] && [ -z "$output" ] && grep -Fqx 'Codex plugin not found — run /codex:setup or install the openai-codex plugin' "$tmp_root/wrapper.err"
}

wrong_expectation_is_detected() {
  run_resolver "$fixture"
  ! { [ "$status" -eq 0 ] && [ "$output" = "$fixture/1.0.9" ]; }
}

record real_plugin_is_resolved
record semver_ordering_prefers_1_0_10
record valid_codex_plugin_override_is_honored
record missing_companion_is_skipped
record empty_cache_fails_without_stdout
record wrapper_reports_actionable_resolution_failure
record wrong_expectation_is_detected

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'CODEX PATH SELFTEST: PASS'
  completed=1; completed=1; exit 0
fi

printf '%s\n' 'CODEX PATH SELFTEST: FAIL'
completed=1; completed=1; exit 1
