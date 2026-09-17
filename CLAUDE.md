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
- Engineering retrospectives are a standing series in `docs/retrospectives/`. Its `README.md` is authoritative for cadence, section structure and the honesty rules; `TEMPLATE.md` is the skeleton, and every entry opens with follow-through on the previous one. Assemble the measured half with `bash scripts/retro-evidence.sh` before writing.

[Scripts]|root: scripts/
|review-round.sh: Dispatches bounded read-only branch-review rounds; budget is per reviewed SCOPE, and it refuses to dispatch without acceptance criteria or over a hole in the prior-findings record. `--self-check` runs the author's own pre-round-0 pass (spends no budget) and every round's report carries a COVERAGE map the next round targets; run `bash scripts/review-round.sh <base> [--bead <id>] [--evidence-file <path>] [--self-check] [--scope-changed "<words>"] [--acceptance-reworded "<words>"] [--user-approved "<words>"] [--dry-run]`|
|fix-prompt-check.sh: Refuses review-budget and countdown phrasing in a written fix-round prompt, naming the line; run `bash scripts/fix-prompt-check.sh <prompt-file> [--label <what>]`|
|name-hygiene.sh: Refuses denied names on any public surface — tracked files, commit messages, or one arbitrary text input; run `bash scripts/name-hygiene.sh [--range <git-range>] [--no-history] [--text-file <path> [--label <what>]]`|
|review-ack-check.sh: Validates portable bounded-review acknowledgement fields for any project gate, and is what `trusted-pr-merge.sh` calls before merging a PR that changes a check or its policy; run `bash scripts/review-ack-check.sh '<ack note>' [--max-rounds 3]`|
|retro-evidence.sh: Assembles measured retrospective evidence without conclusions; run `bash scripts/retro-evidence.sh [--since YYYY-MM-DD | --days N] [--repo <owner/name> ...] [--acks <path> ...] [--out <file>]`|

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
| verify_cmd | `bash scripts/verify.sh` — runs the selftests under "The gate" below, one log per test, real exit codes; `CC_HARNESS_SELFTESTS` overrides the list (negative controls live in `scripts/verify-selftest.sh`); zero resolved selftests is a FAIL |
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
| auto_merge_labels | `agent/auto` (default), `agent/review` — both merged by an agent, but **the command depends on what the PR touches**: a PR changing `rules/`, `agents/`, `scripts/`, `hooks/`, `templates/`, `codex/`, any `CLAUDE.md`, `.github/`, `install.sh`, `uninstall.sh`, or a merge-gate or policy path merges via `scripts/trusted-pr-merge.sh` (which requires the review acknowledgement); everything else via `gh pr merge <PR> --squash --delete-branch`. See § Merge policy for the table. **Never `--auto`** (no required status check to wait on) |
| human_merge_labels | `human/hold` — never auto-merges. Repo settings, branch protection, `.github/`, or anything needing a person. The legacy pr-monitor treats an **unlabelled PR as this**; `scripts/trusted-pr-merge.sh` can allow an ordinary unlabelled PR only after host-side author/path classification and revalidation. |
| pr_review_gate | (none) |
| ci | none — no server-side CI; the gate is the repo's selftests run locally |
| release_merge_strategy | squash |
| browser_validation | (none) |
| quality_gate_pattern | (none) |
| co_author | (none) — never an agent, vendor or model identity; § Git commit identity in global CLAUDE.md |

## Review depth (project parameters for `rules/branch-completion-review.md`)

The global rule asks each project to carry its own class parameters. cc-harness never did, and the
cost showed: class 3 is defined by path as `scripts/**`, `**/*test*`, `**/*gate*`, `**/rules/**`,
which is substantially this whole repository. Measured 2026-09-17 — **6 of 6** merged PRs in the
previous window tripped class 3, so the trigger had no discriminating power here and every change
bought the full three-round budget. The rule was calibrated on a repo where class-3 files are a
minority and the measured problem was *under*-coverage; transplanted here it inverts.

These are parameters, not a restatement, and they change **review depth only**. They do NOT exempt
anything from the merge gate: the § Merge policy table below still routes every PR touching
`scripts/`, `rules/`, `agents/`, `hooks/`, `templates/`, `codex/`, any `CLAUDE.md`, `.github/`,
`install.sh` or `uninstall.sh` through `trusted-pr-merge.sh`, which still demands a valid
`REVIEW ACK:` line. A change that earns one round records `rounds=1`.

| Surface | Why | Rounds |
|---|---|---|
| `scripts/trusted-pr-merge.sh`, `scripts/review-ack-check.sh`, `scripts/verify.sh`, `scripts/name-hygiene.sh` + `scripts/testdata/name-hashes.txt`, `hooks/` | These decide whether anything else is allowed to merge. A defect here is silent and disables the rest. | full budget (3) |
| `rules/` where the change alters a trigger, a policy or a refusal | The rule that decides whether a check runs is the check (global rule, class 3, "including this file"). | full budget (3) |
| Logic in any other `scripts/*.sh` | Real consequences, bounded blast radius, and the gate already exercises them. | 1, extend on findings |
| Prompt prose sent to a reviewer or agent | A mistake surfaces in the next review's own output, which is a fast feedback loop. | 1 |
| Additive `*-selftest.sh` rows, `docs/`, `.beads/*.jsonl`, comment-only edits | Class 3 by path only. An added test row cannot weaken a check; a removed or *edited* one can, and that is logic — see the row above. | stated skip, ack records `rounds=0` |

