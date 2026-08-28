# Model-routing hooks

These hooks are the enforcement layer for the Codex-first Model Routing policy in `global/CLAUDE.md`; update them whenever that policy changes.

`$CODEX_PLUGIN` is not exported by default; use `scripts/codex.sh` (installed as `~/.claude/scripts/codex.sh`) as the supported Codex companion entry point.

- `bd-ready-model-routing.sh` fires after a real `bd ready` Bash command and maps ready work to the Codex model and effort in the equivalence table.
- `exitplan-model-routing.sh` fires when a plan is approved and stops the plan-to-build transition for Codex delegation through `/codex:rescue`.
- `first-edit-codex-gate.sh` fires once per session after the first `Edit`, `Write`, or `NotebookEdit`, covering implementation that bypasses plan mode.

`settings-hooks.json` is the tracked source of truth for the required `PostToolUse` registrations. `./install.sh` links this directory and then runs `hooks/install-hooks.sh`, which merges those registrations and the resolver-derived `env.CODEX_PLUGIN` into the user's `~/.claude/settings.json`; the installer does not own that file or its unrelated settings. Set `CC_HARNESS_CLAUDE_DIR=/path/to/.claude` to target an isolated Claude directory for install or removal.

Verify a machine's registrations with `bash hooks/install-hooks.sh --check`. Use `bash hooks/selftest.sh` for the hermetic regression suite; it validates hook output, registration installation/removal, idempotency, preservation of unrelated settings, and negative controls.

## Measuring

Use `bash scripts/routing-report.sh` to measure observed Codex delegations against Claude-side delegable subagents in recent Claude Code transcripts. It defaults to one day; use `--days N`, `--since YYYY-MM-DD`, or `--json` as needed, and run `bash scripts/routing-report-selftest.sh` for its hermetic regression suite.
