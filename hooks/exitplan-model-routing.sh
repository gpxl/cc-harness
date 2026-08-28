#!/usr/bin/env bash
# PostToolUse hook (matcher: ExitPlanMode). The plan-to-build transition is a
# Codex-first gate, not a request to change the Claude session model.
set -euo pipefail
trap 'exit 0' ERR

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"MODEL ROUTING GATE (~/.claude/CLAUDE.md, mismatch protocol): the plan was just approved, so the work type is build/implementation. STOP before implementing and delegate through /codex:rescue: use gpt-5.6-terra at high effort. Check both axes: (1) is Codex-delegable work about to be done inline anyway? (2) for work that is genuinely irreducible in Claude, does the session/subagent model match the fallback column? On a mismatch, STOP: delegate to Codex, ask the user to run /model <correct-id>, or use an explicit model override. Never proceed inline after merely mentioning the mismatch. Current Claude fallback ids are claude-fable-5, claude-opus-5, and claude-sonnet-5; they apply only when Codex is genuinely unavailable."}}
EOF