`rounds=0` is legitimate **only** with `verdict=GO open_blockers=0` and a one-line stated skip in the
PR body naming which row above applies. A silent skip is not a skip.

## Merge policy

Every agent-authored PR carries **EXACTLY ONE** merge label, chosen by the commit agent at PR-creation time.

- `agent/auto` is the default for harness work: rules, hooks, scripts, docs, agents, and templates. `agent/auto` and `agent/review` are both merged by an agent; **never use `--auto`**. Which command depends on what the PR changes:

| The PR touches | Merge with |
|---|---|
| `rules/`, `agents/`, `scripts/`, `hooks/`, `templates/`, `codex/`, any `CLAUDE.md`, `.github/`, `install.sh`, `uninstall.sh`, or a merge-gate or policy path | `scripts/trusted-pr-merge.sh --repo gpxl/cc-harness --pr <PR> --checkout <dir> --gate scripts/verify.sh --merge`, run from a checkout **outside** the branch under review |
| anything else | `gh pr merge <PR> --squash --delete-branch` |

  The wrapper is not a formality on the first row: it is what requires the review acknowledgement below. It refuses to run from inside the candidate checkout, and refuses when its own worktree is parked on the PR's head commit — `~/.claude/scripts` is a symlink into a checkout of this repository, so "a different directory" and "not the branch under review" are not the same condition.
- `human/hold` is required for changes to `.github/`, branch protection or repo settings, anything touching credentials, and `install.sh` or `uninstall.sh` changes that alter what is linked into `~/.claude`, because they mutate the user's live environment on next install.
- Use `agent/review` for anything in between that warrants a glance but no human gate.
- **A PR that changes a check, or the policy behind it, merges only with a review acknowledgement.** On the first row of the table above, `scripts/trusted-pr-merge.sh` holds the PR unless its body carries an unindented, unquoted line of the form `REVIEW ACK: rounds=<n> verdict=<GO|NO-GO> open_blockers=<n> classes=<list>` that `scripts/review-ack-check.sh` accepts. A line inside a fenced code block does not count, so a PR that documents the format does not thereby satisfy it. The acknowledgement is validated with the trusted harness copy of the checker, never one from the branch under review, and re-checked after the candidate gate so a body edited mid-run buys nothing. Before this existed the merge rested on the orchestrator's own report of its own review.
- Treat an unlabelled PR as `human/hold` in the legacy monitor. The trusted host wrapper may classify an ordinary unlabelled PR as `agent/auto`, but only after it has held unknown authors and external high-risk paths, run the candidate gate, revalidated the metadata, and bound the merge to the verified head SHA.
- The wrapper also scans the PR **title and body** against the denylist before merging — a squash merge publishes the title verbatim on the integration branch, where removing a name costs a history rewrite — and classifies a renamed file by its **previous** path as well as its new one, since GitHub's GraphQL files connection reports only the destination and a check moved out of `scripts/` or `rules/` would otherwise read as an ordinary path.

If a label is missing from the repo, recreate it:

```bash
gh label create agent/auto --color 0E8A16 --description "Merge on local green"
```

### The gate

This repo has no server-side CI and no build/test commands. “Local green” means every selftest below passes at a real exit code, captured by redirect and never through a pipe; see `rules/verification-integrity.md`. A suite that ABORTS partway (unset variable, typo, missing binary) also reports failure — each carries a completion sentinel, because on bash 3.2 a script killed by `set -e`/`set -u` runs its EXIT trap with `$?` already reset to 0, so every abort used to read as PASS (cch-85b).

- `hooks/selftest.sh`
- `scripts/codex-path-selftest.sh`
- `scripts/routing-report-selftest.sh`
- `scripts/loop-report-selftest.sh`
- `scripts/retro-evidence-selftest.sh`
- `scripts/review-round-selftest.sh`
- `scripts/review-ack-check-selftest.sh`
- `scripts/rules-index-selftest.sh`
- `scripts/install-symmetry-selftest.sh`
- `scripts/codex-routing-selftest.sh`
- `scripts/codex-wait-selftest.sh`
- `scripts/codex-brokers-selftest.sh`
- `scripts/codex-jobs-selftest.sh`
- `scripts/codex-dispatch-selftest.sh`
- `scripts/trusted-pr-merge-selftest.sh`
- `scripts/name-hygiene-selftest.sh`
- `scripts/fix-prompt-check-selftest.sh`
- `scripts/verify-selftest.sh`

Run them all with `bash scripts/verify.sh` (the Agent Config `verify_cmd`, redirect its output to a file and read the exit code directly). Merge only when every listed selftest reports PASS at the PR's HEAD.
