---
paths:
  - "**/*handoff*"
  - "**/*handoff*/**"
  - "**/*deliverable*"
  - "**/*deliverable*/**"
  - "**/*.fig"
---

# Client Hand-off

A repository handed to a client is the client's to keep, read and forward. Everything in it — every
file on every branch, every commit message, every pull-request title, body, comment and **edited
revision of a body** — is read by people who never saw how it was made. The working method behind
it (this harness, its gates, its reviewers, its trackers, its rates) stays here. This rule is how a
delivery is prepared, guarded and signed off, so that nothing internal leaks and the client can run
what they were given without us.

## What ships and what stays

**Ships:** the deliverable itself, and everything the client needs to use, change and rebuild it
without us — sources, build scripts, the documentation a new maintainer needs, the platform facts
and click paths a person must follow by hand.

**Never ships:**

| Category | Examples |
|---|---|
| Harness | This repository's name, rule and script names, agent and subagent names, model routing, model names, "the harness" |
| Review and gate stamps | `REVIEW ACK:` and its `key=value` fields, `VERIFY RESULT:` / `CODE QUALITY RESULT:` / `COMMIT RESULT:` lines, tree/sha stamps, "mutation-checked", "negative control" |
| Tracker | Bead ids, `bd` commands, `.beads/` |
| Attribution | Agent or vendor `Co-authored-by` trailers, generated-with footers, agent author identities |
| Personal | Home-directory paths, scratchpad paths, `~/.claude` paths, personal emails, "user decision" notes |
| Other clients | Any other client's or project's name or ticket namespace |
| Commercial | Rates, invoices, retainers, statements of work, upsell notes |
| Secrets | Analytics keys, tag-manager ids, API tokens, private keys |

### What to hand over (client self-sufficiency) vs. what to keep

A judgment call per delivery. The test: does the client need it to **use or maintain** what they
paid for, or is it **how we work**? Record each call here when a new kind of material comes up; the
first delivery set the precedent:

| Kept back | Handed over | Why |
|---|---|---|
| Full visual-conformance harness | Platform API gotchas and click paths | The client maintains the site by hand; the harness is our QA method |
| Render-crop and cross-engine gates | Design-tool page-build scripts | Builders let the client add pages; the gates are our review apparatus |
| Browser-driven designer automation | | The kit sends those steps to a person, so the automation is ours alone |
| Blog-image system, 3D renders | | Production tooling we run as a service, not part of the kit |
| Review/gate pipeline, internal rules and agents | | How we work, never what they bought |

## Set-up, once per delivery repository

1. **Register it** in the private registry (`~/.claude/private/client-deliverables.conf`, never
   committed): `OWNER/REPO client=<Pseudonym> allow-domain=<their domain>[,…] terms=<file>`. The
   registry is the one thing that makes the commit agent and `scripts/trusted-pr-merge.sh` treat
   the repository as a client deliverable; it does not depend on the client's files. An Agent
   Config with `| deliverable | client |` and no registry line is refused until it is registered.
2. **Write the terms file** (private): one regex per line for client-specific internal terms the
   generic scan cannot know (internal ticket prefixes, internal site names, team handles).
3. **Install the push guard** in every working clone: `scripts/handoff-scan.sh --install-hook <clone>`.
   It runs the local scan before every push and blocks it on a hit. It refuses to replace a
   different `pre-push` hook.
4. **Run the first full audit with history**: `scripts/handoff-scan.sh OWNER/REPO --history`. A hit
   in a blob that is no longer at any tip still ships with the clone.

## Guards on every change

| Where | What runs |
|---|---|
| Commit agent (client mode) | No stamps, tracker ids or attribution in messages, titles or bodies; each one scanned with `handoff-scan.sh --text-file`; the clone scanned before push. Review and verify records go to the local ledger `~/.claude/private/handoff-ledger/<owner>/<repo>/pr-<n>.ack` (`agents/commit.md` § Client deliverables) |
| Push | The `pre-push` guard |
| Merge | `scripts/trusted-pr-merge.sh` reads the `REVIEW ACK:` from the ledger, not the body, and holds a title or body with any harness term (`harness-text-in-title-or-body`) |
| Branch-completion review | The acknowledgement is recorded in the ledger, never in the body (`branch-completion-review.md`) |

**Coverage:** an ordinary client pull request (no check or policy change) merges with plain
`gh pr merge`, so its title and body are checked only by the commit agent's Step 10 scan; a merge
through `scripts/trusted-pr-merge.sh` checks them again.

**Known gap:** a comment the orchestrator posts on a client pull request by hand is only caught by
the next full scan, after the fact. Don't post review findings, stamps or gate output as comments
on a client repository.

## Removing a leak

| Where it is | Fix |
|---|---|
| A file at a branch tip | Fix it in a normal commit |
| A commit message, or a file only in history | A history rewrite and force-push: ask the user first, every time |
| A PR title, body or comment | Edit it |
| An **edited revision** of a PR body or comment | Editing does not remove it: GitHub keeps every revision. Open the PR → the "edited" dropdown on the body → each bad revision → **Delete revision from history**. Only the repository owner can, in the web UI |

## Sign-off

A delivery is signed off when all of these hold, in this order:

1. `scripts/handoff-scan.sh OWNER/REPO` exits 0 (all refs including PR heads, all commit messages,
   all PR and issue text and edit history, releases, `.fig` contents). Exit 2 is not clean.
2. The hand-over table above has a row for every kind of material in the repository.
3. The client has been given the repository, and the user has confirmed the hand-over.

Re-run step 1 before every later hand-over of the same repository.
