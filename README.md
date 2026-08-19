# cc-harness

A structured dev workflow for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Six global agents that handle code quality, testing, commits, releases, PR monitoring, and verification — all config-driven from your project's `CLAUDE.md`.

## What you get

| Agent | Purpose |
|-------|---------|
| **code-quality** | A **pre-check**, not the full verify: evaluates test coverage, quality (Q1-Q8 checklist), and lint — tests scoped to changed packages where the framework allows, and never the build. Reports `CODE QUALITY RESULT: PASS\|FAIL sha=<sha> tree=<tree> covered=<gates>` and files Q3-Q8 warnings as tracker tasks in the same run (deduped, changed modules only). |
| **test-writer** | Writes behavioral tests for gaps reported by code-quality. Never writes line-coverage tests. |
| **commit** | Gates on code-quality PASS, consumes the recorded full verify (and runs that full lint+test+build itself, once, when no record covers this tree), creates Conventional Commits, pushes branch, opens PR. Browser validation and the coverage gate run only when nothing already covered them for this HEAD. Worktree-aware: when invoked from an orchestrator-provisioned `git worktree`, commits on the worktree's HEAD without `git checkout`. |
| **release** | Early-exits in three lines on tags-only projects with no `feat:`/`fix:` since the last tag. Otherwise: documentation audit (FAILs if user-facing `feat:` commits aren't reflected in README/`docs/`), version bump, changelog, tag, GitHub Release. Does not re-run gates for an already-merged tree. Refuses to run inside a worktree — must be invoked from the main checkout. |
| **pr-monitor** | **Skipped entirely when Agent Config `ci` is `none`** — it exists to poll CI checks. Where CI exists: watches checks and auto-merges on green only when (a) the branch matches `branch_pattern` and (b) the PR carries one of `auto_merge_labels`. PRs without a permitted label get CI watched but emit `AWAITING_HUMAN`. Unset `auto_merge_labels` skips label-gating. |
| **verification** | Adversarial verification before reporting done. Consumes the recorded gate rather than re-running the suite, then spends its run trying to break the change. Anti-rationalization catalog. |

Plus rules for test quality, memory discipline, CLAUDE.md project templates, and agent purpose statements.

## Install

```bash
git clone https://github.com/YOUR_USERNAME/cc-harness.git
cd cc-harness
./install.sh
```

This symlinks `agents/` and `rules/` into `~/.claude/`, and `global/CLAUDE.md` to `~/.claude/CLAUDE.md`, making them available in every project.

Existing state is never destroyed: a real directory or file at the target is backed up first (`<name>.backup.<timestamp>`), and `./uninstall.sh` restores the most recent backup. A target that is already a *symlink* is repointed rather than backed up — the file it pointed at is left untouched, so nothing is lost, but note that `uninstall.sh` restores a backup rather than the previous symlink.

Keeping the global `CLAUDE.md` here means edits to it are versioned and reviewable like everything else. It is the file Claude Code loads into *every* session, so an unversioned edit to it is an unversioned change to how every project behaves.

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
| `verify_cmd` | optional single command running lint+test+build (e.g. `pnpm verify`); preferred over the three above when present |
| `ci` | `github-actions`, `none`, … — `none` makes the pipeline skip pr-monitor |
| `coverage_per_module` | `80` or `(none)` |
| `version_strategy` | `semver`, `semver-beta`, `git-tags-only`, or `(none)` |
| `deploy_model` | `discrete` or `auto-deploy` |
| `auto_merge_labels` | comma-separated PR labels that permit pr-monitor to auto-merge (e.g. `agent/auto`); unset disables label-gating |
| `worktree_root` | parent directory for orchestrator-provisioned worktrees (e.g. `../<repo>-worktrees`); enables parallel-safe pipelines |
| `isolation_required_for` | comma-separated skill names that must run inside a worktree |

Use `(none)` to skip any capability your project doesn't need.

See [`templates/agent-config.md`](templates/agent-config.md) for the full schema with descriptions.

## How it works

Claude Code loads agents from `~/.claude/agents/` globally. Project-level agents at `<project>/.claude/agents/` override global ones by name if you need custom behavior.

The harness agents are **config-driven**: instead of hardcoding commands and thresholds, each agent's first step reads the `## Agent Config` table from the current project's `CLAUDE.md`. This means one set of agents works across Python, TypeScript, Go, or any other stack — the project config tells the agent what to run.

```
~/.claude/
├── CLAUDE.md →  cc-harness/global/CLAUDE.md  (symlink)
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
  → code-quality (PRE-CHECK: scoped tests + lint + coverage — never the build)
    → FAIL? → test-writer (fix gaps) → code-quality (re-verify)
    → PASS  → emits CODE QUALITY RESULT: PASS sha=<sha> tree=<tree> covered=test-scoped,lint,coverage
      → the FULL verify (lint + test + build) runs ONCE for this tree — by the
        orchestrator, or by the commit agent when no record exists — and is
        recorded as VERIFY RESULT: PASS sha=<sha> tree=<tree>
      → commit  — consumes that record (or produces it)
                  → stage, push, open PR
        → pr-monitor  [only if the project has CI — Agent Config `ci` ≠ none]
          → release   [only if `version_strategy` ≠ none]

Non-trivial work:
  → verification (consumes the recorded gate; spends its run on adversarial checks)
```

**Gate once** = **one full verify per tree.** code-quality's scoped test + lint is a
pre-check, not that gate: it never runs the build, and its tests cover only the changed
modules. The full lint+test+build triple runs a single time per working tree — by the
orchestrator or the commit agent, whoever gets there first — and every later step reads
the recorded `VERIFY RESULT:` line rather than re-running it. The contract lives in
[`rules/pipeline-contract.md`](rules/pipeline-contract.md) — orchestrators pass that
file by reference to subagents instead of restating gate instructions.

## Per-project overrides

If a project needs fundamentally different agent behavior (not just different config), create a project-level agent with the same name:

```
my-project/.claude/agents/commit.md   ← overrides the global commit agent
```

This is useful for projects with unique workflows (e.g., student-facing agents that avoid git terminology).

## Rules included

Rules with a `paths:` frontmatter block load only when a matching file is read; the rest load
in every session. Maintainer-only history (incidents, measurements, setup boilerplate) lives in
[`docs/reference/`](docs/reference/), which is **not** symlinked into `~/.claude/`.

| Rule | What it provides |
|------|-----------------|
| **pipeline-contract** | The gate-once contract: who runs the verify, the result-line formats, consume-don't-re-run, and the small-diff fast path |
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
