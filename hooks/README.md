# Model-routing hooks

These hooks enforce the Model Routing policy in `global/CLAUDE.md` (always-loaded core) and
`rules/model-routing-codex.md` (Codex-first mechanics, read when `openai` is the primary route).
`model-routing-table.sh` is the source of truth; `hooks/selftest.sh` checks the markdown table
against it.

`$CODEX_PLUGIN` is not exported by default. Use `scripts/codex.sh`, installed as
`~/.claude/scripts/codex.sh`, as the supported Codex companion entry point.

## Vendor switch

`vendors.conf` is the repo-wide default (openai enabled); a machine-local
`~/.claude/private/vendors.conf` overrides it per vendor, and is where a user pauses one (`openai=disabled`). `vendors.sh` resolves the two (source it
for `vendor_enabled`, or run `bash hooks/vendors.sh` to print the state). Anything but an explicit
`enabled` is disabled, and `anthropic` cannot be disabled. The first enabled vendor in
`MODEL_ROUTING_VENDORS` (`model-routing-table.sh`) is the primary route; every hook below reads
it, and `scripts/codex.sh` refuses new Codex work while `openai` is off. Adding a vendor is one
model column in `model-routing-table.sh`, one entry in its vendor arrays, and one line in
`vendors.conf`. When `openai` is the primary route, the three PostToolUse reminders below tell the model to
Read `~/.claude/rules/model-routing-codex.md`; while it is disabled they never mention that file.

- `bd-ready-model-routing.sh` runs after a real `bd ready` Bash command and maps ready work to the primary vendor's model and effort in the equivalence table.
- `exitplan-model-routing.sh` runs when a plan is approved. With `openai` enabled it stops the plan-to-build transition so work can be delegated through `/codex:rescue`; with it disabled it names the Claude model and forbids the Codex route. It reads `tool_input.plan` and classifies it (`model_routing_classify_plan`): only a positively mechanical plan (mechanical signals, no build signal) takes the mechanical tier (Sonnet, low) with no STOP and an escalation trigger; every other plan, including no-signal and mixed ones, keeps the build tier and its STOP, and architecture plans keep theirs.
- `first-edit-codex-gate.sh` runs once per session after the first `Edit`, `Write`, or `NotebookEdit`, covering implementation that bypasses plan mode. It is silent while `openai` is not the primary vendor.
- `vendor-state.sh` runs at `SessionStart` (`startup|resume|clear|compact`: after `/clear` or compaction the earlier context is gone, so the line is re-injected). It is silent unless a routing vendor is disabled; then it adds one line (~40 tokens) naming the disabled vendors and the primary route, and says to route there silently, with no readiness check, so the model never has to run `vendors.sh` itself. It is also silent when the evidence is missing (no readable config names a routing vendor, or the table or resolver is unreadable): it never reports "disabled by config" without a config line behind it.

`settings-hooks.json` defines the required hook registrations. `./install.sh` links this
directory, then runs `hooks/install-hooks.sh` to merge the registrations and resolver-derived
`env.CODEX_PLUGIN` into `~/.claude/settings.json`. The installer does not own that file or touch
unrelated settings. Set `CC_HARNESS_CLAUDE_DIR=/path/to/.claude` to use an isolated Claude
directory for installation or removal, and `--manifest <path>` to install from another manifest.

The manifest takes two shapes. A bare JSON array (the legacy form) is a list of `PostToolUse`
entries. An object (the current file) maps event names to entry arrays, for example
`{"PostToolUse": [...], "SessionStart": [...]}`. Each manifest entry has an identity within its
event, and install replaces the one settings entry with that identity (dropping duplicates),
`--check` reports it `missing` or `wrong`, and `--remove` deletes only entries identical to the
manifest's:

- Tool events (`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`): the
  matcher, which names the tool. The manifest owns that matcher slot.
- Every other event, such as `SessionStart`: the event plus the entry's commands. The matcher is
  optional (`"startup|resume"`, `""`, or absent) and is not part of the identity, because those
  matchers are shared with the user's own entries, which must never be replaced.

Ownership follows identity. For a non-tool event, the manifest owns every settings entry that runs
the same commands: install overwrites a user entry with that command even when its matcher or
timeout differs, and collapses duplicates into the single manifest entry. A user entry running
any other command is never touched, even when it shares the matcher. `--remove` is narrower: it
deletes only entries identical to the manifest's, so a user-modified copy survives. When that
empties a non-tool event's list, the event key is dropped. Tool events keep the earlier
behaviour, and an emptied `PostToolUse` stays as `[]`.

`--check` prints `<matcher>: missing|wrong` for `PostToolUse` (unchanged from the array-only
installer), `<event> <matcher>` for other tool events, and `<event> <command>` otherwise.

Check a machine's registrations with `bash hooks/install-hooks.sh --check`. Run
`bash hooks/selftest.sh` for the hermetic regression suite, which covers hook output,
registration installation and removal, idempotency, preservation of unrelated settings,
multi-event (`SessionStart`) manifests from a fixture, the shipped manifest's install/check/remove
round trip in an isolated directory, the `vendor-state.sh` output states, and negative controls.

## Measuring

`bash scripts/routing-report.sh` compares observed Codex delegations with delegable Claude-side
subagents in recent Claude Code transcripts. It defaults to one day; use `--days N`,
`--since YYYY-MM-DD`, or `--json` as needed. Its hermetic regression suite is
`bash scripts/routing-report-selftest.sh`.
