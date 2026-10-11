#!/usr/bin/env bash
# Measure bounded-review-loop signals from Claude Code transcripts.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/loop-report.sh [--days N] [--since YYYY-MM-DD] [--json] [--prs n[,n...]]' >&2
}

days=1
since=''
json=false
prs=''
report_root="${LOOP_REPORT_ROOT:-${HOME:-}/.claude/projects}"
reference=''
file_list=''
report_json=''
pr_json=''

cleanup() {
  [ -z "$reference" ] || rm -f "$reference"
  [ -z "$file_list" ] || rm -f "$file_list"
  [ -z "$report_json" ] || rm -f "$report_json"
  [ -z "$pr_json" ] || rm -f "$pr_json"
}
trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --days)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      days="$2"
      shift 2
      ;;
    --since)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      since="$2"
      shift 2
      ;;
    --json)
      json=true
      shift
      ;;
    --prs)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      prs="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

case "$days" in ''|*[!0-9]*|0) usage; exit 64 ;; esac
if [ -n "$since" ]; then
  case "$since" in ????-??-??) ;; *) usage; exit 64 ;; esac
  reference=$(mktemp "${TMPDIR:-/tmp}/loop-report-reference.XXXXXX") || exit 1
  since_stamp=$(printf '%s' "$since" | tr -d '-')0000
  if ! touch -t "$since_stamp" "$reference"; then
    printf 'Invalid --since date: %s\n' "$since" >&2
    exit 64
  fi
  window_label="since $since"
else
  window_label="last $days day(s)"
fi

case "$prs" in
  '') ;;
  *[!0-9,]*|,*|*,) usage; exit 64 ;;
esac

if [ ! -d "$report_root" ]; then
  printf 'Transcript root does not exist or is not a directory: %s\n' "$report_root" >&2
  exit 2
fi

file_list=$(mktemp "${TMPDIR:-/tmp}/loop-report-files.XXXXXX") || exit 1
if [ -n "$since" ]; then
  find "$report_root" -type f -name '*.jsonl' -newer "$reference" -print0 > "$file_list"
else
  find "$report_root" -type f -name '*.jsonl' -mtime "-$days" -print0 > "$file_list"
fi

files_scanned=0
while IFS= read -r -d '' transcript; do
  files_scanned=$((files_scanned + 1))
done < "$file_list"
if [ "$files_scanned" -eq 0 ]; then
  printf 'No transcripts found in %s under: %s\n' "$window_label" "$report_root" >&2
  exit 2
fi

report_json=$(mktemp "${TMPDIR:-/tmp}/loop-report-data.XXXXXX") || exit 1
python3 - "$file_list" "$window_label" > "$report_json" <<'PY'
import datetime as dt
import json
import os
import re
import sys

file_list, window = sys.argv[1:]
with open(file_list, "rb") as source:
    paths = [path.decode("utf-8", "surrogateescape") for path in source.read().split(b"\0") if path]

round_pattern = re.compile(r"\b[Rr]ound (\d+)\b")

def parse_time(value):
    if not isinstance(value, str):
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None

