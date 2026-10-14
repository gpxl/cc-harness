#!/usr/bin/env bash
# Merge cc-harness's hook registrations (PostToolUse, SessionStart, ...) into a Claude settings file.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
claude_dir="${CC_HARNESS_CLAUDE_DIR:-${HOME}/.claude}"
settings_path="${claude_dir}/settings.json"
mode='install'
manifest_path="${root}/settings-hooks.json"

usage() {
  printf '%s\n' 'Usage: hooks/install-hooks.sh [--settings <path>] [--manifest <path>] [--check] [--remove]'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --settings)
      if [ "$#" -lt 2 ]; then
        usage >&2
        exit 2
      fi
      settings_path="$2"
      shift 2
      ;;
    --manifest)
      if [ "$#" -lt 2 ]; then
        usage >&2
        exit 2
      fi
      manifest_path="$2"
      shift 2
      ;;
    --check)
      mode='check'
      shift
      ;;
    --remove)
      mode='remove'
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

codex_plugin=''
if [ "$mode" = 'install' ]; then
  if ! codex_plugin=$(bash "$root/../scripts/codex-plugin-root.sh" 2>/dev/null); then
    printf '%s\n' 'CODEX_PLUGIN resolver unavailable; skipping settings env update.'
    codex_plugin=''
  fi
fi

exec python3 - "$settings_path" "$mode" "$manifest_path" "$codex_plugin" <<'PY'
import datetime
import json
import os
import shutil
import sys
import tempfile


def fail(message):
    print("install-hooks.sh: " + message, file=sys.stderr)
    sys.exit(2)


settings_path, mode, manifest_path, codex_plugin = sys.argv[1:]

# Tool events key an entry by its matcher (the tool name): the manifest owns that matcher slot.
# Every other event (SessionStart, Stop, ...) keys an entry by the commands it runs, because
# matchers there ("", "startup|resume") are shared with the user's own entries.
TOOL_EVENTS = ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest")


def commands_of(entry):
    hook_list = entry.get("hooks") if isinstance(entry, dict) else None
    if not isinstance(hook_list, list) or not hook_list:
        return None
    commands = []
    for hook in hook_list:
        if not isinstance(hook, dict) or not isinstance(hook.get("command"), str):
            return None
        commands.append(hook["command"])
    return tuple(commands)


def identity(event, entry):
    if not isinstance(entry, dict):
        return None
    if event in TOOL_EVENTS:
        matcher = entry.get("matcher")
        return ("matcher", matcher) if isinstance(matcher, str) else None
    commands = commands_of(entry)
    return ("commands", commands) if commands else None


def label(event, entry):
    if event == "PostToolUse":
        return entry["matcher"]  # legacy --check output: "<matcher>: missing"
    if event in TOOL_EVENTS:
        return event + " " + entry["matcher"]
    return event + " " + " && ".join(commands_of(entry))


try:
    with open(manifest_path, "r") as manifest_file:
        raw_manifest = json.load(manifest_file)
except (OSError, ValueError) as error:
    fail("cannot read hook manifest: " + str(error))

# Legacy form: a bare array means PostToolUse entries. Object form: {"<Event>": [entries]}.
if isinstance(raw_manifest, list):
    manifest_events = [("PostToolUse", raw_manifest)]
elif isinstance(raw_manifest, dict):
    manifest_events = list(raw_manifest.items())
else:
    fail("hook manifest must be an array of PostToolUse entries or an object of event arrays")

for event, entries in manifest_events:
    if not event or not isinstance(entries, list):
        fail("hook manifest event " + json.dumps(event) + " must map to an array of entries")
    seen = set()
    for entry in entries:
        key = identity(event, entry)
        if key is None:
            if event in TOOL_EVENTS:
                fail("hook manifest " + event + " entries must have string matchers")
            fail("hook manifest " + event + " entries must have command hooks")
        if key in seen:
            fail("hook manifest " + event + " has two entries with the same identity")
        seen.add(key)

exists = os.path.exists(settings_path)
if exists:
    try:
        with open(settings_path, "r") as settings_file:
            original_text = settings_file.read()
        settings = json.loads(original_text)
    except (OSError, ValueError) as error:
        fail("cannot parse settings JSON at " + settings_path + ": " + str(error))
    if not isinstance(settings, dict):
        fail("settings JSON at " + settings_path + " must be an object")
else:
    settings = {}
    original_text = ""

hooks = settings.get("hooks")
if hooks is not None and not isinstance(hooks, dict):
    fail("settings hooks value must be an object")


def event_list(event):
    existing = hooks.get(event) if hooks is not None else None
    if existing is not None and not isinstance(existing, list):
        fail("settings hooks." + event + " value must be an array")
    return existing


if mode == "check":
    failures = 0
    for event, entries in manifest_events:
        existing = event_list(event) or []
        for entry in entries:
            key = identity(event, entry)
            matching = [candidate for candidate in existing if identity(event, candidate) == key]
            if not matching:
                print(label(event, entry) + ": missing")
                failures += 1
            elif len(matching) != 1 or matching[0] != entry:
                print(label(event, entry) + ": wrong")
                failures += 1
    if failures:
        sys.exit(1)
    print("Hook registrations verified.")
    sys.exit(0)

changed = False
env_changed = False
if mode == "remove":
    for event, entries in manifest_events:
        existing = event_list(event)
        if existing is None:
            continue
        owned = set(json.dumps(entry, sort_keys=True, separators=(",", ":")) for entry in entries)
        retained = []
        removed = False
        for candidate in existing:
            if json.dumps(candidate, sort_keys=True, separators=(",", ":")) in owned:
                removed = True
            else:
                retained.append(candidate)
        if removed:
            hooks[event] = retained
            changed = True
