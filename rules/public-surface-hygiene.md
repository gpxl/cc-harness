# Public Surface Hygiene

Any repository can become public, and one of them already is. Before a real name reaches a file,
a commit message, a PR body or a tracker description, substitute the pseudonym — because the
moment it lands there, removing it costs a history rewrite and a force-push.

Always loaded, not `paths:`-scoped, on purpose: the highest-risk surfaces are commit messages and
PR bodies, and those have no path to trigger on.

## Never write these on a public surface

A client, employer, product, or private-repo name · a ticket prefix (`ABC-1234`) · a bead or issue
id from another project's tracker · a private-repo PR number · a product-internal feature noun ·
an absolute path that contains any of the above.

"Public surface" means every tracked file, **every commit message**, every PR title and body, and
every tracker description that could sync somewhere public. A commit message is as public as a
file, and a squash-merge body gets published verbatim.

## Substitute by purpose, not by client

`AudioApp`, not `ClientA` or `Project A`. A purpose-named pseudonym still carries the lesson — an
incident about a native macOS audio app reads as one, while `Project A` makes the reader guess.

The real↔pseudonym table lives **outside any repo**, at `~/.claude/private/project-pseudonyms.md`.
Keep it consistent across entries: the same repo is `AudioApp` in every retrospective, forever.

## Rename the domain, not just the repo

A feature noun identifies a product as surely as its name does. Generalize each to its role — a
named browse tab becomes "a paginated browse tab", a named linking RPC becomes "an external-id
linking RPC".

**The exception is where the technology *is* the finding.** A sandbox that cannot run a Swift
macro plugin, or a language's memberwise-init visibility rule, are generic facts about that
language and identify no product. Keep those concrete; a lesson stripped of the mechanism is not
a lesson.

## Enforcement

`scripts/name-hygiene.sh` scans tracked files and commit messages and fails naming the token, file
and line. It is wired into `scripts/verify.sh` through the gate list in `CLAUDE.md`, so a leak
fails the same gate as a broken test. Its denylist (`scripts/testdata/name-hashes.txt`) holds
SHA-256 hashes only — no plaintext — so it is safe to publish and works on any clone.

**Those hashes are obfuscation, not secrecy.** Unsalted SHA-256 of a short name falls to a
dictionary. They exist to stop accidental recurrence and republication, which is the actual
threat; salting would need a machine-local key and would break the check on a fresh clone. Do not
mistake the denylist for a control on the names themselves.

When the check fires, fix the text — never add a name to an allowlist, and never weaken the
tokenizer to get past it.

## Related

`verification-integrity.md` — a missing denylist is exit 2, never "clean": an instrument that
cannot see must not report healthy.
