# Security

This is a personal reference archive, not a supported product. There is no release process, no
advisory feed, and no server-side CI attesting anything about the contents. Read what follows
before running any of it.

## What this repository can do to your machine

| Surface | What it does |
|---|---|
| `install.sh` | Symlinks `agents/`, `rules/`, `hooks/`, `scripts/` into `~/.claude/`, points `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` at `global/CLAUDE.md`, links `harness_*` roles into `~/.codex/agents/`, and merges hook registrations into `~/.claude/settings.json`. It backs up anything real it would replace and aborts on a role-name collision, but it does change how **every** Claude Code and Codex session on the machine behaves. |
| `global/CLAUDE.md` | Loaded into every session once installed. Because `~/.claude/rules` is a symlink into the working tree, checking out a different branch changes the live ruleset under any running session. |
| `hooks/` | Registered `PostToolUse` hooks run on your machine as you work. |
| `scripts/trusted-pr-merge.sh` | A merge wrapper that is a security boundary in its own right: it classifies PR author, labels and changed paths, holds untrusted combinations, and binds the merge to a revalidated head SHA. Keep it **outside** the checkout it gates. Its default is a dry run; `--merge` is the only thing that merges. |
| `scripts/codex-*.sh` | Dispatch and manage OpenAI Codex jobs, which execute with write access to the workspace they are given. |

Read `install.sh` and `uninstall.sh` before running either. `uninstall.sh` removes only symlinks
whose target it verifies, and restores the most recent backup.

## Reporting

Open an issue at <https://github.com/gpxl/cc-harness/issues>. For anything you would rather not
post publicly, say so in an issue without details and a private channel will be arranged.

Because this is an archive rather than a maintained tool, expect no service-level commitment on
response time.

## Secrets

No credentials, tokens, or `.env` files belong in this repository, and none are present. Private
project identities are pseudonymized; `rules/public-surface-hygiene.md` states the policy and
`scripts/name-hygiene.sh` enforces it as part of the repository's own gate.
