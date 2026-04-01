# cc-harness

Config-driven dev workflow agents for Claude Code. This repo contains markdown agent prompts, rules, and templates — no source code, no build, no tests.

## Contributing

- Edit agent prompts in `agents/`, rules in `rules/`, templates in `templates/`
- Changes here propagate to all projects via symlinks after `./install.sh`
- Use Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`)

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
| version_strategy | (none) |
| branch_pattern | <type>/<description> |
| deploy_model | (none) |
| pr_merge_strategy | squash |
| release_merge_strategy | (none) |
| browser_validation | (none) |
| quality_gate_pattern | (none) |
| co_author | Claude <noreply@anthropic.com> |
