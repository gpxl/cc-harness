#!/usr/bin/env bash
# Hermetic regression test for scripts/loop-report.sh.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
report="$root/scripts/loop-report.sh"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/loop-report-selftest.XXXXXX") || exit 1
completed=0
trap 'st=$?; rm -rf "$tmp_root"; [ "$completed" = 1 ] || st=1; exit $st' EXIT HUP INT TERM

failures=0
pass() { printf '%s: PASS\n' "$1"; }
fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

fixture_root="$tmp_root/projects"
fixture="$fixture_root/fixture.jsonl"
empty_root="$tmp_root/empty"
missing_root="$tmp_root/missing"
mkdir -p "$fixture_root"
mkdir -p "$empty_root"

python3 - "$fixture" <<'PY'
import json
import sys

def record(kind, blocks):
    return {"type": kind, "message": {"content": blocks}}

def text(value):
    return {"type": "text", "text": value}

def tool(name, command=None):
    input_value = {} if command is None else {"command": command}
    return {"type": "tool_use", "name": name, "input": input_value}

records = [
    record("assistant", [text("Round 1: first review")]),
    record("assistant", [text("round 2: re-review"), tool("Bash", "bash scripts/merge-gate.sh")]),
    record("assistant", [text("Round 3: final review"), tool("Bash", "bash scripts/merge-gate.sh"), tool("Bash", "bash scripts/merge-gate.sh --record-ack")]),
    record("assistant", [tool("SendMessage"), tool("mcp__collaboration__send_message"), tool("other__send_message"), tool("SendMessage")]),
    record("assistant", [tool("Agent")]),
]
with open(sys.argv[1], "w", encoding="utf-8") as output:
    for value in records:
        output.write(json.dumps(value) + "\n")
PY

run_report() {
  local output result_code
  if output=$(LOOP_REPORT_ROOT="$fixture_root" bash "$report" --days 1 --json 2>&1); result_code=$?; [ "$result_code" -eq 0 ]; then
    printf '%s\n' "$output"
    return 0
  fi
  printf '%s\n' "$output"
  return "$result_code"
}

assert_counts() {
  local output="$1"
  local expected_gates="$2"
  local expected_malformed="$3"
  local report_output="$tmp_root/report.json"
  printf '%s' "$output" > "$report_output"
  python3 - "$expected_gates" "$expected_malformed" "$report_output" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[3], encoding="utf-8"))
rows = payload["transcripts"]
assert len(rows) == 1, rows
row = rows[0]
expected = {
    "review_rounds": 3,
    "gate_runs": int(sys.argv[1]),
    "merge_gate_invocations": 3,
    "peer_messages": 4,
    "assistant_messages": 5,
    "subagent_calls": 1,
    "malformed": int(sys.argv[2]),
}
for field, value in expected.items():
    assert row[field] == value, (field, row[field], value)
    if field != "malformed":
        assert row[field] > 0, (field, row[field])
PY
}

if output=$(LOOP_REPORT_ROOT="$missing_root" bash "$report" --days 1 --json 2>&1); then
  fail 'missing root negative control' 'missing root exited zero'
elif contains "$output" 'Transcript root does not exist'; then
  pass 'missing root negative control'
else
  fail 'missing root negative control' 'missing root did not report a clear error'
fi

if output=$(LOOP_REPORT_ROOT="$empty_root" bash "$report" --days 1 --json 2>&1); then
  fail 'empty root negative control' 'empty root exited zero'
elif contains "$output" 'No transcripts found'; then
  pass 'empty root negative control'
else
  fail 'empty root negative control' 'empty root did not report a clear error'
fi

if output=$(run_report) && assert_counts "$output" 2 0; then
  pass 'known counters'
else
  fail 'known counters' 'fixture counts did not reconcile'
fi

python3 - "$fixture" <<'PY'
import json
import sys