else:
    for event, entries in manifest_events:
        if not entries:
            continue
        existing = event_list(event)
        if existing is None:
            if hooks is None:
                hooks = {}
                settings["hooks"] = hooks
            existing = []
            hooks[event] = existing
        for entry in entries:
            key = identity(event, entry)
            indices = [
                index for index, candidate in enumerate(existing)
                if identity(event, candidate) == key
            ]
            if not indices:
                existing.append(entry)
                changed = True
                continue
            first = indices[0]
            if existing[first] != entry:
                existing[first] = entry
                changed = True
            for index in reversed(indices[1:]):
                del existing[index]
                changed = True

if mode != "check":
    env = settings.get("env")
    if env is not None and not isinstance(env, dict):
        fail("settings env value must be an object")
    if mode == "remove":
        if isinstance(env, dict) and "CODEX_PLUGIN" in env:
            del env["CODEX_PLUGIN"]
            changed = True
            env_changed = True
            if not env:
                del settings["env"]
    elif codex_plugin:
        if env is None:
            env = {}
            settings["env"] = env
        if env.get("CODEX_PLUGIN") != codex_plugin:
            env["CODEX_PLUGIN"] = codex_plugin
            changed = True
            env_changed = True

if not changed:
    if mode == "remove":
        print("Hook registrations already absent.")
    else:
        print("Hook registrations already current (no change).")
    sys.exit(0)


def hooks_value_span(text):
    """Return the raw value span for the sole root-level hooks key, if present."""
    decoder = json.JSONDecoder()
    length = len(text)
    index = 0

    def skip_whitespace(position):
        while position < length and text[position] in " \t\r\n":
            position += 1
        return position

    index = skip_whitespace(index)
    if index >= length or text[index] != "{":
        return None
    index += 1
    found = None
    while True:
        index = skip_whitespace(index)
        if index >= length or text[index] == "}":
            break
        key, index = decoder.raw_decode(text, index)
        index = skip_whitespace(index)
        if index >= length or text[index] != ":":
            fail("cannot locate hooks entry in settings JSON")
        index = skip_whitespace(index + 1)
        value_start = index
        _, index = decoder.raw_decode(text, index)
        if key == "hooks":
            if found is not None:
                fail("settings JSON contains duplicate root hooks keys")
            found = (value_start, index)
        index = skip_whitespace(index)
        if index < length and text[index] == ",":
            index += 1
            continue
        if index < length and text[index] == "}":
            break
        fail("cannot locate hooks entry in settings JSON")
    return found


def render_settings():
    if env_changed:
        return json.dumps(settings, indent=2, ensure_ascii=True) + "\n"

    # When hooks already exists, splice only its JSON value into the original
    # text. This preserves every unrelated settings key byte-for-byte.
    span = hooks_value_span(original_text) if exists else None
    if span is not None:
        value_start, value_end = span
        line_start = original_text.rfind("\n", 0, value_start) + 1
        line_prefix = original_text[line_start:value_start]
        indentation = line_prefix[:len(line_prefix) - len(line_prefix.lstrip(" \t"))]
        rendered_hooks = json.dumps(hooks, indent=2, ensure_ascii=True)
        rendered_hooks = rendered_hooks.replace("\n", "\n" + indentation)
        return original_text[:value_start] + rendered_hooks + original_text[value_end:]
    if not exists:
        return json.dumps(settings, indent=2, ensure_ascii=True) + "\n"

    # A pre-existing settings file without hooks still keeps its other raw
    # keys. Appending the new key is the only necessary change outside hooks.
    decoder = json.JSONDecoder()
    start = 0
    while original_text[start] in " \t\r\n":
        start += 1
    _, end = decoder.raw_decode(original_text, start)
    close = end - 1
    content_end = close
    while content_end > start and original_text[content_end - 1] in " \t\r\n":
        content_end -= 1
    rendered_hooks = json.dumps(hooks, indent=2, ensure_ascii=True)
    rendered_hooks = rendered_hooks.replace("\n", "\n  ")
    if original_text[start + 1:content_end].strip():
        return (
            original_text[:content_end]
            + ",\n  \"hooks\": "
            + rendered_hooks
            + original_text[content_end:]
        )
    return (
        original_text[:start + 1]
        + "\n  \"hooks\": "
        + rendered_hooks
        + "\n"
        + original_text[close:]
    )

directory = os.path.dirname(os.path.abspath(settings_path))
if not os.path.isdir(directory):
    os.makedirs(directory)

rendered_settings = render_settings()

if exists:
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_path = settings_path + ".backup." + timestamp
    suffix = 1
    while os.path.exists(backup_path):
        backup_path = settings_path + ".backup." + timestamp + "." + str(suffix)
        suffix += 1
    shutil.copy2(settings_path, backup_path)

file_descriptor, temporary_path = tempfile.mkstemp(prefix=".settings.json.", dir=directory)
try:
    with os.fdopen(file_descriptor, "w") as temporary_file:
        temporary_file.write(rendered_settings)
    os.replace(temporary_path, settings_path)
except BaseException:
    try:
        os.unlink(temporary_path)
    except OSError:
        pass
    raise

if mode == "remove":
    print("Hook registrations removed.")
else:
    print("Hook registrations installed.")
PY
