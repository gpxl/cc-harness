#!/usr/bin/env bash
# Hermetic model-routing hook regression test. No network or real hook state.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
failures=0
output=''
tmp_state=$(mktemp -d "${TMPDIR:-/tmp}/cc-harness-hooks.XXXXXX") || exit 1
# A completion sentinel, not `$?`: on bash 3.2 (the system shell here) a script killed by
# set -e/set -u runs its EXIT trap with $? ALREADY RESET TO 0, so capturing the status in the
# trap is inert — measured. Only positive evidence that the suite reached its own verdict can
# distinguish a real pass from an abort. cch-85b; rules/verification-integrity.md.
completed=0
trap 'st=$?; rm -rf "$tmp_state"; [ "$completed" = 1 ] || st=1; exit $st' EXIT HUP INT TERM
export XDG_STATE_HOME="$tmp_state"
# Hermetic vendor switch: every row runs against fixtures, never the tracked or local config.
vendors_on="$tmp_state/vendors-openai-enabled.conf"
vendors_off="$tmp_state/vendors-openai-disabled.conf"
printf 'anthropic=enabled\nopenai=enabled\n' > "$vendors_on"
printf 'anthropic=enabled\nopenai=disabled\n' > "$vendors_off"
export CC_HARNESS_VENDORS_FILE="$vendors_on"
export CC_HARNESS_VENDORS_LOCAL="$tmp_state/no-local-vendors.conf"
plugin_cache="$tmp_state/plugin-cache"
plugin_root="$plugin_cache/1.2.3"
mkdir -p "$plugin_root/scripts"
: > "$plugin_root/scripts/codex-companion.mjs"
plugin_root=$(CDPATH='' cd -- "$plugin_root" && pwd -P)
export CODEX_PLUGIN=''
export CODEX_PLUGIN_CACHE_DIR="$plugin_cache"

record() {
  local label="$1"
  shift
  if "$@"; then
    printf '%s: PASS\n' "$label"
  else
    printf '%s: FAIL\n' "$label"
    failures=$((failures + 1))
  fi
}

check_json() {
  local payload="$1"
  local json_file
  json_file=$(mktemp "${TMPDIR:-/tmp}/cc-harness-hook-json.XXXXXX") || return 1
  printf '%s' "$payload" > "$json_file" || {
    rm -f "$json_file"
    return 1
  }
  if python3 -c 'import json, sys; data = json.load(sys.stdin); assert data["hookSpecificOutput"]["hookEventName"] == "PostToolUse"' < "$json_file" >/dev/null 2>&1; then
    rm -f "$json_file"
    return 0
  fi
  rm -f "$json_file"
  return 1
}

invoke_bd() {
  local command="$1"
  output=$(printf '{"tool_input":{"command":"%s"}}' "$command" | bash "$root/bd-ready-model-routing.sh" 2>/dev/null) || return 1
}

load_model_routing_table() {
  local data_file="$root/model-routing-table.sh"
  [ -r "$data_file" ] || return 1
  if ! . "$data_file"; then
    return 1
  fi
  model_routing_table_valid
}

bd_fires() {
  local build_index
  load_model_routing_table || return 1
  build_index=$(model_routing_index_for_key build) || return 1
  invoke_bd "$1" && [ -n "$output" ] && check_json "$output" && printf '%s' "$output" | grep -Fq "${MODEL_ROUTING_CODEX[$build_index]}"
}

bd_silent() {
  invoke_bd "$1" && [ -z "$output" ]
}

