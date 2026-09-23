---
paths:
  - "**/AGENTS.md"
  - "**/.codex/**"
---
# Native Codex Routing

This rule applies only to native Codex sessions. Select a `harness_*` role automatically for
useful bounded work: `harness_explorer` for read-only investigation, `harness_runner` for an
approved existing command sequence, `harness_spark` for precise, small coding iterations with a
known outcome and an easy correctness check, `harness_worker` for broader implementation and tests,
`harness_analyst` for difficult design or evidence interpretation, and `harness_reviewer` for
independent review. Keep the main model unchanged. If the client cannot select a named role,
spawn a self-contained subtask with the role's explicit generated model and effort; desktop
collaboration forks need `fork_turns="none"` to accept those settings.

Delegate only when the supervisor has useful independent work. Roles do not delegate again.
Project `AGENTS.md` files add project constraints and task-specific authority; they do not copy
the shared model table or generic role prompts. Claude Code's `/codex:rescue`, model mismatch,
and Claude fallback rules apply only inside Claude Code sessions and are not invoked from native
Codex.

## Focused coding selection

Prefer `harness_spark` when the desired outcome is already known, the scope is small, and
correctness is easy to check. The role name is retained for compatibility; it now selects
`gpt-6-luna` at low effort. The following are routing recommendations for this harness:

| Good task | Example |
|---|---|
| Small UI adjustment | Reduce a hero's height, adjust spacing, or change a button label |
| Mechanical refactor | Rename a prop and update its callers |
| Straightforward fix | Handle a specified empty value or correct a known conditional |
| Focused test | Add regression coverage for clearly specified behavior |
| Small utility | Write a transform with explicit inputs, outputs, and edge cases |

Give one bounded change, the existing component or paths to reuse, invariants to preserve, and
the check that establishes success. For example:

> Update the homepage CTA to “Watch set + tracklist.” Reuse the existing component and preserve
> its destination and analytics. Follow the repository workflow and verify the change.

Text-only means the task must be understandable without interpreting screenshots; visual
inspection belongs to a capable supervisor or tool. Small UI edits still need the repository's
applicable visual checks. The focused coding role does not bypass tests, review, or the commit
pipeline.

Use `harness_worker` for diagnosing search failures or broader implementation; use
`harness_analyst` for designing playback persistence or deciding what engagement metrics mean.
If ambiguity, an unknown cause, or cross-cutting design emerges, `harness_spark` returns its
findings to the supervisor for reassignment instead of expanding scope or delegating again.

Keep model and effort in the generated catalog, not in project copies. `gpt-6-sol` and
`gpt-6-luna` require codex-cli >= 0.155.0 for ChatGPT accounts. Check the live client's
model/role availability before dispatch: a generated role is not proof of account access.
When a named role is unavailable, use its explicit generated settings only if the client exposes
that model; if `gpt-6-luna` is unavailable, use `harness_worker` for the bounded task and report
the substitution. Keep the main model unchanged.

The tracked catalog is generated from `hooks/model-routing-table.sh`: run
`scripts/sync-codex-agents.sh --check` to detect a stale catalog. Run
`scripts/codex-routing-check.sh --project <repo>` after installation to find missing installed
links, project role shadows, copied legacy role files, and project-level routing defaults. It is
read-only and never removes project configuration. It uses Python 3.11+'s standard-library
`tomllib` to inspect TOML semantics and fails closed when parsing fails. A nonempty
`AGENTS.override.md` has higher discovery precedence than `AGENTS.md`; empty or remove it before
claiming shared routing is active. See the [official subagent configuration
guide](https://learn.chatgpt.com/docs/agent-configuration/subagents) for client behavior.