rows = []
for path in paths:
    rounds = gate_runs = merge_gate_invocations = peer_messages = assistant_messages = subagent_calls = malformed = 0
    stamps = {}
    model_msgs = {}
    tool_owner = {}
    results = {}
    with open(path, encoding="utf-8", errors="replace") as transcript:
        for line in transcript:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                malformed += 1
                continue
            when = parse_time(record.get("timestamp"))
            if when is not None and isinstance(record.get("uuid"), str):
                stamps[record["uuid"]] = when
            if record.get("type") == "user" and isinstance(record.get("message", {}).get("content"), list):
                for block in record["message"]["content"]:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        owner = tool_owner.get(block.get("tool_use_id"))
                        if owner:
                            counts = results.setdefault(owner, [0, 0])
                            counts[0] += 1
                            counts[1] += 1 if block.get("is_error") else 0
            if record.get("type") != "assistant":
                continue
            assistant_messages += 1
            message = record.get("message", {})
            model = message.get("model")
            message_id = message.get("id")
            if isinstance(model, str) and model and not model.startswith("<") and isinstance(message_id, str):
                entry = model_msgs.setdefault(message_id, {"model": model, "parent": record.get("parentUuid"), "last": when})
                if when is not None and (entry["last"] is None or when > entry["last"]):
                    entry["last"] = when
                for block in message.get("content", []) if isinstance(message.get("content"), list) else []:
                    if isinstance(block, dict) and block.get("type") == "tool_use" and isinstance(block.get("id"), str):
                        tool_owner[block["id"]] = model
            content = record.get("message", {}).get("content", [])
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    value = block.get("text", "")
                    if isinstance(value, str):
                        for match in round_pattern.finditer(value):
                            rounds = max(rounds, int(match.group(1)))
                    continue
                if block.get("type") != "tool_use":
                    continue
                name = block.get("name", "")
                if name == "Agent":
                    subagent_calls += 1
                if name == "SendMessage" or (isinstance(name, str) and name.endswith("__send_message")):
                    peer_messages += 1
                if name == "Bash":
                    command = block.get("input", {}).get("command", "")
                    if isinstance(command, str) and "merge-gate.sh" in command:
                        merge_gate_invocations += 1
                        if all(flag not in command for flag in ("--record-ack", "--list-acks", "--selftest")):
                            gate_runs += 1
    models = {}
    for message_id, entry in model_msgs.items():
        slot = models.setdefault(entry["model"], {"messages": 0, "tool_results": 0, "tool_errors": 0, "latency_s": []})
        slot["messages"] += 1
        parent = stamps.get(entry["parent"])
        if parent is not None and entry["last"] is not None:
            seconds = (entry["last"] - parent).total_seconds()
            if 0 < seconds < 600:
                slot["latency_s"].append(round(seconds, 1))
    for owner_model, counts in results.items():
        if owner_model in models:
            models[owner_model]["tool_results"] = counts[0]
            models[owner_model]["tool_errors"] = counts[1]
    rows.append({
        "transcript": path,
        "models": models,
        "review_rounds": rounds,
        "gate_runs": gate_runs,
        "merge_gate_invocations": merge_gate_invocations,
        "peer_messages": peer_messages,
        "assistant_messages": assistant_messages,
        "subagent_calls": subagent_calls,
        "malformed": malformed,
    })

print(json.dumps({"window": window, "files_scanned": len(paths), "transcripts": rows}, separators=(",", ":")))
PY

pr_json=$(mktemp "${TMPDIR:-/tmp}/loop-report-prs.XXXXXX") || exit 1
if [ -n "$prs" ]; then
  old_ifs=$IFS
  IFS=,
  set -- $prs
  IFS=$old_ifs
  for pr in "$@"; do
    if ! gh pr view "$pr" --json commits,createdAt,mergedAt >> "$pr_json"; then
      printf 'Unable to read PR #%s\n' "$pr" >&2
      exit 1
    fi
    printf '\n' >> "$pr_json"
  done
fi

if [ "$json" = true ]; then
  python3 - "$report_json" "$pr_json" "$prs" <<'PY'
import datetime as dt
import json
import sys

