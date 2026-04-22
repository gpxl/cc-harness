# cc-harness

A structured dev workflow for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Six global agents that handle code quality, testing, commits, releases, PR monitoring, and verification — all config-driven from your project's `CLAUDE.md`.

## What you get

| Agent | Purpose |
|-------|---------|
| **code-quality** | Evaluates test coverage, quality (Q1-Q8 checklist), and lint. Reports PASS/FAIL. |
| **test-writer** | Writes behavioral tests for gaps reported by code-quality. Never writes line-coverage tests. |
| **commit** | Gates on code-quality PASS, creates Conventional Commits, pushes branch, opens PR. Worktree-aware: when invoked from an orchestrator-provisioned `git worktree`, commits on the worktree's HEAD without `git checkout`. |
| **release** | Evaluates whether to release, runs a documentation audit (FAILs if user-facing `feat:`/`fix:` commits aren't reflected in README/`docs/`), bumps version, updates changelog, tags, creates GitHub Release. Refuses to run inside a worktree — must be invoked from the main checkout. |
| **pr-monitor** | Watches CI checks. Auto-merges on green only when (a) the branch matches the `branch_pattern` and (b) the PR carries one of the labels listed in `auto_merge_labels` (Agent Config). PRs without a permitted label get CI watched but emit `AWAITING_HUMAN` for manual merge. If `auto_merge_labels` is unset, label-gating is skipped (backward compatible). |
| **verification** | Adversarial verification before reporting done. Anti-rationalization catalog. Tries to break it. |

Plus rules for test quality, memory discipline, CLAUDE.md project templates, and agent purpose statements.

## Install

```bash
git clone https://github.com/YOUR_USERNAME/cc-harness.git
cd cc-harness
./install.sh
```

This symlinks `agents/` and `rules/` into `~/.claude/`, making them available in every project. Any existing directories are backed up first.

## Configure a project

Add an `## Agent Config` table to your project's `CLAUDE.md`. The agents read this table at runtime for project-specific commands and thresholds.

```bash
# Copy the template
cat templates/agent-config.md
```

Then edit the values for your project. Key fields:

| Field | Example |
|-------|---------|
| `test_cmd` | `pnpm test` or `python3 -m pytest tests/` |
| `lint_cmd` | `pnpm lint` or `ruff check src/` |
| `build_cmd` | `pnpm build` or `(none)` |
| `coverage_per_module` | `80` or `(none)` |
| `version_strategy` | `semver`, `semver-beta`, `git-tags-only`, or `(none)` |
| `deploy_model` | `discrete` or `auto-deploy` |
| `auto_merge_labels` | comma-separated PR labels that permit pr-monitor to auto-merge (e.g. `agent/auto`); unset disables label-gating |
| `worktree_root` | parent directory for orchestrator-provisioned worktrees (e.g. `../<repo>-worktrees`); enables parallel-safe pipelines |
| `isolation_required_for` | comma-separated skill names that must run inside a worktree |

Use `(none)` to skip any capability your project doesn't need.

See [`templates/agent-config.md`](templates/agent-config.md) for the full 25-key schema with descriptions.

## How it works

Claude Code loads agents from `~/.claude/agents/` globally. Project-level agents at `<project>/.claude/agents/` override global ones by name if you need custom behavior.

The harness agents are **config-driven**: instead of hardcoding commands and thresholds, each agent's first step reads the `## Agent Config` table from the current project's `CLAUDE.md`. This means one set of agents works across Python, TypeScript, Go, or any other stack — the project config tells the agent what to run.

```
~/.claude/
├── agents/  →  cc-harness/agents/   (symlink)
│   ├── code-quality.md
│   ├── commit.md
│   ├── release.md
│   ├── test-writer.md
│   ├── pr-monitor.md
│   └── verification.md
└── rules/   →  cc-harness/rules/    (symlink)
    ├── testing-guidelines.md
    ├── claude-md-project-templates.md
    ├── memory-discipline.md
    ├── agent-purpose-statements.md
    └── agent-isolation.md
```

## Agent workflow

The agents form a pipeline:

```
code change
  → code-quality (evaluate)
    → FAIL? → test-writer (fix gaps) → code-quality (re-verify)
    → PASS  → commit (stage, push, open PR)
      → pr-monitor (watch CI, merge on green)
        → release (evaluate, tag, publish)

Non-trivial work:
  → verification (adversarial checks before reporting done)
```

## Per-project overrides

If a project needs fundamentally different agent behavior (not just different config), create a project-level agent with the same name:

```
my-project/.claude/agents/commit.md   ← overrides the global commit agent
```

This is useful for projects with unique workflows (e.g., student-facing agents that avoid git terminology).

## Rules included

| Rule | What it provides |
|------|-----------------|
| **testing-guidelines** | Test quality checklist (Q1-Q8), TDD workflow, anti-patterns, session close protocol |
| **claude-md-project-templates** | NEVER rules template + autonomy tier template for project CLAUDE.md |
| **memory-discipline** | Memory exclusion reinforcements + recall-time verification protocol |
| **agent-purpose-statements** | Purpose statement pattern for manual agent orchestration |
| **agent-isolation** | Worktree-based isolation for parallel-safe pipelines — when/how to use `git worktree` so concurrent Claude sessions don't corrupt each other's branch state |

## Uninstall

```bash
./uninstall.sh
```

Removes the symlinks and restores any backed-up directories.

## Customization

Fork this repo and modify agents/rules to match your workflow. The agents are markdown files — no build step, no dependencies.

Key customization points:
- Agent models: change `model:` in frontmatter (e.g., `claude-haiku-4-5-20251001` for cheaper quality checks)
- Quality thresholds: adjust per-project via Agent Config, not by modifying the global agent
- Additional agents: add new `.md` files to `agents/`
- Additional rules: add new `.md` files to `rules/`

## License

MIT
