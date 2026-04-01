# Agent Config Template

Add this section to your project's `CLAUDE.md`. The global agents read these
values at runtime to adapt to your project's tooling.

Replace placeholder values with your project-specific commands and thresholds.
Use `(none)` to skip a capability (e.g., `build_cmd | (none)` if no build step).

---

## Agent Config

| Key | Value |
|-----|-------|
| language | TypeScript (strict) |
| framework | Next.js 16 + App Router |
| package_dir | src/ |
| test_dir | tests/ |
| test_cmd | pnpm test |
| coverage_cmd | pnpm test -- --coverage |
| coverage_overall | (none) |
| coverage_per_module | 80 |
| coverage_tiers | (none) |
| lint_cmd | pnpm lint |
| lint_fix_cmd | (none) |
| build_cmd | pnpm build |
| test_pattern | src/foo.ts -> tests/foo.test.ts |
| test_framework | vitest |
| test_fixtures | (none) |
| exclusions | (none) |
| exclusion_reason | (none) |
| version_files | package.json (version) |
| version_strategy | semver |
| branch_pattern | <type>/<description> |
| deploy_model | discrete |
| pr_merge_strategy | merge |
| release_merge_strategy | squash |
| browser_validation | (none) |
| quality_gate_pattern | src/**/*.ts |
| co_author | Claude <noreply@anthropic.com> |

---

## Key Reference

| Key | What it controls | Example values |
|-----|-----------------|----------------|
| `language` | Assertion syntax, test patterns | `Python 3.9+`, `TypeScript (strict)` |
| `framework` | Framework-specific checks | `Next.js 16`, `CLI (tsup)`, `(none)` |
| `package_dir` | Where source code lives | `src/`, `app/`, `lib/` |
| `test_dir` | Where tests live | `tests/`, `co-located *.test.ts` |
| `test_cmd` | Run full test suite | `pnpm test`, `python3 -m pytest tests/` |
| `coverage_cmd` | Run tests with coverage output | `pnpm test -- --coverage`, `(none)` |
| `coverage_overall` | Minimum total coverage % | `50`, `70`, `(none)` |
| `coverage_per_module` | Minimum per-module coverage % | `80`, `(none)` |
| `coverage_tiers` | Different thresholds by module category | `core:80,command:60`, `(none)` |
| `lint_cmd` | Run linter | `pnpm lint`, `ruff check src/` |
| `lint_fix_cmd` | Auto-fix lint issues | `ruff check --fix src/`, `(none)` |
| `build_cmd` | Build/compile step | `pnpm build`, `(none)` |
| `test_pattern` | Map source files to test files | `src/foo.ts -> tests/foo.test.ts` |
| `test_framework` | Which test framework | `pytest`, `jest + react-testing-library`, `vitest` |
| `test_fixtures` | Available shared fixtures/helpers | `conftest.py: fixture1, fixture2`, `(none)` |
| `exclusions` | Files/dirs excluded from quality checks | `src/components/ui/`, `(none)` |
| `exclusion_reason` | Why those files are excluded | `Shadcn UI (auto-generated)`, `(none)` |
| `version_files` | Files containing version strings to sync | `package.json (version), src/version.ts (VERSION)`, `(none)` |
| `version_strategy` | How versions are managed | `semver`, `semver-beta`, `git-tags-only`, `(none)` |
| `branch_pattern` | Branch naming convention | `<type>/<description>`, `claude/<description>` |
| `deploy_model` | How releases reach production | `discrete` (explicit), `auto-deploy` (Vercel/etc.) |
| `pr_merge_strategy` | How feature PRs are merged | `merge` (preserve history), `squash` |
| `release_merge_strategy` | How release PRs are merged | `squash`, `(none)` |
| `browser_validation` | Browser-based validation commands | `pnpm test:visual:home`, `(none)` |
| `quality_gate_pattern` | Files that require code-quality PASS before commit | `src/**/*.ts`, `app/**/*.py` |
| `co_author` | Co-author line for commits | `Claude <noreply@anthropic.com>` |
