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
  [ -n "$output" ] && check_json "$output" && printf '%s' "$output" | grep -Fqi 'codex' && printf '%s' "$output" | grep -Fq "${MODEL_ROUTING_CODEX[$build_index]} at ${MODEL_ROUTING_EFFORT[$build_index]} effort" && ! printf '%s' "$output" | grep -Fq "$retired_opus" && ! printf '%s' "$output" | grep -Fq "$retired_sonnet" && ! printf '%s' "$output" | grep -Fq "$retired_gpt"
}

model_routing_table_matches_claude() {
  local data_file values_file index fallback
  data_file="$root/model-routing-table.sh"
  values_file="$tmp_state/model-routing-values"
  load_model_routing_table || return 1
  : > "$values_file" || return 1
  for ((index = 0; index < ${#MODEL_ROUTING_KEYS[@]}; index++)); do
    printf 'C|%s\n' "${MODEL_ROUTING_CODEX[$index]}" >> "$values_file" || return 1
    printf 'E|%s %s\n' "${MODEL_ROUTING_EFFORT[$index]}" "${MODEL_ROUTING_CLAUDE_EFFORT[$index]}" >> "$values_file" || return 1
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
expected_efforts = []
for line in open(values_path):
    kind, slug = line.rstrip("\n").split("|", 1)
    assert kind in {"C", "L", "E"}
    if kind == "E":
        expected_efforts.append(tuple(slug.split(" ")))
    else:
        expected.add(slug)
header = [cell.strip() for cell in table_lines[0].strip("|").split("|")]
codex_col, claude_col = header.index("Codex effort"), header.index("Claude effort")
table_efforts = []
for row in table_lines[2:]:
    cells = [cell.strip().strip("`") for cell in row.strip("|").split("|")]
    table_efforts.append((cells[codex_col], cells[claude_col]))
assert table_efforts == expected_efforts, ("table", table_efforts, "data", expected_efforts)
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
  printf '%s' "$output" | grep -Fq "${MODEL_ROUTING_CLAUDE_FALLBACKS[$build_index]} at ${MODEL_ROUTING_CLAUDE_EFFORT[$build_index]};" || return 1
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
  printf '%s' "$output" | grep -Fq "at ${MODEL_ROUTING_CLAUDE_EFFORT[$build_index]} effort" || return 1
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

# cch-ypu: the Codex-first mechanics live in a path-scoped rule. With openai primary every
# routing reminder must point at it; with openai disabled none may (route silently).
codex_rule_pointer='Read ~/.claude/rules/model-routing-codex.md'

routing_reminders_point_at_codex_rule_when_openai_primary() {
  output=$(printf '{"tool_input":{"command":"bd ready"}}' | bash "$root/bd-ready-model-routing.sh" 2>/dev/null) || return 1
  printf '%s' "$output" | grep -Fq "$codex_rule_pointer" || return 1
  output=$(bash "$root/exitplan-model-routing.sh" </dev/null 2>/dev/null) || return 1
  printf '%s' "$output" | grep -Fq "$codex_rule_pointer" || return 1
  output=$(printf '{"session_id":"%s"}' 'codex-rule-pointer-session' | bash "$root/first-edit-codex-gate.sh" 2>/dev/null) || return 1
  check_json "$output" && printf '%s' "$output" | grep -Fq "$codex_rule_pointer"
}

routing_reminders_omit_codex_rule_when_openai_disabled() {
  output=$(printf '{"tool_input":{"command":"bd ready"}}' | CC_HARNESS_VENDORS_FILE="$vendors_off" bash "$root/bd-ready-model-routing.sh" 2>/dev/null) || return 1
  [ -n "$output" ] || return 1
  printf '%s' "$output" | grep -Fq 'model-routing-codex' && return 1
  output=$(CC_HARNESS_VENDORS_FILE="$vendors_off" bash "$root/exitplan-model-routing.sh" </dev/null 2>/dev/null) || return 1
  [ -n "$output" ] || return 1
  printf '%s' "$output" | grep -Fq 'model-routing-codex' && return 1
  return 0
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
    manifest = json.load(manifest_file)
# The shipped manifest is the object form; its PostToolUse entries are what these rows check.
required = manifest["PostToolUse"] if isinstance(manifest, dict) else manifest
session_required = manifest.get("SessionStart", []) if isinstance(manifest, dict) else []

assert settings["$schema"] == "https://json.schemastore.org/claude-code-settings.json"
assert settings["permissions"] == {"allow": ["Bash(git status)"], "defaultMode": "auto"}
assert settings["enabledPlugins"] == {"example@marketplace": True}
assert settings["autoMode"] == {"allow": ["$defaults"]}
assert settings["hooks"]["SessionStart"] == [{"matcher": "", "hooks": [{"type": "command", "command": "echo session"}]}] + session_required
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
    manifest = json.load(manifest_file)
# The shipped manifest is the object form; its PostToolUse entries are what these rows check.
required = manifest["PostToolUse"] if isinstance(manifest, dict) else manifest
session_required = manifest.get("SessionStart", []) if isinstance(manifest, dict) else []

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
    manifest = json.load(manifest_file)
# The shipped manifest is the object form; its PostToolUse entries are what these rows check.
required = manifest["PostToolUse"] if isinstance(manifest, dict) else manifest
session_required = manifest.get("SessionStart", []) if isinstance(manifest, dict) else []

assert set(settings) == {"env", "hooks"}
assert settings["env"] == {"CODEX_PLUGIN": sys.argv[3]}
assert settings["hooks"]["PostToolUse"] == required
assert settings["hooks"].get("SessionStart", []) == session_required
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
    manifest = json.load(manifest_file)
# The shipped manifest is the object form; its PostToolUse entries are what these rows check.
required = manifest["PostToolUse"] if isinstance(manifest, dict) else manifest
session_required = manifest.get("SessionStart", []) if isinstance(manifest, dict) else []

assert settings["permissions"] == {"allow": ["Bash(git status)"], "defaultMode": "auto"}
assert settings["enabledPlugins"] == {"example@marketplace": True}
assert settings["autoMode"] == {"allow": ["$defaults"]}
assert settings["hooks"]["PostToolUse"] == required
PY
}

# --- Multi-event manifests (object form, SessionStart) -------------------------------------
# Hermetic: an isolated CC_HARNESS_CLAUDE_DIR and a fixture manifest; the real manifest and the
# real ~/.claude are never read. `ss_installer` is swapped for a mutant by the negative control.
ss_installer="$root/install-hooks.sh"
ss_dir="$tmp_state/claude-multi-event"
ss_settings="$ss_dir/settings.json"
ss_manifest="$tmp_state/multi-event-manifest.json"
mkdir -p "$ss_dir"
python3 - "$ss_manifest" <<'PY'
import json
import sys

manifest = {
    "PostToolUse": [
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash $HOME/.claude/hooks/fixture-post.sh", "timeout": 5}]},
    ],
    "SessionStart": [
        {"matcher": "startup|resume", "hooks": [{"type": "command", "command": "bash $HOME/.claude/hooks/fixture-session.sh", "timeout": 5}]},
        {"hooks": [{"type": "command", "command": "bash $HOME/.claude/hooks/fixture-session-any.sh"}]},
    ],
}
with open(sys.argv[1], "w") as manifest_file:
    json.dump(manifest, manifest_file, indent=2)
PY

ss_run() {
  CC_HARNESS_CLAUDE_DIR="$ss_dir" bash "$ss_installer" --manifest "$ss_manifest" "$@"
}

# User-owned entries that share an event and even a matcher with the manifest; none may move.
write_ss_settings_fixture() {
  python3 - "$ss_settings" <<'PY'
import json
import sys

settings = {
    "$schema": "https://json.schemastore.org/claude-code-settings.json",
    "permissions": {"allow": ["Bash(git status)"], "defaultMode": "auto"},
    "hooks": {
        "SessionStart": [
            {"matcher": "", "hooks": [{"type": "command", "command": "echo session"}]},
            {"matcher": "startup|resume", "hooks": [{"type": "command", "command": "echo user-resume"}]},
        ],
        "PostToolUse": [{"matcher": "Other", "hooks": [{"type": "command", "command": "echo other"}]}],
        "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}],
    },
}
with open(sys.argv[1], "w") as fixture:
    json.dump(settings, fixture, indent=2)
    fixture.write("\n")
PY
}

ss_backup_count() {
  local backup
  local count=0
  for backup in "$ss_settings".backup.*; do
    if [ -e "$backup" ]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

ss_registrations_are_present() {
  python3 - "$ss_settings" "$ss_manifest" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
with open(sys.argv[2]) as manifest_file:
    manifest = json.load(manifest_file)

assert settings["permissions"] == {"allow": ["Bash(git status)"], "defaultMode": "auto"}
hooks = settings["hooks"]
assert hooks["Stop"] == [{"hooks": [{"type": "command", "command": "echo stop"}]}]
session = hooks["SessionStart"]
assert session[0] == {"matcher": "", "hooks": [{"type": "command", "command": "echo session"}]}
assert session[1] == {"matcher": "startup|resume", "hooks": [{"type": "command", "command": "echo user-resume"}]}
assert len(session) == 2 + len(manifest["SessionStart"])
for entry in manifest["SessionStart"]:
    assert session.count(entry) == 1
post = hooks["PostToolUse"]
assert post[0] == {"matcher": "Other", "hooks": [{"type": "command", "command": "echo other"}]}
assert post[1:] == manifest["PostToolUse"]
PY
}

ss_install_registers_session_start() {
  local before_prefix after_prefix
  write_ss_settings_fixture || return 1
  before_prefix=$(sed '/^  "hooks":/,$d' "$ss_settings") || return 1
  ss_run >/dev/null || return 1
  after_prefix=$(sed '/^  "hooks":/,$d' "$ss_settings") || return 1
  [ "$after_prefix" = "$before_prefix" ] && ss_registrations_are_present
}

ss_second_install_is_noop() {
  local before backups_before
  write_ss_settings_fixture || return 1
  ss_run >/dev/null || return 1
  before=$(cat "$ss_settings") || return 1
  backups_before=$(ss_backup_count) || return 1
  ss_run >/dev/null || return 1
  [ "$(cat "$ss_settings")" = "$before" ] && [ "$(ss_backup_count)" -eq "$backups_before" ]
}

ss_check_missing_wrong_ok() {
  write_ss_settings_fixture || return 1
  if ss_run --check >"$tmp_state/ss-check-missing.out" 2>&1; then
    return 1
  fi
  grep -Fx 'SessionStart bash $HOME/.claude/hooks/fixture-session.sh: missing' "$tmp_state/ss-check-missing.out" >/dev/null || return 1
  grep -Fx 'SessionStart bash $HOME/.claude/hooks/fixture-session-any.sh: missing' "$tmp_state/ss-check-missing.out" >/dev/null || return 1
  ss_run >/dev/null || return 1
  ss_run --check >"$tmp_state/ss-check-ok.out" 2>&1 || return 1
  python3 - "$ss_settings" <<'PY' || return 1
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
for entry in settings["hooks"]["SessionStart"]:
    if entry["hooks"][0]["command"] == "bash $HOME/.claude/hooks/fixture-session.sh":
        entry["hooks"][0]["timeout"] = 99
with open(sys.argv[1], "w") as settings_file:
    json.dump(settings, settings_file, indent=2)
    settings_file.write("\n")
PY
  if ss_run --check >"$tmp_state/ss-check-wrong.out" 2>&1; then
    return 1
  fi
  grep -Fx 'SessionStart bash $HOME/.claude/hooks/fixture-session.sh: wrong' "$tmp_state/ss-check-wrong.out" >/dev/null || return 1
  # Only the altered entry is reported; the untouched ones still verify.
  [ "$(wc -l < "$tmp_state/ss-check-wrong.out" | tr -d ' ')" = 1 ]
}

ss_install_replaces_and_dedupes_by_command() {
  write_ss_settings_fixture || return 1
  python3 - "$ss_settings" <<'PY' || return 1
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
stale = {"matcher": "startup", "hooks": [{"type": "command", "command": "bash $HOME/.claude/hooks/fixture-session.sh", "timeout": 1}]}
settings["hooks"]["SessionStart"].extend([stale, dict(stale, matcher="resume")])
with open(sys.argv[1], "w") as settings_file:
    json.dump(settings, settings_file, indent=2)
    settings_file.write("\n")
PY
  ss_run >/dev/null || return 1
  ss_registrations_are_present
}

ss_remove_only_owned_entries() {
  write_ss_settings_fixture || return 1
  ss_run >/dev/null || return 1
  # A user-modified copy of an owned command is not identical to the manifest: it stays.
  python3 - "$ss_settings" <<'PY' || return 1
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
settings["hooks"]["SessionStart"].append(
    {"matcher": "clear", "hooks": [{"type": "command", "command": "bash $HOME/.claude/hooks/fixture-session-any.sh", "timeout": 7}]}
)
with open(sys.argv[1], "w") as settings_file:
    json.dump(settings, settings_file, indent=2)
    settings_file.write("\n")
PY
  ss_run --remove >/dev/null || return 1
  python3 - "$ss_settings" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
hooks = settings["hooks"]
assert settings["permissions"] == {"allow": ["Bash(git status)"], "defaultMode": "auto"}
assert hooks["SessionStart"] == [
    {"matcher": "", "hooks": [{"type": "command", "command": "echo session"}]},
    {"matcher": "startup|resume", "hooks": [{"type": "command", "command": "echo user-resume"}]},
    {"matcher": "clear", "hooks": [{"type": "command", "command": "bash $HOME/.claude/hooks/fixture-session-any.sh", "timeout": 7}]},
]
assert hooks["PostToolUse"] == [{"matcher": "Other", "hooks": [{"type": "command", "command": "echo other"}]}]
assert hooks["Stop"] == [{"hooks": [{"type": "command", "command": "echo stop"}]}]
PY
}

ss_legacy_array_equals_object_post_tool_use() {
  local legacy_manifest="$tmp_state/legacy-array-manifest.json"
  local object_manifest="$tmp_state/object-post-manifest.json"
  python3 - "$ss_manifest" "$legacy_manifest" "$object_manifest" <<'PY' || return 1
import json
import sys

with open(sys.argv[1]) as manifest_file:
    post = json.load(manifest_file)["PostToolUse"]
with open(sys.argv[2], "w") as legacy:
    json.dump(post, legacy)
with open(sys.argv[3], "w") as obj:
    json.dump({"PostToolUse": post}, obj)
PY
  write_ss_settings_fixture || return 1
  CC_HARNESS_CLAUDE_DIR="$ss_dir" bash "$ss_installer" --manifest "$legacy_manifest" >/dev/null || return 1
  cp "$ss_settings" "$tmp_state/legacy-result.json" || return 1
  CC_HARNESS_CLAUDE_DIR="$ss_dir" bash "$ss_installer" --manifest "$legacy_manifest" --check >/dev/null || return 1
  write_ss_settings_fixture || return 1
  CC_HARNESS_CLAUDE_DIR="$ss_dir" bash "$ss_installer" --manifest "$object_manifest" >/dev/null || return 1
  cmp -s "$ss_settings" "$tmp_state/legacy-result.json" || return 1
  # The array form registers PostToolUse only: SessionStart stays exactly the user's two entries.
  python3 - "$ss_settings" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
assert len(settings["hooks"]["SessionStart"]) == 2
assert settings["hooks"]["PostToolUse"][1]["matcher"] == "Bash"
PY
}

ss_malformed_manifest_is_rejected() {
  local bad_manifest="$tmp_state/bad-session-manifest.json"
  local before
  printf '%s\n' '{"SessionStart": [{"matcher": "startup", "hooks": [{"type": "prompt", "prompt": "x"}]}]}' > "$bad_manifest" || return 1
  write_ss_settings_fixture || return 1
  before=$(cat "$ss_settings") || return 1
  if CC_HARNESS_CLAUDE_DIR="$ss_dir" bash "$ss_installer" --manifest "$bad_manifest" >"$tmp_state/ss-bad.out" 2>&1; then
    return 1
  fi
  grep -F 'SessionStart entries must have command hooks' "$tmp_state/ss-bad.out" >/dev/null || return 1
  [ "$(cat "$ss_settings")" = "$before" ]
}

ss_remove_drops_emptied_session_start() {
  write_ss_settings_fixture || return 1
  python3 - "$ss_settings" <<'PY' || return 1
import json
import sys

with open(sys.argv[1]) as settings_file:
    settings = json.load(settings_file)
del settings["hooks"]["SessionStart"]
del settings["hooks"]["PostToolUse"]
with open(sys.argv[1], "w") as settings_file:
    json.dump(settings, settings_file, indent=2)
    settings_file.write("\n")
PY
  ss_run >/dev/null || return 1
  ss_run --remove >/dev/null || return 1
  python3 - "$ss_settings" <<'PY'
import json
import sys

with open(sys.argv[1]) as settings_file:
    hooks = json.load(settings_file)["hooks"]
assert "SessionStart" not in hooks          # non-tool event emptied by --remove: key dropped
assert hooks["PostToolUse"] == []           # tool event: legacy behaviour, emptied list kept
assert hooks["Stop"] == [{"hooks": [{"type": "command", "command": "echo stop"}]}]
PY
}

# Negative controls: a mutant installer with one piece of the event handling removed must turn
# the named row red. The mutation anchor must match exactly once, or the control is vacuous.
ss_mutant_turns_row_red() {
  local anchor="$1" replacement="$2" row="$3"
  local mutant_dir="$tmp_state/mutant-hooks"
  local verdict=0
  mkdir -p "$mutant_dir" || return 1
  python3 - "$root/install-hooks.sh" "$mutant_dir/install-hooks.sh" "$anchor" "$replacement" <<'PY' || return 1
import sys

source = open(sys.argv[1]).read()
anchor = sys.argv[3] + "\n"
if source.count(anchor) != 1:
    sys.exit("mutation anchor not found exactly once; the control would be vacuous")
open(sys.argv[2], "w").write(source.replace(anchor, sys.argv[4] + "\n"))
PY
  ss_installer="$mutant_dir/install-hooks.sh"
  if "$row" >/dev/null 2>&1; then
    verdict=1
  fi
  ss_installer="$root/install-hooks.sh"
  return "$verdict"
}

ss_negative_control_without_event_handling() {
  ss_mutant_turns_row_red \
    '    manifest_events = list(raw_manifest.items())' \
    '    manifest_events = [("PostToolUse", raw_manifest.get("PostToolUse", []))]' \
    ss_install_registers_session_start
}

ss_negative_control_check_without_event_handling() {
  ss_mutant_turns_row_red \
    '        existing = event_list(event) or []' \
    '        existing = (event_list(event) or []) if event in TOOL_EVENTS else []' \
    ss_check_missing_wrong_ok
}

ss_negative_control_remove_without_event_handling() {
  ss_mutant_turns_row_red \
    '        owned = set(json.dumps(entry, sort_keys=True, separators=(",", ":")) for entry in entries)' \
    '        if event not in TOOL_EVENTS: continue
        owned = set(json.dumps(entry, sort_keys=True, separators=(",", ":")) for entry in entries)' \
    ss_remove_only_owned_entries
}

ss_negative_control_remove_keeps_empty_key() {
  ss_mutant_turns_row_red \
    '            if retained or event in TOOL_EVENTS:' \
    '            if True:' \
    ss_remove_drops_emptied_session_start
}

# --- SessionStart vendor-state hook (cch-1ry) ----------------------------------------------
# `vendor_state_hook` is swapped for a mutant by the negative controls below.
vendor_state_hook="$root/vendor-state.sh"

invoke_vendor_state() {
  output=$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$vendor_state_hook" 2>/dev/null) || return 1
}

vendor_state_disabled_emits_one_line() {
  local lines
  output=$(printf '{"source":"startup"}' | CC_HARNESS_VENDORS_FILE="$vendors_off" bash "$vendor_state_hook" 2>/dev/null) || return 1
  lines=$(printf '%s\n' "$output" | wc -l | tr -d ' ') || return 1
  [ "$lines" = 1 ] || return 1
  printf '%s' "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert set(data) == {"hookSpecificOutput"}
out = data["hookSpecificOutput"]
assert out["hookEventName"] == "SessionStart"
text = out["additionalContext"]
assert "openai disabled by config" in text, text
assert "bash ~/.claude/hooks/vendors.sh" in text
assert "Claude column" in text
assert "no readiness check" in text
assert len(text.split()) <= 40, len(text.split())
' >/dev/null 2>&1
}

vendor_state_all_enabled_is_silent() {
  invoke_vendor_state && [ -z "$output" ]
}

vendor_state_unreadable_config_is_silent() {
  output=$(CC_HARNESS_VENDORS_FILE="$tmp_state/does-not-exist.conf" bash "$vendor_state_hook" </dev/null 2>/dev/null) || return 1
  [ -z "$output" ] || return 1
  # A config that exists but names no routing vendor is no evidence either.
  printf 'anthropic=enabled\n' > "$tmp_state/vendors-anthropic-only.conf" || return 1
  output=$(CC_HARNESS_VENDORS_FILE="$tmp_state/vendors-anthropic-only.conf" bash "$vendor_state_hook" </dev/null 2>/dev/null) || return 1
  [ -z "$output" ]
}

vendor_state_local_override_is_reported() {
  printf 'openai=disabled\n' > "$tmp_state/vendors-local-off.conf" || return 1
  output=$(CC_HARNESS_VENDORS_LOCAL="$tmp_state/vendors-local-off.conf" bash "$vendor_state_hook" </dev/null 2>/dev/null) || return 1
  printf '%s' "$output" | grep -Fq 'openai disabled by config'
}

vendor_state_invalid_table_is_silent() {
  local copy="$tmp_state/degraded-vendor-state"
  mkdir -p "$copy" || return 1
  cp "$root/vendor-state.sh" "$root/vendors.sh" "$root/model-routing-table.sh" "$copy/" || return 1
  printf 'MODEL_ROUTING_VENDOR_COLUMNS[0]=%s\n' "'MODEL_ROUTING_X;true'" >> "$copy/model-routing-table.sh" || return 1
  output=$(CC_HARNESS_VENDORS_FILE="$vendors_off" bash "$copy/vendor-state.sh" </dev/null 2>/dev/null) || return 1
  [ -z "$output" ] || return 1
  rm -f "$copy/model-routing-table.sh" || return 1
  output=$(CC_HARNESS_VENDORS_FILE="$vendors_off" bash "$copy/vendor-state.sh" </dev/null 2>/dev/null) || return 1
  [ -z "$output" ]
}

# The SHIPPED manifest (not a fixture) into an isolated Claude dir: the real ~/.claude is untouched.
vendor_state_shipped_manifest_round_trip() {
  local dir="$tmp_state/claude-shipped"
  rm -rf "$dir" && mkdir -p "$dir" || return 1
  CC_HARNESS_CLAUDE_DIR="$dir" bash "$root/install-hooks.sh" >/dev/null 2>&1 || return 1
  python3 - "$dir/settings.json" "$root/settings-hooks.json" <<'PY' || return 1
import json
import sys

settings = json.load(open(sys.argv[1]))
manifest = json.load(open(sys.argv[2]))
session = manifest["SessionStart"]
assert [entry["hooks"][0]["command"] for entry in session] == ["bash $HOME/.claude/hooks/vendor-state.sh"]
# Re-injected after /clear and compaction, which drop the earlier context.
assert [entry["matcher"] for entry in session] == ["startup|resume|clear|compact"]
assert settings["hooks"]["SessionStart"] == session
assert settings["hooks"]["PostToolUse"] == manifest["PostToolUse"]
PY
  CC_HARNESS_CLAUDE_DIR="$dir" bash "$root/install-hooks.sh" --check >/dev/null 2>&1 || return 1
  CC_HARNESS_CLAUDE_DIR="$dir" bash "$root/install-hooks.sh" --remove >/dev/null 2>&1 || return 1
  python3 - "$dir/settings.json" <<'PY' || return 1
import json
import sys

settings = json.load(open(sys.argv[1]))
assert "SessionStart" not in settings["hooks"]
assert settings["hooks"]["PostToolUse"] == []
PY
  # After --remove, --check must go red again: the check can fail.
  if CC_HARNESS_CLAUDE_DIR="$dir" bash "$root/install-hooks.sh" --check >"$tmp_state/shipped-check.out" 2>&1; then
    return 1
  fi
  grep -Fx 'SessionStart bash $HOME/.claude/hooks/vendor-state.sh: missing' "$tmp_state/shipped-check.out" >/dev/null
}

# Negative controls: a mutant hook missing one guard must turn the named row red.
vendor_state_mutant_turns_row_red() {
  local anchor="$1" replacement="$2" row="$3"
  local mutant_dir="$tmp_state/mutant-vendor-state"
  local verdict=0
  mkdir -p "$mutant_dir" || return 1
  cp "$root/vendors.sh" "$root/model-routing-table.sh" "$mutant_dir/" || return 1
  python3 - "$root/vendor-state.sh" "$mutant_dir/vendor-state.sh" "$anchor" "$replacement" <<'PY' || return 1
import sys

source = open(sys.argv[1]).read()
anchor = sys.argv[3] + "\n"
if source.count(anchor) != 1:
    sys.exit("mutation anchor not found exactly once; the control would be vacuous")
open(sys.argv[2], "w").write(source.replace(anchor, sys.argv[4] + "\n"))
PY
  vendor_state_hook="$mutant_dir/vendor-state.sh"
  if "$row" >/dev/null 2>&1; then
    verdict=1
  fi
  vendor_state_hook="$root/vendor-state.sh"
  return "$verdict"
}

vendor_state_negative_control_prints_when_enabled() {
  vendor_state_mutant_turns_row_red \
    '[ "$disabled" = none ] && exit 0' \
    ':' \
    vendor_state_all_enabled_is_silent
}

vendor_state_negative_control_without_evidence_guard() {
  vendor_state_mutant_turns_row_red \
    "  [ \"\$(vendor_source \"\$vendor\")\" = '(not configured)' ] && exit 0" \
    '  :' \
    vendor_state_unreadable_config_is_silent
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
record 'codex rule pointer: every routing reminder names model-routing-codex.md when openai is primary' routing_reminders_point_at_codex_rule_when_openai_primary
record 'codex rule pointer: no routing reminder names it while openai is disabled' routing_reminders_omit_codex_rule_when_openai_disabled
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
record 'multi-event install registers SessionStart beside user entries' ss_install_registers_session_start
record 'multi-event second install is a no-op without backup' ss_second_install_is_noop
record 'multi-event check reports missing, then ok, then wrong' ss_check_missing_wrong_ok
record 'multi-event install replaces and dedupes SessionStart by command' ss_install_replaces_and_dedupes_by_command
record 'multi-event remove deletes only entries identical to the manifest' ss_remove_only_owned_entries
record 'legacy array manifest behaves as PostToolUse object form' ss_legacy_array_equals_object_post_tool_use
record 'multi-event manifest without command hooks is rejected unchanged' ss_malformed_manifest_is_rejected
record 'multi-event remove drops an emptied SessionStart key, keeps legacy PostToolUse []' ss_remove_drops_emptied_session_start
record 'negative control: SessionStart row fails without event handling' ss_negative_control_without_event_handling
record 'negative control: check row fails without event handling' ss_negative_control_check_without_event_handling
record 'negative control: remove row fails without event handling' ss_negative_control_remove_without_event_handling
record 'negative control: emptied-key row fails if the key is kept' ss_negative_control_remove_keeps_empty_key
record 'vendor-state: openai disabled emits exactly one valid SessionStart JSON line' vendor_state_disabled_emits_one_line
record 'vendor-state: silent when every vendor is enabled' vendor_state_all_enabled_is_silent
record 'vendor-state: silent when no config names the vendor' vendor_state_unreadable_config_is_silent
record 'vendor-state: a machine-local disable is reported' vendor_state_local_override_is_reported
record 'vendor-state: silent on an invalid or missing table' vendor_state_invalid_table_is_silent
record 'vendor-state: shipped manifest installs, checks ok, removes clean into an isolated dir' vendor_state_shipped_manifest_round_trip
record 'negative control: enabled-silent row fails when the hook prints regardless' vendor_state_negative_control_prints_when_enabled
record 'negative control: no-evidence row fails without the evidence guard' vendor_state_negative_control_without_evidence_guard

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'HOOKS SELFTEST RESULT: PASS'
  completed=1; completed=1; exit 0
fi

printf '%s\n' 'HOOKS SELFTEST RESULT: FAIL'
completed=1; completed=1; exit 1
