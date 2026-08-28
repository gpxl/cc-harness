#!/usr/bin/env bash
# PostToolUse hook (matcher: Bash). Fires ONLY when the executed command actually
# invokes `bd ready`, injecting a reminder to tag each ready issue with a
# suggested model per the Model Routing policy in ~/.claude/CLAUDE.md.
#
# Self-gating: reads the tool input on stdin and exits silently unless the command
# is a `bd ready` invocation. This does NOT rely on the settings.json `if:` filter
# (which does not gate this hook in the installed Claude Code version) — the script
# is the source of truth for when the reminder appears.
set -euo pipefail

input=$(cat 2>/dev/null || printf '')

# Extract tool_input.command (first quoted value; a `bd ready` command has no
# inner quotes, so [^"]* captures it cleanly).
cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

# Match `bd ready` as a command token: at the start, or after a shell separator
# (; & |) or whitespace, and followed by whitespace or end. So `bd readyfoo`,
# `abd ready`, or an unrelated mention of the phrase does not trigger it.
if ! printf '%s' "$cmd" | grep -Eq '(^|[;&|]|[[:space:]])bd[[:space:]]+ready([[:space:]]|$)'; then
  exit 0
fi

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Model Routing (~/.claude/CLAUDE.md): /codex:rescue is the default delegation route. For each issue listed by `bd ready`, suggest a Codex model by its type/title: architecture/design (ADRs, system design, novel abstractions, hard trade-offs) -> gpt-5.6-sol at xhigh; build/implementation (coding, refactors, tests, eval scenarios, debugging) -> gpt-5.6-terra at high; probe/exploration (codebase surveys, read-only investigation, light passes) -> gpt-5.6-luna at medium; mechanical (trivial rewrites, formatting-scale edits) -> gpt-5.3-codex-spark at low. The Claude column is fallback only when Codex is genuinely unavailable: architecture/design claude-fable-5 then claude-opus-5, build claude-opus-5, probe/mechanical claude-sonnet-5. This governs the dev-driving model, not any repo's EVAL_MODEL."}}
EOF
