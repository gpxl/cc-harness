# cc-harness

This is the development harness I use with
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) and native Codex. It combines six
Claude agents, five Codex roles, and a set of shared rules for testing, verification, git, and
review.

I publish it as a working reference, not a supported product. The repository records both the
current workflow and the failures that shaped it. If you want to understand the reasoning before
installing anything, start with the [design rationale](docs/design-rationale.md).

## Before you install

There is no release process, versioning promise, or server-side CI. More importantly,
`./install.sh` changes how every Claude Code and Codex session on your machine behaves: it links
this repository into `~/.claude/` and `~/.codex/`.

Read [`install.sh`](install.sh) and [`SECURITY.md`](SECURITY.md) first. The installer backs up real
files and directories before replacing them. `./uninstall.sh` restores the latest backup and
removes the hook registrations and `CODEX_PLUGIN` setting it installed, but you should still
understand the changes before making them.

## What it does

The Claude agents form a development pipeline:

| Agent | Role |
|---|---|
| **code-quality** | Checks changed code for test quality, coverage, and lint problems. |
| **test-writer** | Adds behavioral tests for gaps found by code-quality. |
| **commit** | Consumes the recorded checks, creates the commit, pushes the branch, and opens the PR. |
| **pr-monitor** | Watches CI where CI exists, and merges only when the project's branch and label rules allow it. |
| **release** | Audits documentation, updates versions and changelogs, tags, and creates GitHub Releases. |
| **verification** | Tries to break the finished change before it is reported done. |

Native Codex uses five shared, bounded roles: explorer, runner, worker, analyst, and reviewer.
Projects inherit them without replacing personal Codex settings or roles.

The supporting rules cover the parts that are easy to get subtly wrong: meaningful tests, honest
exit codes, feature-branch discipline, one gate per working tree, parallel-session isolation,
bounded review, and keeping private project identities off public surfaces.

## Install

```bash
git clone https://github.com/gpxl/cc-harness.git
cd cc-harness
./install.sh
```

The installer links:

- `agents/`, `rules/`, `hooks/`, and `scripts/` into `~/.claude/`
- `global/CLAUDE.md` to both `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`
- the generated `harness_*` role files into `~/.codex/agents/`

Use `CC_HARNESS_CLAUDE_DIR=/path/to/.claude` or
`CC_HARNESS_CODEX_DIR=/path/to/.codex` for an isolated target.

The installer leaves unrelated Codex roles and `~/.codex/config.toml` alone. It stops before
changing Codex if a personal file, directory, or foreign symlink already uses one of the managed
`harness_*.toml` names.

Keeping the global instructions here makes changes reviewable and reversible. It also means
`~/.claude/rules` points into the current working tree, so switching branches changes the live
rules beneath running sessions.

## Configure a project

Add an `## Agent Config` table to the project's `CLAUDE.md`:

```bash
cat templates/agent-config.md
```

The table tells the shared agents which commands and policies apply: tests, lint, build, coverage,
CI, versioning, merge strategy, browser checks, branch naming, and worktree isolation. Use `(none)`
when a capability does not exist. See the [full template](templates/agent-config.md) for every key
and example.

Project files should hold local parameters and constraints, not copies of the global rules. A
project-level agent at `<project>/.claude/agents/<name>.md` may override a global agent when the
project genuinely needs different behavior.

## How the pipeline works

```text
change
  → code-quality → test-writer when needed
  → full verify, once for this working tree
  → commit → push → pull request
  → pr-monitor when the project has CI
  → release when the project has a version strategy

non-trivial work
  → adversarial verification before completion
```

The full lint, test, and build gate runs once per working tree. Its result is tied to the tree hash,
so later steps can reuse it safely and any edit invalidates it. The scoped checks in code-quality
are a pre-check, not a second full gate. The exact contract lives in
[`rules/pipeline-contract.md`](rules/pipeline-contract.md).

Agents read project configuration at runtime rather than hardcoding toolchains. The same pipeline
can therefore work in Python, TypeScript, Swift, Go, or a documentation-only repository.

## Native Codex routing

Native Codex projects inherit the shared `harness_*` roles. Keep project-specific constraints in
`AGENTS.md`; do not copy the generic role prompts or model defaults into each project.

After installation, check a project without changing it:

```bash
scripts/codex-routing-check.sh --project /path/to/project
```

The check reports missing links, local role shadows, and copied routing defaults. After changing
the shared model table, regenerate and validate the role catalog with:

```bash
scripts/sync-codex-agents.sh
scripts/sync-codex-agents.sh --check
```

The semantic checks require Python 3.11 or newer for the standard-library `tomllib`; they install
no third-party packages. Some clients need a new Codex session before they rediscover the roles.
See the [native subagent configuration guide](https://learn.chatgpt.com/docs/agent-configuration/subagents)
for client behavior.

## Trusted PR merges

`scripts/trusted-pr-merge.sh` is a host-side wrapper for repositories that need to gate pull
requests from outside contributors. Keep the wrapper outside the checkout it evaluates. It checks
the author, labels, and changed paths, runs the candidate gate, fetches the metadata again, and
binds a squash merge to the revalidated head SHA.

Its default is a dry run. Pass `--merge` only when you intend to merge:

```bash
scripts/trusted-pr-merge.sh \
  --repo OWNER/REPO --pr 42 \
  --checkout /trusted/path/to/candidate-checkout \
  --gate scripts/verify.sh \
  --merge
```

## Where to read next

- [`docs/design-rationale.md`](docs/design-rationale.md) explains the main design decisions.
- [`docs/README.md`](docs/README.md) maps the rules, incident histories, and retrospectives.
- [`rules/`](rules/) and [`agents/`](agents/) contain the operative text loaded into sessions.
- [`docs/reference/`](docs/reference/) holds maintainer detail and incident evidence that should
  not consume context in every session.

Incident reports use purpose-based pseudonyms such as `AudioApp` and `AudioWebsite`; the
[documentation index](docs/README.md) explains them.

## Uninstall

```bash
./uninstall.sh
```

Uninstall removes harness-owned symlinks and hook registrations, clears the installed
`env.CODEX_PLUGIN` value from `~/.claude/settings.json`, and restores backed-up Claude directories
or Codex `AGENTS.md`. It leaves unrelated settings, personal Codex roles, directories, and
configuration in place.

## Customize

Fork the repository and adapt the markdown agents and rules to your workflow. Typical changes are
project thresholds in Agent Config, model choices in agent frontmatter, and additional files under
`agents/` or `rules/`.

## License

[MIT](LICENSE).
