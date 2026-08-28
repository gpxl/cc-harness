#!/usr/bin/env bash
# PostToolUse hook (matcher: Edit|Write|NotebookEdit). Remind each session once
# that implementation is Codex-first even when it did not pass through plan mode.
set -euo pipefail
trap 'exit 0' ERR
umask 077

input=$(cat 2>/dev/null || printf '')
session_id=''

if command -v python3 >/dev/null 2>&1; then
  session_id=$(printf '%s' "$input" | python3 -c '
import json
import sys
value = json.load(sys.stdin).get("session_id")
if isinstance(value, str):
    print(value)
' 2>/dev/null) || session_id=''
fi

safe_session=$(printf '%s' "$session_id" | tr -cd '[:alnum:]_-')
if [ -z "$safe_session" ]; then
  safe_session="ppid-${PPID:-parent}"
fi

state_root="${XDG_STATE_HOME:-${HOME:-}/.local/state}"
if [ -z "$state_root" ]; then
  exit 0
fi

marker_dir="${state_root}/cc-harness/first-edit-gate"
mkdir -p "$marker_dir" 2>/dev/null || exit 0
marker="${marker_dir}/${safe_session}"

# noclobber makes marker creation atomic: an existing marker means no output.
if ! (set -C; : > "$marker") 2>/dev/null; then
  exit 0
fi

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"An inline file edit just happened. Under the Codex-first budget rule, implementation defaults to /codex:rescue, not inline editing: is there any reason this cannot be a Codex run? The only genuinely irreducible exceptions are the orchestrator's own turn and tools Codex cannot reach (MCP, browser/computer-use, Artifacts, iOS Simulator, Figma, or anything needing a permission prompt). Claude-side bookkeeping also stays here: beads, git/branch/PR flow, and running the verify gate. `It's only a one-liner` is explicitly not a fallback reason. The codex-rescue SUBAGENT description leads with `when Claude Code is stuck` and warns off `simple asks`; the plugin itself exists for delegation. Under this harness Codex is the DEFAULT route for implementation, and that subagent wording does not narrow it. A Codex task inherits the session cwd as its sandbox root, so a delegation targeting another repo is refused; pass --cwd <repo> (or launch from that repo) rather than falling back to inline work."}}
EOF
