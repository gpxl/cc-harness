# CLAUDE.md Project Templates

When setting up or optimizing a project's CLAUDE.md, include these sections with project-specific entries.

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

**Prompt for project owners — fill in entries for:**

| Category | Think about |
|----------|-------------|
| Testing | What should never be mocked? What tests must never be skipped? |
| Architecture | What boundaries exist? What import rules? What patterns are banned? |
| Dependencies | Which libraries are forbidden? What's the approved alternative? |
| Infrastructure | Which directories/configs are dangerous to modify? |
| Data | What DB operations need human approval? What's irreversible? |
| Releases | What gates exist before publish/deploy? |
| Secrets | What project-specific secret files beyond `.env`? |

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

**Prompt for project owners — customize entries for each tier:**

| Tier | Think about |
|------|-------------|
| Autonomous | Which commands are safe? Which directories are freely editable? |
| Confirm first | What has moderate blast radius? What affects shared state? |
| Never | What's irreversible? What affects production? What costs money? |
