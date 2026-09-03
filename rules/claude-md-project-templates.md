---
paths:
  - "**/CLAUDE.md"
  - "**/CLAUDE.local.md"
  - "**/.claude/rules/**"
---
# CLAUDE.md Project Templates

When setting up or optimizing a project's CLAUDE.md, include these sections with project-specific entries.

## Agent Config — Isolation Keys

For any project where multiple Claude sessions / scheduled routines may run against the repo concurrently, add these two keys to the `## Agent Config` table. They let orchestrator skills (multi-PR routines, `/loop` git-writing tasks) wrap their pipeline in a `git worktree` so parallel runs don't corrupt each other. See `agent-isolation.md` for the full lifecycle.

```markdown
## Agent Config

| Key | Value |
|-----|-------|
| worktree_root | ../<repo-name>-worktrees |
| isolation_required_for | <comma-separated skill names>, or (none) |
```

| Key | Default | Meaning |
|-----|---------|---------|
| `worktree_root` | `../<repo>-worktrees` | Parent directory for all isolated worktrees. Keep outside the repo. |
| `isolation_required_for` | `(none)` | Comma-separated skill names that MUST run in a worktree. Skills enforce this in their preamble. |

Projects without these keys keep the old behavior — the commit and release agents detect "main checkout" via `git rev-parse --git-common-dir` and no-op their worktree branches.

## Agent Config — `verify_cmd`

| Key | Default | Meaning |
|-----|---------|---------|
| `verify_cmd` | (absent → `test_cmd && lint_cmd && build_cmd`) | One command that is the project's whole gate, run **once per tree** and recorded as `VERIFY RESULT:` (`pipeline-contract.md`). Match what CI actually runs, not the root turbo task — a root `lint` that aborts on an unrelated workspace is a red that says nothing. |

Set it whenever `quality_gate_pattern` is `(none)`: that is the configuration where the
code-quality agent is skipped and `verify_cmd` is the only gate (`agent-enforcement.md`).

## Referencing global rules from a project file

A project `CLAUDE.md` / `CLAUDE.local.md` **references** a global rule by filename and carries
only the project's parameters. It never restates the procedure. A restated procedure freezes the
version that was copied: one project kept both branch-completion stages "mandatory" for a month
after the global rule demoted one and re-triggered the other (rule-histories §branch-completion-review,
2026-09-03), and nothing flagged it because the local text was self-consistent.

What belongs in the project file, per rule:

| Global rule | Project-side parameters only |
|---|---|
| `branch-completion-review.md` | Which surfaces are class 1 / 4 *in this codebase*; the typical stated-skip line; adversary route if it deviates from Model Routing |
| `pipeline-contract.md` / `agent-enforcement.md` | `verify_cmd`, `quality_gate_pattern`, `exclusions` |
| `codex-dispatch-protocol.md` | Sandbox `writable_roots` this repo needs; commands Codex cannot run here (builds, token-gated package managers) |

If a sentence in the project file would still be true with the project name removed, it belongs
in the global rule, not here.

## Project-Specific NEVER Rules

Add this section to a project's CLAUDE.md. The value is in entries only the project owner knows — do NOT duplicate built-in system prompt rules (e.g., "never force-push" is already built-in).

```markdown
## NEVER Rules

| Category | Rule |
|----------|------|
| **Testing** | Never mock the database in integration tests — use the test DB |
| **Testing** | Never skip E2E tests for PR merges |
| **Architecture** | Never import from `internal/` outside its package boundary |
| **Architecture** | Never add direct DB queries outside the repository layer |
| **Dependencies** | Never use [X library] — we use [Y] instead because [reason] |
| **Infrastructure** | Never modify files under `deploy/` or `.github/` without asking |
| **Data** | Never run migrations against prod without explicit instruction |
| **Data** | Never truncate or DROP tables — always use reversible migrations |
| **Releases** | Never auto-merge PRs — all merges require human approval |
| **Releases** | Never publish to npm/PyPI without version bump in [file] |
| **Secrets** | Never commit `.env.local`, `credentials.json`, or `*.pem` files |
```

## Autonomy Tiers (Blast Radius)

Add this section to define what Claude can do freely vs. what needs confirmation. The built-in system prompt handles generic cases — these entries are project-specific.

```markdown
## Autonomy Tiers

### Autonomous (do freely)
- Run `pnpm test`, `pnpm lint`, `pnpm build`
- Read any file in the repo
- Edit files under `src/`, `tests/`, `scripts/`
- Create/modify test files
- Run `git status`, `git diff`, `git log`

### Confirm First
- Install or remove dependencies (`pnpm add`, `pnpm remove`)
- Modify config files (`tsconfig.json`, `eslint.config.*`, `package.json`)
- Create or comment on PRs/issues
- Modify anything under `deploy/`, `.github/`, or `infrastructure/`
- Run database seeds or test data scripts

### Never Without Explicit Request
- Run database migrations
- Deploy to any environment
- Publish packages
- Delete branches or tags
- Modify CI/CD pipelines
- Run `rm -rf` on any directory
- Push to `main`/`master` directly
```

Elicitation prompts for filling in both templates: `~/projects/cc-harness/docs/reference/rule-histories.md`.