path = sys.argv[1]
records = [json.loads(line) for line in open(path, encoding="utf-8")]
for record in records:
    for block in record["message"]["content"]:
        if block.get("type") == "tool_use" and block.get("input", {}).get("command", "").endswith("--record-ack"):
            block["input"]["command"] = "bash scripts/merge-gate.sh"
with open(path, "w", encoding="utf-8") as output:
    for record in records:
        output.write(json.dumps(record) + "\n")
PY

if output=$(run_report) && assert_counts "$output" 3 0; then
  pass 'record-ack exclusion negative control'
else
  fail 'record-ack exclusion negative control' 'plain merge-gate call did not increment gate_runs'
fi

python3 - "$fixture" <<'PY'
import sys

with open(sys.argv[1], "a", encoding="utf-8") as output:
    output.write('{"type":"assistant"\n')
PY

if output=$(run_report); then
  fail 'malformed transcript negative control' 'malformed transcript exited zero'
elif assert_counts "$output" 3 1; then
  pass 'malformed transcript negative control'
else
  fail 'malformed transcript negative control' 'malformed count was not reported as 1'
fi

# Per-model breakdown: two models, known latency, one attributed tool error.
model_root="$tmp_root/models"
mkdir -p "$model_root"
python3 - "$model_root/models.jsonl" <<'PY'
import json
import sys

def rec(kind, uuid, parent, when, message):
    return {"type": kind, "uuid": uuid, "parentUuid": parent, "timestamp": when, "message": message}

def asst(uuid, parent, when, model, mid, tool_id=None):
    blocks = [{"type": "text", "text": "ok"}]
    if tool_id:
        blocks.append({"type": "tool_use", "id": tool_id, "name": "Bash", "input": {"command": "true"}})
    return rec("assistant", uuid, parent, when, {"model": model, "id": mid, "content": blocks})

def result(uuid, parent, when, tool_id, is_error):
    return rec("user", uuid, parent, when, {"content": [{"type": "tool_result", "tool_use_id": tool_id, "is_error": is_error, "content": "x"}]})

records = [
    rec("user", "u1", None, "2026-10-01T10:00:00Z", {"content": "go"}),
    asst("a1", "u1", "2026-10-01T10:00:04Z", "model-slow", "m1", "t1"),
    result("u2", "a1", "2026-10-01T10:00:05Z", "t1", True),
    asst("a2", "u2", "2026-10-01T10:00:11Z", "model-fast", "m2", "t2"),
    result("u3", "a2", "2026-10-01T10:00:12Z", "t2", False),
    result("u4", "a2", "2026-10-01T10:00:13Z", "no-such-tool", True),
    asst("a3", "u3", "2026-10-01T10:00:14Z", "model-fast", "m2"),
]
with open(sys.argv[1], "w", encoding="utf-8") as output:
    for value in records:
        output.write(json.dumps(value) + "\n")
PY

if output=$(LOOP_REPORT_ROOT="$model_root" bash "$report" --days 1 --json 2>&1) && python3 - "$output" <<'PY'
import json
import sys

models = json.loads(sys.argv[1])["by_model"]
slow, fast = models["model-slow"], models["model-fast"]
assert slow["messages"] == 1 and fast["messages"] == 1, models  # m2 chunks dedupe by message id
assert slow["median_latency_s"] == 4.0, slow
assert fast["median_latency_s"] == 9.0, fast  # last chunk of m2 (10:00:14) minus its parent u2 (10:00:05)
assert slow["tool_results"] == 1 and slow["tool_errors"] == 1 and slow["tool_error_pct"] == 100.0, slow
assert fast["tool_results"] == 1 and fast["tool_errors"] == 0, fast  # orphan tool_use_id error is not attributed
PY
then
  pass 'per-model breakdown'
else
  fail 'per-model breakdown' "model rows did not reconcile: ${output:-}"
fi

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'LOOP REPORT SELFTEST: PASS'
  completed=1; exit 0
fi
printf '%s\n' 'LOOP REPORT SELFTEST: FAIL'
completed=1; exit 1
