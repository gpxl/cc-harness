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

fixture_root="$tmp_root/projects"
fixture="$fixture_root/fixture.jsonl"
mkdir -p "$fixture_root"

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
  local output
  if output=$(LOOP_REPORT_ROOT="$fixture_root" bash "$report" --days 1 --json 2>&1); then
    printf '%s\n' "$output"
    return 0
  fi
  return 1
}

assert_counts() {
  local output="$1"
  local expected_gates="$2"
  local report_output="$tmp_root/report.json"
  printf '%s' "$output" > "$report_output"
  python3 - "$expected_gates" "$report_output" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[2], encoding="utf-8"))
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
}
for field, value in expected.items():
    assert row[field] == value, (field, row[field], value)
    assert row[field] > 0, (field, row[field])
PY
}

if output=$(run_report) && assert_counts "$output" 2; then
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

if output=$(run_report) && assert_counts "$output" 3; then
  pass 'record-ack exclusion negative control'
else
  fail 'record-ack exclusion negative control' 'plain merge-gate call did not increment gate_runs'
fi

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'LOOP REPORT SELFTEST: PASS'
  completed=1; exit 0
fi
printf '%s\n' 'LOOP REPORT SELFTEST: FAIL'
completed=1; exit 1
