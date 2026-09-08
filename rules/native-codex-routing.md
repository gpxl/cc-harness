---
paths:
  - "**/AGENTS.md"
  - "**/.codex/**"
---
# Native Codex Routing

This rule applies only to native Codex sessions. Select a `harness_*` role automatically for
useful bounded work: `harness_explorer` for read-only investigation, `harness_runner` for an
approved existing command sequence, `harness_worker` for implementation and tests,
`harness_analyst` for difficult design or evidence interpretation, and `harness_reviewer` for
independent review. Keep the main model unchanged. If the client cannot select a named role,
spawn a self-contained subtask with the role's explicit generated model and effort; desktop
collaboration forks need `fork_turns="none"` to accept those settings.

Delegate only when the supervisor has useful independent work. Roles do not delegate again.
Project `AGENTS.md` files add project constraints and task-specific authority; they do not copy
the shared model table or generic role prompts. Claude Code's `/codex:rescue`, model mismatch,
and Claude fallback rules apply only inside Claude Code sessions and are not invoked from native
Codex.

The tracked catalog is generated from `hooks/model-routing-table.sh`: run
`scripts/sync-codex-agents.sh --check` to detect a stale catalog. Run
`scripts/codex-routing-check.sh --project <repo>` after installation to find missing installed
links, project role shadows, copied legacy role files, and project-level routing defaults. It is
read-only and never removes project configuration. It uses Python 3.11+'s standard-library
`tomllib` to inspect TOML semantics and fails closed when parsing fails. A nonempty
`AGENTS.override.md` has higher discovery precedence than `AGENTS.md`; empty or remove it before
claiming shared routing is active. See the [official subagent configuration
guide](https://learn.chatgpt.com/docs/agent-configuration/subagents) for client behavior.
