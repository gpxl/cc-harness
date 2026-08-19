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

Elicitation prompts for filling in both templates: `docs/reference/rule-histories.md`.
