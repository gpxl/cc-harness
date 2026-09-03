#!/usr/bin/env bash
# Hermetic checks for codex-jobs.sh: an unresolvable store is reported, never mistaken for "no jobs";
# --all-workspaces sees every plugin-data root, not only the one this session was launched with.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tool="$script_dir/codex-jobs.sh"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-jobs-selftest.XXXXXX") || exit 1
# A completion sentinel, not `$?`: on bash 3.2 (the system shell here) a script killed by
# set -e/set -u runs its EXIT trap with $? ALREADY RESET TO 0, so capturing the status in the
# trap is inert — measured. Only positive evidence that the suite reached its own verdict can
# distinguish a real pass from an abort. cch-85b; rules/verification-integrity.md.
completed=0
trap 'st=$?; rm -rf "$tmp_root"; [ "$completed" = 1 ] || st=1; exit $st' EXIT HUP INT TERM
failures=0

# Case 1: plugin root cannot be resolved -> non-zero exit and a stderr line, no stdout.
out="$tmp_root/unresolvable.out"; err="$tmp_root/unresolvable.err"
set +e
CODEX_PLUGIN=/nonexistent CODEX_PLUGIN_CACHE_DIR=/nonexistent bash "$tool" --cwd "$tmp_root" > "$out" 2> "$err"
code=$?
set -e
if [ "$code" -eq 0 ] || [ -s "$out" ] || ! grep -q 'unavailable' "$err"; then
  printf 'unresolvable store: exit=%s stdout=%s stderr=%s\n' "$code" "$(cat "$out")" "$(cat "$err")" >&2
  failures=$((failures + 1))
fi

# Case 2: two sibling plugin-data roots (two plugin installs) + an empty TMPDIR fallback.
data="$tmp_root/plugin-data"
mkdir -p "$data/codex-inline/state/ws-a-1111" "$data/codex-openai-codex/state/ws-b-2222" "$tmp_root/emptytmp"
printf '{"jobs":[{"id":"job-inline","status":"completed","pid":null,"sessionId":"s1","updatedAt":"2026-01-01T00:00:01Z","workspaceRoot":"/a"}]}\n' > "$data/codex-inline/state/ws-a-1111/state.json"
printf '{"jobs":[{"id":"job-other","status":"running","pid":null,"sessionId":"s2","updatedAt":"2026-01-01T00:00:02Z","workspaceRoot":"/b"}]}\n' > "$data/codex-openai-codex/state/ws-b-2222/state.json"
all="$tmp_root/all.out"
CLAUDE_PLUGIN_DATA="$data/codex-inline" TMPDIR="$tmp_root/emptytmp" bash "$tool" --all-workspaces > "$all" 2>&1 || { printf 'all-workspaces exited non-zero\n' >&2; failures=$((failures + 1)); }
grep -q '^job-inline ' "$all" || { printf 'own data root missing from --all-workspaces\n' >&2; failures=$((failures + 1)); }
grep -q '^job-other ' "$all" || { printf 'sibling data root missing from --all-workspaces\n' >&2; failures=$((failures + 1)); }

# Case 3: --active keeps queued/running only.
active="$tmp_root/active.out"
CLAUDE_PLUGIN_DATA="$data/codex-inline" TMPDIR="$tmp_root/emptytmp" bash "$tool" --all-workspaces --active > "$active" 2>&1 || true
if grep -q '^job-inline ' "$active" || ! grep -q '^job-other ' "$active"; then
  printf -- '--active filter wrong: %s\n' "$(cat "$active")" >&2; failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then printf '%s\n' 'CODEX JOBS SELFTEST: PASS'; completed=1; exit 0; fi
printf '%s\n' 'CODEX JOBS SELFTEST: FAIL'; completed=1; exit 1
