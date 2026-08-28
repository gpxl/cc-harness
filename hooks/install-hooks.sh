#!/usr/bin/env bash
# Merge cc-harness's PostToolUse hook registrations into a Claude settings file.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
claude_dir="${CC_HARNESS_CLAUDE_DIR:-${HOME}/.claude}"
settings_path="${claude_dir}/settings.json"
mode='install'

usage() {
  printf '%s\n' 'Usage: hooks/install-hooks.sh [--settings <path>] [--check] [--remove]'
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

exec python3 - "$settings_path" "$mode" "$root/settings-hooks.json" "$codex_plugin" <<'PY'
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

try:
    with open(manifest_path, "r") as manifest_file:
        required = json.load(manifest_file)
except (OSError, ValueError) as error:
    fail("cannot read hook manifest: " + str(error))

if not isinstance(required, list) or not all(
    isinstance(entry, dict) and isinstance(entry.get("matcher"), str)
    for entry in required
):
    fail("hook manifest must be an array of entries with matchers")

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
if hooks is None:
    if mode == "check":
        for entry in required:
            print(entry["matcher"] + ": missing")
        sys.exit(1)
    if mode == "remove":
        post_tool_use = []
    else:
        hooks = {}
        settings["hooks"] = hooks
elif not isinstance(hooks, dict):
    fail("settings hooks value must be an object")

if hooks is not None:
    post_tool_use = hooks.get("PostToolUse")
    if post_tool_use is None:
        if mode == "check":
            for entry in required:
                print(entry["matcher"] + ": missing")
            sys.exit(1)
        if mode == "remove":
            post_tool_use = []
        else:
            post_tool_use = []
            hooks["PostToolUse"] = post_tool_use
    elif not isinstance(post_tool_use, list):
        fail("settings hooks.PostToolUse value must be an array")


def entries_for(matcher):
    return [entry for entry in post_tool_use if isinstance(entry, dict) and entry.get("matcher") == matcher]


if mode == "check":
    failures = 0
    for entry in required:
        matching = entries_for(entry["matcher"])
        if not matching:
            print(entry["matcher"] + ": missing")
            failures += 1
        elif len(matching) != 1 or matching[0] != entry:
            print(entry["matcher"] + ": wrong")
            failures += 1
    if failures:
        sys.exit(1)
    print("Hook registrations verified.")
    sys.exit(0)

changed = False
env_changed = False
if mode == "remove":
    owned = set()
    for entry in required:
        owned.add(json.dumps(entry, sort_keys=True, separators=(",", ":")))
    retained = []
    for entry in post_tool_use:
        fingerprint = json.dumps(entry, sort_keys=True, separators=(",", ":"))
        if fingerprint in owned:
            changed = True
        else:
            retained.append(entry)
    if changed:
        hooks["PostToolUse"] = retained
else:
    for entry in required:
        matcher = entry["matcher"]
        indices = [
            index for index, candidate in enumerate(post_tool_use)
            if isinstance(candidate, dict) and candidate.get("matcher") == matcher
        ]
        if not indices:
            post_tool_use.append(entry)
            changed = True
            continue
        first = indices[0]
        if post_tool_use[first] != entry:
            post_tool_use[first] = entry
            changed = True
        for index in reversed(indices[1:]):
            del post_tool_use[index]
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
