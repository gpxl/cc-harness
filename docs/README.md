# Documentation

The documentation falls into four groups:

| Where | Question it answers |
|---|---|
| [`../rules/`](../rules/) and [`../agents/`](../agents/) | What the harness does: the operative rules and prompts loaded into sessions. |
| [`design-rationale.md`](design-rationale.md) | Why it works this way: the architectural decisions and the rules that enforce them. Start here if you want to understand the repository. |
| [`reference/rule-histories.md`](reference/rule-histories.md) | Why a particular rule exists: the incident or measurement behind it. |
| [`retrospectives/`](retrospectives/) | What happened over time and what changed as a result: dated narratives with supporting numbers. |

`reference/` is not symlinked into `~/.claude/` or loaded into sessions. It preserves the evidence
behind each rule without charging every turn for that context.

## Reading order

To understand the system, read `design-rationale.md`, the latest retrospective, then the relevant
section of `rule-histories.md`.

For a single rule, read the rule first, then its entry in `rule-histories.md`. Most rules exist
because something specific broke.

## A note on names

The incidents happened on private projects. Purpose-based pseudonyms keep the projects anonymous
without hiding what kind of system was involved:

| Pseudonym | What it stands for |
|---|---|
| **AudioApp** | A native macOS/Swift audio application |
| **AudioWebsite** | A CMS-backed marketing web application |
| **AudioWebsiteMedia** | A sibling media/metadata service to the above |
| **WebAppMonoRepo** | A client's marketing monorepo |

Ticket IDs, tracker IDs, and PR numbers are also substituted. "AudioApp PR #7," for example, is a
position in this archive, not a link to the original PR.

Internal feature names are generalized in the same way. Technology stays named when it is the
finding: a sandbox that cannot host a Swift macro plugin or a language's memberwise-init visibility
rule identifies no product, and removing the mechanism would remove the lesson.

[`../rules/public-surface-hygiene.md`](../rules/public-surface-hygiene.md) defines the policy.
`scripts/name-hygiene.sh` enforces it as part of this repository's gate.
