# cc-harness

Config-driven dev workflow agents for Claude Code. This repo contains markdown agent prompts, rules, and templates — no source code, no build, no tests.

## Contributing

- Edit agent prompts in `agents/`, rules in `rules/`, templates in `templates/`
- `global/CLAUDE.md` is the user's global `~/.claude/CLAUDE.md`, symlinked by `install.sh` — distinct from *this* file, which is the instructions for working on this repo. When you add a rule to `rules/`, add its one-line entry to the `[Rules]` index in `global/CLAUDE.md` in the same PR: a rule that isn't indexed is a file nothing loads.
- Changes here propagate to all projects via symlinks after `./install.sh`
- Use Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`)
- Use the committed Beads workspace for cc-harness work: run `bd prime` at session start, `bd ready` for next work, `bd create` before non-trivial changes, and `bd close` when done.
- `.beads/.gitignore` excludes the Dolt store (`embeddeddolt/`, `dolt/`, and lock/socket/daemon files); track only `issues.jsonl`, `config.yaml`, `metadata.json`, and `README.md`.
- Run `git config beads.role maintainer` once per clone; `bd` warns when it is unset.

## Agent Config

| Key | Value |
|-----|-------|
| language | Markdown + Bash |
| framework | (none) |
| package_dir | (none) |
| test_dir | (none) |
| test_cmd | (none) |
| coverage_cmd | (none) |
| coverage_overall | (none) |
| coverage_per_module | (none) |
| coverage_tiers | (none) |
| lint_cmd | (none) |
| lint_fix_cmd | (none) |
| build_cmd | (none) |
| test_pattern | (none) |
| test_framework | (none) |
| test_fixtures | (none) |
| exclusions | (none) |
| exclusion_reason | (none) |
| version_files | (none) |
| version_strategy | git-tags-only |
| branch_pattern | <type>/<description> |
| deploy_model | discrete |
| pr_merge_strategy | squash |
| auto_merge_labels | `agent/auto` (default), `agent/review` — both merged by an agent via `gh pr merge <PR> --squash --delete-branch`. **Never `--auto`** (no required status check to wait on) |
| human_merge_labels | `human/hold` — never auto-merges. Repo settings, branch protection, `.github/`, or anything needing a person. An **unlabelled PR is treated as this** |
| pr_review_gate | (none) |
| ci | none — no server-side CI; the gate is the repo's selftests run locally |
| release_merge_strategy | squash |
| browser_validation | (none) |
| quality_gate_pattern | (none) |
| co_author | Claude <noreply@anthropic.com> |

## Merge policy

Every agent-authored PR carries **EXACTLY ONE** merge label, chosen by the commit agent at PR-creation time.

- `agent/auto` is the default for harness work: rules, hooks, scripts, docs, agents, and templates. `agent/auto` and `agent/review` are both merged by an agent via `gh pr merge <PR> --squash --delete-branch`; **never use `--auto`**.
- `human/hold` is required for changes to `.github/`, branch protection or repo settings, anything touching credentials, and `install.sh` or `uninstall.sh` changes that alter what is linked into `~/.claude`, because they mutate the user's live environment on next install.
- Use `agent/review` for anything in between that warrants a glance but no human gate.
- Treat an unlabelled PR as `human/hold`.

If a label is missing from the repo, recreate it:

```bash
gh label create agent/auto --color 0E8A16 --description "Merge on local green"
```

### The gate

This repo has no server-side CI and no build/test commands. “Local green” means every selftest below passes at a real exit code, captured by redirect and never through a pipe; see `rules/verification-integrity.md`.

- `hooks/selftest.sh`
- `scripts/codex-path-selftest.sh`
- `scripts/routing-report-selftest.sh`
- `scripts/install-symmetry-selftest.sh`
- `scripts/codex-wait-selftest.sh`
- `scripts/codex-brokers-selftest.sh`

Merge only when all six report PASS at the PR's HEAD.
