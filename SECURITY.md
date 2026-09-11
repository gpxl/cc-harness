# Security

This is a personal reference archive, not a supported product. It has no release process,
advisory feed, or server-side CI attesting to its contents. Read this page before running
anything from the repository.

## What this repository can do to your machine

| Surface | What it does |
|---|---|
| `install.sh` | Symlinks `agents/`, `rules/`, `hooks/`, and `scripts/` into `~/.claude/`; points `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` at `global/CLAUDE.md`; links `harness_*` roles into `~/.codex/agents/`; and merges hook registrations into `~/.claude/settings.json`. It backs up real files and directories before replacement and aborts on a role-name collision. Once installed, it changes how every Claude Code and Codex session on the machine behaves. |
| `global/CLAUDE.md` | Loaded into every session once installed. Because `~/.claude/rules` is a symlink into the working tree, checking out a different branch changes the live ruleset under any running session. |
| `hooks/` | Registered `PostToolUse` hooks run on your machine as you work. |
| `scripts/trusted-pr-merge.sh` | A merge wrapper that is a security boundary in its own right: it classifies PR author, labels and changed paths, holds untrusted combinations, and binds the merge to a revalidated head SHA. Keep it **outside** the checkout it gates. Its default is a dry run; `--merge` is the only thing that merges. |
| `scripts/codex-*.sh` | Dispatch and manage OpenAI Codex jobs, which execute with write access to the workspace they are given. |

Read `install.sh` and `uninstall.sh` before running either. `uninstall.sh` verifies symlink targets
before removing them, restores the most recent backup, removes the hook registrations installed by
the harness, and clears its `env.CODEX_PLUGIN` value from `~/.claude/settings.json`. Unrelated
settings stay in place.

## Reporting

Open an issue at <https://github.com/gpxl/cc-harness/issues>. If the report should stay private,
open an issue without details and ask for a private channel.

Because this is an archive rather than a maintained tool, expect no service-level commitment on
response time.

## Secrets

Credentials, tokens, and `.env` files do not belong in this repository; none are present. Private
project identities use pseudonyms. `rules/public-surface-hygiene.md` defines that policy, and
`scripts/name-hygiene.sh` enforces it in the repository gate.