def by_model(transcripts):
    totals = {}
    for row in transcripts:
        attributed = sum(slot["messages"] for slot in row.get("models", {}).values())
        for name, slot in row.get("models", {}).items():
            total = totals.setdefault(name, {"sessions": 0, "dominant_sessions": 0, "messages": 0, "tool_results": 0, "tool_errors": 0, "latency_s": []})
            total["sessions"] += 1
            total["messages"] += slot["messages"]
            total["tool_results"] += slot["tool_results"]
            total["tool_errors"] += slot["tool_errors"]
            total["latency_s"].extend(slot["latency_s"])
            if attributed >= 10 and slot["messages"] * 10 >= attributed * 9:
                total["dominant_sessions"] += 1
    out = {}
    for name, total in sorted(totals.items(), key=lambda item: -item[1]["messages"]):
        latencies = sorted(total.pop("latency_s"))
        total["median_latency_s"] = latencies[len(latencies) // 2] if latencies else None
        total["tool_error_pct"] = round(100.0 * total["tool_errors"] / total["tool_results"], 1) if total["tool_results"] else None
        out[name] = total
    return out

def hours_open(created, merged):
    if not created or not merged:
        return None
    return round((dt.datetime.fromisoformat(merged.replace("Z", "+00:00")) - dt.datetime.fromisoformat(created.replace("Z", "+00:00"))).total_seconds() / 3600, 1)

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
prs = []
numbers = sys.argv[3].split(",") if sys.argv[3] else []
for number, line in zip(numbers, (line for line in open(sys.argv[2], encoding="utf-8") if line.strip())):
    if line.strip():
        value = json.loads(line)
        commits = value.get("commits", [])
        prs.append({
            "number": int(number),
            "commits": len(commits),
            "fix_commits": sum(1 for commit in commits if commit.get("messageHeadline", "").startswith("fix")),
            "hours_open": hours_open(value.get("createdAt"), value.get("mergedAt")),
        })
payload["prs"] = prs
payload["by_model"] = by_model(payload["transcripts"])
print(json.dumps(payload, separators=(",", ":")))
PY
else
  python3 - "$report_json" "$pr_json" "$prs" <<'PY'
import datetime as dt
import json
import os
import sys

def by_model(transcripts):
    totals = {}
    for row in transcripts:
        attributed = sum(slot["messages"] for slot in row.get("models", {}).values())
        for name, slot in row.get("models", {}).items():
            total = totals.setdefault(name, {"sessions": 0, "dominant_sessions": 0, "messages": 0, "tool_results": 0, "tool_errors": 0, "latency_s": []})
            total["sessions"] += 1
            total["messages"] += slot["messages"]
            total["tool_results"] += slot["tool_results"]
            total["tool_errors"] += slot["tool_errors"]
            total["latency_s"].extend(slot["latency_s"])
            if attributed >= 10 and slot["messages"] * 10 >= attributed * 9:
                total["dominant_sessions"] += 1
    out = {}
    for name, total in sorted(totals.items(), key=lambda item: -item[1]["messages"]):
        latencies = sorted(total.pop("latency_s"))
        total["median_latency_s"] = latencies[len(latencies) // 2] if latencies else None
        total["tool_error_pct"] = round(100.0 * total["tool_errors"] / total["tool_results"], 1) if total["tool_results"] else None
        out[name] = total
    return out

def hours_open(created, merged):
    if not created or not merged:
        return None
    return round((dt.datetime.fromisoformat(merged.replace("Z", "+00:00")) - dt.datetime.fromisoformat(created.replace("Z", "+00:00"))).total_seconds() / 3600, 1)

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
print("Window: {}".format(payload["window"]))
print("Files scanned: {}".format(payload["files_scanned"]))
if not payload["transcripts"]:
    print("NO DATA")
else:
    print("Transcript\tRounds\tGate runs\tMerge-gate invocations\tPeer msgs\tAssistant msgs\tAgent calls\tMalformed")
    for row in payload["transcripts"]:
        print("{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}".format(os.path.basename(row["transcript"]), row["review_rounds"], row["gate_runs"], row["merge_gate_invocations"], row["peer_messages"], row["assistant_messages"], row["subagent_calls"], row["malformed"]))

models = by_model(payload["transcripts"])
if models:
    print("Model\tSessions\tDominant sessions\tMessages\tMedian latency s\tTool error %\tTool results")
    for name, row in models.items():
        print("{}\t{}\t{}\t{}\t{}\t{}\t{}".format(name, row["sessions"], row["dominant_sessions"], row["messages"], "unknown" if row["median_latency_s"] is None else row["median_latency_s"], "unknown" if row["tool_error_pct"] is None else row["tool_error_pct"], row["tool_results"]))

pr_rows = []
numbers = sys.argv[3].split(",") if sys.argv[3] else []
for number, line in zip(numbers, (line for line in open(sys.argv[2], encoding="utf-8") if line.strip())):
    if line.strip():
        value = json.loads(line)
        commits = value.get("commits", [])
        pr_rows.append((number, len(commits), sum(1 for commit in commits if commit.get("messageHeadline", "").startswith("fix")), hours_open(value.get("createdAt"), value.get("mergedAt"))))
if pr_rows:
    print("PR\tCommits\tFix commits\tHours open")
    for row in pr_rows:
        print("#{}\t{}\t{}\t{}".format(row[0], row[1], row[2], "unknown" if row[3] is None else row[3]))
PY
fi

if ! python3 - "$report_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
sys.exit(1 if any(row["malformed"] for row in payload["transcripts"]) else 0)
PY
then
  exit 2
fi
