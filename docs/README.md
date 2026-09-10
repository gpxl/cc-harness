# Documentation

Three kinds of writing live in this repository, and they answer different questions.

| Where | Question it answers |
|---|---|
| [`../rules/`](../rules/) and [`../agents/`](../agents/) | **What the harness does.** The rules and agent prompts themselves — the operative text, loaded into sessions. |
| [`design-rationale.md`](design-rationale.md) | **Why it is shaped this way.** The architectural decisions, each linked to the rule that enforces it. Start here if you are reading the repo rather than installing it. |
| [`reference/rule-histories.md`](reference/rule-histories.md) | **Why a specific rule says what it says.** Per-rule incident forensics — the measurement or the failure that put each line there. |
| [`retrospectives/`](retrospectives/) | **What happened to us over a period, and what we did about it.** Narrative, dated, with the numbers. |

`reference/` is deliberately **not** symlinked into `~/.claude/`. Nothing in it is loaded into any
session — it exists so the evidence behind a rule survives without costing context tokens on every
turn.

## Reading order

If you want to understand the system: `design-rationale.md`, then the most recent retrospective,
then `rule-histories.md` for whichever rule surprised you.

If you want to understand a single rule: open the rule, then find its section in
`rule-histories.md`. Most rules exist because something specific broke.

## A note on names

Incidents in this repository happened on real projects, which are private. They appear here under
**purpose-based pseudonyms** — the pseudonym says what the project *is*, so the lesson survives
the rename:

| Pseudonym | What it stands for |
|---|---|
| **AudioApp** | A native macOS/Swift audio application |
| **AudioWebsite** | A CMS-backed marketing web application |
| **AudioWebsiteMedia** | A sibling media/metadata service to the above |
| **WebAppMonoRepo** | A client's marketing monorepo |

Ticket ids, tracker ids and PR numbers from those projects are likewise substituted. Where a
retrospective says "AudioApp PR #7", the number is positional within this archive, not a link to
anything.

Product-internal feature names are generalized to their role for the same reason. The exception is
where the technology *is* the finding — a sandbox that cannot host a Swift macro plugin, or a
language's memberwise-init visibility rule, are generic facts that identify no product, and a
lesson stripped of its mechanism is not a lesson.

The policy is [`../rules/public-surface-hygiene.md`](../rules/public-surface-hygiene.md); it is
enforced mechanically by `scripts/name-hygiene.sh`, which runs as part of this repository's own
gate.
