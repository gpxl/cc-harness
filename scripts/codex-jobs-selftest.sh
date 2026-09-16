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

# Case 4: a queued/running record whose tracked pid is dead is an ORPHAN, not active. The pid is a
# real one that has exited, so the check is against the live process table, not a sentinel value.
dead_root="$tmp_root/dead-data"
mkdir -p "$dead_root/codex-inline/state/ws-c-3333"
dead_pid=$( (exec bash -c 'exit 0') & printf '%s' "$!" ); wait "$dead_pid" 2>/dev/null || true
live_pid=$$
printf '{"jobs":[{"id":"job-dead","status":"running","pid":%s,"sessionId":"s3","updatedAt":"2026-01-01T00:00:03Z","workspaceRoot":"/c"},{"id":"job-live","status":"running","pid":%s,"sessionId":"s4","updatedAt":"2026-01-01T00:00:04Z","workspaceRoot":"/c"}]}\n' \
  "$dead_pid" "$live_pid" > "$dead_root/codex-inline/state/ws-c-3333/state.json"

dead_out="$tmp_root/dead-active.out"
CLAUDE_PLUGIN_DATA="$dead_root/codex-inline" TMPDIR="$tmp_root/emptytmp" bash "$tool" --all-workspaces --active > "$dead_out" 2>&1 || true
if grep -q '^job-dead ' "$dead_out"; then
  printf -- '--active listed a job whose pid is dead: %s\n' "$(cat "$dead_out")" >&2; failures=$((failures + 1))
fi
if ! grep -q '^job-live ' "$dead_out"; then
  printf -- '--active dropped a job whose pid is alive: %s\n' "$(cat "$dead_out")" >&2; failures=$((failures + 1))
fi
# Omissions are counted out loud: a filter that hid them would make an orphan look like no work.
if ! grep -q '1 orphaned record(s) omitted' "$dead_out"; then
  printf -- '--active did not report the omitted orphan: %s\n' "$(cat "$dead_out")" >&2; failures=$((failures + 1))
fi

# Without --active the same record is still listed, annotated dead: the filter is for --active only.
all_dead="$tmp_root/dead-all.out"
CLAUDE_PLUGIN_DATA="$dead_root/codex-inline" TMPDIR="$tmp_root/emptytmp" bash "$tool" --all-workspaces > "$all_dead" 2>&1 || true
grep -q "^job-dead running - $dead_pid(dead) " "$all_dead" || {
  printf 'full listing lost the dead record or its annotation: %s\n' "$(cat "$all_dead")" >&2; failures=$((failures + 1)); }

# --json carries the liveness verdict and applies the same filter, since codex-dispatch.sh's
# duplicate-job check reads it and must not be blocked by a worker that died days ago.
dead_json="$tmp_root/dead-active.json"
CLAUDE_PLUGIN_DATA="$dead_root/codex-inline" TMPDIR="$tmp_root/emptytmp" bash "$tool" --all-workspaces --active --json > "$dead_json" 2>/dev/null || true
if ! node -e '
const jobs = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const ids = jobs.map((job) => job.id);
if (ids.includes("job-dead") || !ids.includes("job-live")) process.exit(1);
if (jobs.find((job) => job.id === "job-live").pidAlive !== true) process.exit(1);
' "$dead_json"; then
  printf -- '--active --json wrong: %s\n' "$(cat "$dead_json")" >&2; failures=$((failures + 1))
fi

# NEGATIVE CONTROL: without the liveness filter the dead record comes back, so the rows above
# cannot be passing for some other reason.
mutant="$tmp_root/codex-jobs-mutant.sh"
sed 's/if (alive === false) { orphaned += 1; continue; }/if (false) { orphaned += 1; continue; }/' "$tool" > "$mutant"
if cmp -s "$mutant" "$tool"; then
  printf 'liveness-filter mutation did not apply\n' >&2; failures=$((failures + 1))
else
  mutant_out="$tmp_root/mutant-active.out"
  CLAUDE_PLUGIN_DATA="$dead_root/codex-inline" TMPDIR="$tmp_root/emptytmp" bash "$mutant" --all-workspaces --active > "$mutant_out" 2>&1 || true
  grep -q '^job-dead ' "$mutant_out" || {
    printf 'mutation did not restore the dead record: %s\n' "$(cat "$mutant_out")" >&2; failures=$((failures + 1)); }
fi

if [ "$failures" -eq 0 ]; then printf '%s\n' 'CODEX JOBS SELFTEST: PASS'; completed=1; exit 0; fi
printf '%s\n' 'CODEX JOBS SELFTEST: FAIL'; completed=1; exit 1
