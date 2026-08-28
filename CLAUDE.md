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
| release_merge_strategy | squash |
| browser_validation | (none) |
| quality_gate_pattern | (none) |
| co_author | Claude <noreply@anthropic.com> |