exitplan_valid() {
  local build_index retired_opus retired_sonnet retired_gpt
  load_model_routing_table || return 1
  retired_opus=$(printf '%s%s' 'claude-opus-' '4-8')
  retired_sonnet=$(printf '%s%s' 'claude-sonnet-' '4-6')
  retired_gpt=$(printf '%s%s' 'gpt-5' '.4')
  build_index=$(model_routing_index_for_key build) || return 1
  output=$(bash "$root/exitplan-model-routing.sh" </dev/null 2>/dev/null) || return 1
  [ -n "$output" ] && check_json "$output" && printf '%s' "$output" | grep -Fqi 'codex' && printf '%s' "$output" | grep -Fq "${MODEL_ROUTING_CODEX[$build_index]}" && ! printf '%s' "$output" | grep -Fq "$retired_opus" && ! printf '%s' "$output" | grep -Fq "$retired_sonnet" && ! printf '%s' "$output" | grep -Fq "$retired_gpt"
}

model_routing_table_matches_claude() {
  local data_file values_file index fallback
  data_file="$root/model-routing-table.sh"
  values_file="$tmp_state/model-routing-values"
  load_model_routing_table || return 1
  : > "$values_file" || return 1
  for ((index = 0; index < ${#MODEL_ROUTING_KEYS[@]}; index++)); do
    printf 'C|%s\n' "${MODEL_ROUTING_CODEX[$index]}" >> "$values_file" || return 1
    for fallback in ${MODEL_ROUTING_CLAUDE_FALLBACKS[$index]}; do
      printf 'L|%s\n' "$fallback" >> "$values_file" || return 1
    done
  done
  python3 - "$root/../global/CLAUDE.md" "$values_file" <<'PY'
import re
import sys

claude_path, values_path = sys.argv[1:]
lines = open(claude_path).read().splitlines()
heading = lines.index("### Equivalence table")
table_lines = []
started = False
for line in lines[heading + 1:]:
    if line.startswith("|"):
        started = True
        table_lines.append(line)
    elif started:
        break
table = "\n".join(table_lines)
table_slugs = set(re.findall(r"\b(?:gpt|claude)-[A-Za-z0-9.-]+\b", table))
expected = set()
for line in open(values_path):
    kind, slug = line.rstrip("\n").split("|", 1)
    assert kind in {"C", "L"}
    expected.add(slug)
assert table_slugs == expected, ("table-only", table_slugs - expected, "data-only", expected - table_slugs)
PY
}

invoke_first_edit() {
  local session_id="$1"
  output=$(printf '{"session_id":"%s"}' "$session_id" | bash "$root/first-edit-codex-gate.sh" 2>/dev/null) || return 1
}

first_edit_fires() {
  invoke_first_edit "$1" && [ -n "$output" ] && check_json "$output"
}

first_edit_silent() {
  invoke_first_edit "$1" && [ -z "$output" ]
}

# openai disabled: bd-ready and exitplan name only Claude models and never recommend Codex.
bd_openai_disabled_routes_to_claude() {
  local build_index slug
  load_model_routing_table || return 1
  build_index=$(model_routing_index_for_key build) || return 1
  output=$(printf '{"tool_input":{"command":"bd ready"}}' | CC_HARNESS_VENDORS_FILE="$vendors_off" bash "$root/bd-ready-model-routing.sh" 2>/dev/null) || return 1
  [ -n "$output" ] && check_json "$output" || return 1
  printf '%s' "$output" | grep -Fq "${MODEL_ROUTING_CLAUDE_FALLBACKS[$build_index]}" || return 1
  printf '%s' "$output" | grep -Fq 'Disabled vendors, never to be routed to: openai' || return 1
  for slug in "${MODEL_ROUTING_CODEX[@]}"; do
    printf '%s' "$output" | grep -Fq "$slug" && return 1
  done
  return 0
}

exitplan_openai_disabled_forbids_codex() {
  local build_index slug
  load_model_routing_table || return 1
  build_index=$(model_routing_index_for_key build) || return 1
  output=$(CC_HARNESS_VENDORS_FILE="$vendors_off" bash "$root/exitplan-model-routing.sh" </dev/null 2>/dev/null) || return 1
  [ -n "$output" ] && check_json "$output" || return 1
  printf '%s' "$output" | grep -Fq 'Do NOT dispatch /codex:rescue' || return 1
  printf '%s' "$output" | grep -Fq "${MODEL_ROUTING_CLAUDE_FALLBACKS[$build_index]}" || return 1
  for slug in "${MODEL_ROUTING_CODEX[@]}"; do
    printf '%s' "$output" | grep -Fq "$slug" && return 1
  done
  return 0
}

first_edit_openai_disabled_is_silent() {
  output=$(printf '{"session_id":"%s"}' 'vendor-off-session' | CC_HARNESS_VENDORS_FILE="$vendors_off" bash "$root/first-edit-codex-gate.sh" 2>/dev/null) || return 1
  [ -z "$output" ] || return 1
  # Silence must not burn the once-per-session marker: re-enabling fires the reminder.
  first_edit_fires 'vendor-off-session'
}

first_edit_invalid_table_is_silent() {
  local copy="$tmp_state/degraded-hooks"
  mkdir -p "$copy" || return 1
  cp "$root/first-edit-codex-gate.sh" "$root/vendors.sh" "$root/model-routing-table.sh" "$copy/" || return 1
  printf 'MODEL_ROUTING_VENDOR_COLUMNS[0]=%s\n' "'MODEL_ROUTING_X;true'" >> "$copy/model-routing-table.sh" || return 1
  output=$(printf '{"session_id":"%s"}' 'degraded-session' | bash "$copy/first-edit-codex-gate.sh" 2>/dev/null) || return 1
  [ -z "$output" ] || return 1
  rm -f "$copy/model-routing-table.sh" || return 1
  output=$(printf '{"session_id":"%s"}' 'degraded-session' | bash "$copy/first-edit-codex-gate.sh" 2>/dev/null) || return 1
  [ -z "$output" ]
}

vendor_state_is() {
  local expected="$1" vendor="$2" file="$3" local_file="${4:-$tmp_state/no-local-vendors.conf}"
  [ "$(CC_HARNESS_VENDORS_FILE="$file" CC_HARNESS_VENDORS_LOCAL="$local_file" bash -c '. "$1" && vendor_state "$2"' _ "$root/vendors.sh" "$vendor")" = "$expected" ]
}

vendor_local_override_wins() {
  local local_file="$tmp_state/local-override.conf"
  printf 'openai = disabled # paused here only\n' > "$local_file"
  vendor_state_is disabled openai "$vendors_on" "$local_file"
}

vendor_unknown_value_fails_closed() {
  local file="$tmp_state/vendors-typo.conf"
  printf 'openai=enabeld\n' > "$file"
  vendor_state_is disabled openai "$file"
}

vendor_missing_config_fails_closed() {
  vendor_state_is disabled openai "$tmp_state/does-not-exist.conf"
}

vendor_anthropic_cannot_be_disabled() {
  local file="$tmp_state/vendors-no-claude.conf"
  printf 'anthropic=disabled\n' > "$file"
  vendor_state_is enabled anthropic "$file"
}

tracked_vendors_conf_parses() {
  local state
  state=$(CC_HARNESS_VENDORS_FILE="$root/vendors.conf" bash -c '. "$1" && vendor_state openai' _ "$root/vendors.sh") || return 1
  grep -Eq '^[[:space:]]*openai[[:space:]]*=[[:space:]]*(enabled|disabled)[[:space:]]*(#.*)?$' "$root/vendors.conf" || return 1
  case "$state" in enabled|disabled) ;; *) return 1 ;; esac
}

broken_checker_fails() {
  local stub
  stub="$tmp_state/broken-hook.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "{broken"' > "$stub" || return 1
  chmod +x "$stub" || return 1
  output=$(bash "$stub" 2>/dev/null) || return 1
  ! check_json "$output"
}

settings_file="$tmp_state/settings.json"

write_settings_fixture() {
  python3 - "$settings_file" <<'PY'
import json
import sys

settings = {
    "$schema": "https://json.schemastore.org/claude-code-settings.json",
    "permissions": {"allow": ["Bash(git status)"], "defaultMode": "auto"},
    "enabledPlugins": {"example@marketplace": True},
    "autoMode": {"allow": ["$defaults"]},
    "hooks": {
        "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "echo session"}]}],
        "PostToolUse": [{"matcher": "Other", "hooks": [{"type": "command", "command": "echo other"}]}],
    },
}
with open(sys.argv[1], "w") as fixture:
    json.dump(settings, fixture, indent=2)
    fixture.write("\n")
PY
}

settings_registrations_are_present() {
  python3 - "$settings_file" "$root/settings-hooks.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
with open(sys.argv[2]) as manifest_file:
    required = json.load(manifest_file)

assert settings["$schema"] == "https://json.schemastore.org/claude-code-settings.json"
assert settings["permissions"] == {"allow": ["Bash(git status)"], "defaultMode": "auto"}
assert settings["enabledPlugins"] == {"example@marketplace": True}
assert settings["autoMode"] == {"allow": ["$defaults"]}
assert settings["hooks"]["SessionStart"] == [{"matcher": "", "hooks": [{"type": "command", "command": "echo session"}]}]
post_tool_use = settings["hooks"]["PostToolUse"]
assert {entry["matcher"] for entry in post_tool_use} == {"Other"} | {entry["matcher"] for entry in required}
for entry in required:
    matches = [candidate for candidate in post_tool_use if candidate.get("matcher") == entry["matcher"]]
    assert matches == [entry]
PY
}

backup_count() {
  local backup
  local count=0
  for backup in "$settings_file".backup.*; do
    if [ -e "$backup" ]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

settings_install_preserves_unrelated() {
  local after_prefix before_prefix
  write_settings_fixture || return 1
  before_prefix=$(sed '/^  "hooks":/,$d' "$settings_file") || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  after_prefix=$(sed '/^  "hooks":/,$d' "$settings_file") || return 1
  [ "$after_prefix" = "$before_prefix" ] && settings_registrations_are_present
}

settings_second_install_is_noop() {
  local before backups_before backups_after
  write_settings_fixture || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  before=$(cat "$settings_file") || return 1
  backups_before=$(backup_count) || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  backups_after=$(backup_count) || return 1
  [ "$(cat "$settings_file")" = "$before" ] && [ "$backups_after" -eq "$backups_before" ]
}

settings_wrong_command_is_replaced() {
  write_settings_fixture || return 1
  python3 - "$settings_file" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
settings["hooks"]["PostToolUse"].append({
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": "bash /wrong/path", "timeout": 5}],
})
with open(sys.argv[1], "w") as settings_file:
    json.dump(settings, settings_file, indent=2)
    settings_file.write("\n")
PY
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  settings_registrations_are_present
}

settings_check_detects_missing_then_passes() {
  local check_output
  write_settings_fixture || return 1
  if bash "$root/install-hooks.sh" --settings "$settings_file" --check >"$tmp_state/check-missing.out" 2>&1; then
    return 1
  fi
  check_output=$(cat "$tmp_state/check-missing.out") || return 1
  printf '%s' "$check_output" | grep -Fx 'Bash: missing' >/dev/null || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" --check >/dev/null
}

settings_remove_preserves_unrelated() {
  write_settings_fixture || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" --remove >/dev/null || return 1
  python3 - "$settings_file" "$root/settings-hooks.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
with open(sys.argv[2]) as manifest_file:
    required = json.load(manifest_file)

assert settings["permissions"] == {"allow": ["Bash(git status)"], "defaultMode": "auto"}
assert settings["enabledPlugins"] == {"example@marketplace": True}
assert settings["autoMode"] == {"allow": ["$defaults"]}
assert settings["hooks"]["SessionStart"] == [{"matcher": "", "hooks": [{"type": "command", "command": "echo session"}]}]
assert settings["hooks"]["PostToolUse"] == [{"matcher": "Other", "hooks": [{"type": "command", "command": "echo other"}]}]
assert all(entry not in settings["hooks"]["PostToolUse"] for entry in required)
PY
}

settings_malformed_json_is_unchanged() {
  local before
  printf '%s\n' '{ malformed json' > "$settings_file" || return 1
  before=$(cat "$settings_file") || return 1
  if bash "$root/install-hooks.sh" --settings "$settings_file" >"$tmp_state/malformed.out" 2>&1; then
    return 1
  fi
  [ "$(cat "$settings_file")" = "$before" ]
}

settings_negative_control_detects_altered_command() {
  local check_output
  write_settings_fixture || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  python3 - "$settings_file" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
for entry in settings["hooks"]["PostToolUse"]:
    if entry.get("matcher") == "Bash":
        entry["hooks"][0]["command"] = "bash $HOME/.claude/hooks/altered.sh"
with open(sys.argv[1], "w") as settings_file:
    json.dump(settings, settings_file, indent=2)
    settings_file.write("\n")
PY
  if bash "$root/install-hooks.sh" --settings "$settings_file" --check >"$tmp_state/check-altered.out" 2>&1; then
    return 1
  fi
  check_output=$(cat "$tmp_state/check-altered.out") || return 1
  printf '%s' "$check_output" | grep -Fx 'Bash: wrong' >/dev/null
}

settings_missing_file_creates_minimal_settings() {
  local missing_settings_file="$tmp_state/missing-settings.json"
  bash "$root/install-hooks.sh" --settings "$missing_settings_file" >/dev/null || return 1
  python3 - "$missing_settings_file" "$root/settings-hooks.json" "$plugin_root" <<'PY' || return 1
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
with open(sys.argv[2]) as manifest_file:
    required = json.load(manifest_file)

assert set(settings) == {"env", "hooks"}
assert settings["env"] == {"CODEX_PLUGIN": sys.argv[3]}
assert settings["hooks"]["PostToolUse"] == required
PY
  [ ! -e "$missing_settings_file".backup.* ]
}

settings_codex_plugin_env_is_refreshed() {
  write_settings_fixture || return 1
  python3 - "$settings_file" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
settings["env"] = {"CODEX_PLUGIN": "/stale/plugin", "KEEP": "preserve"}
with open(sys.argv[1], "w") as settings_file:
    json.dump(settings, settings_file, indent=2)
    settings_file.write("\n")
PY
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  python3 - "$settings_file" "$plugin_root" <<'PY' || return 1
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
assert settings["env"] == {"CODEX_PLUGIN": sys.argv[2], "KEEP": "preserve"}
PY
}

settings_remove_cleans_codex_plugin_env() {
  write_settings_fixture || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" --remove >/dev/null || return 1
  python3 - "$settings_file" <<'PY' || return 1
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
assert "env" not in settings
PY

  write_settings_fixture || return 1
  python3 - "$settings_file" <<'PY' || return 1
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
settings["env"] = {"KEEP": "preserve"}
with open(sys.argv[1], "w") as settings_file:
    json.dump(settings, settings_file, indent=2)
    settings_file.write("\n")
PY
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  bash "$root/install-hooks.sh" --settings "$settings_file" --remove >/dev/null || return 1
  python3 - "$settings_file" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
assert settings["env"] == {"KEEP": "preserve"}
PY
}

settings_existing_file_without_hooks_is_merged() {
  write_settings_fixture || return 1
  python3 - "$settings_file" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
del settings["hooks"]
with open(sys.argv[1], "w") as settings_file:
    json.dump(settings, settings_file, indent=2)
    settings_file.write("\n")
PY
  bash "$root/install-hooks.sh" --settings "$settings_file" >/dev/null || return 1
  python3 - "$settings_file" "$root/settings-hooks.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
with open(sys.argv[2]) as manifest_file:
    required = json.load(manifest_file)

assert settings["permissions"] == {"allow": ["Bash(git status)"], "defaultMode": "auto"}
assert settings["enabledPlugins"] == {"example@marketplace": True}
assert settings["autoMode"] == {"allow": ["$defaults"]}
assert settings["hooks"]["PostToolUse"] == required
PY
}

record 'bd-ready fires: bd ready' bd_fires 'bd ready'
record 'bd-ready fires: foo; bd ready' bd_fires 'foo; bd ready'
record 'bd-ready fires: bd ready --json' bd_fires 'bd ready --json'
record 'bd-ready silent: bd readyfoo' bd_silent 'bd readyfoo'
record 'bd-ready silent: abd ready' bd_silent 'abd ready'
record 'bd-ready silent: bd list' bd_silent 'bd list'
record 'bd-ready silent: quoted phrase' bd_silent "printf 'bd ready'"
record 'model-routing data slugs exactly match the CLAUDE equivalence table' model_routing_table_matches_claude
record 'exitplan emits valid Codex-first JSON' exitplan_valid
record 'first-edit fires once: fresh session' first_edit_fires 'fresh-session'
record 'first-edit silent: repeated session' first_edit_silent 'fresh-session'
record 'first-edit fires: session alpha' first_edit_fires 'session-alpha'
record 'first-edit fires: session beta' first_edit_fires 'session-beta'
record 'first-edit silent: repeated alpha' first_edit_silent 'session-alpha'
record 'first-edit silent: repeated beta' first_edit_silent 'session-beta'
record 'vendor switch: openai disabled routes bd-ready to Claude only' bd_openai_disabled_routes_to_claude
record 'vendor switch: openai disabled exitplan forbids Codex' exitplan_openai_disabled_forbids_codex
record 'vendor switch: openai disabled first-edit is silent without burning the marker' first_edit_openai_disabled_is_silent
record 'vendor switch: first-edit is silent on an invalid or missing table' first_edit_invalid_table_is_silent
record 'vendor switch: local override wins over tracked default' vendor_local_override_wins
record 'vendor switch: unknown value fails closed' vendor_unknown_value_fails_closed
record 'vendor switch: missing config fails closed' vendor_missing_config_fails_closed
record 'vendor switch: anthropic cannot be disabled' vendor_anthropic_cannot_be_disabled
record 'vendor switch: tracked vendors.conf names openai with a valid state' tracked_vendors_conf_parses
record 'negative control: malformed JSON is rejected' broken_checker_fails
record 'settings install preserves unrelated keys and registers hooks' settings_install_preserves_unrelated
record 'settings second install is a no-op without backup' settings_second_install_is_noop
record 'settings wrong command is replaced without duplication' settings_wrong_command_is_replaced
record 'settings check detects missing registrations then passes' settings_check_detects_missing_then_passes
record 'settings remove preserves unrelated keys' settings_remove_preserves_unrelated
record 'settings malformed JSON is unchanged' settings_malformed_json_is_unchanged
record 'negative control: settings checker detects altered command' settings_negative_control_detects_altered_command
record 'settings missing file creates minimal registrations without backup' settings_missing_file_creates_minimal_settings
record 'settings existing file without hooks is merged safely' settings_existing_file_without_hooks_is_merged
record 'settings CODEX_PLUGIN env is refreshed without disturbing siblings' settings_codex_plugin_env_is_refreshed
record 'settings remove cleans only the owned CODEX_PLUGIN env' settings_remove_cleans_codex_plugin_env

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'HOOKS SELFTEST RESULT: PASS'
  completed=1; completed=1; exit 0
fi

printf '%s\n' 'HOOKS SELFTEST RESULT: FAIL'
completed=1; completed=1; exit 1
