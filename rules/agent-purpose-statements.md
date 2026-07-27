# Purpose Statements

Applies to two things: **agents** (why this agent is being invoked and how its output will be used) and **plans** (why each phase exists and what depends on it).

When manually orchestrating agents (using the Agent tool or building workflows), include a purpose statement that tells the agent **why** it's being invoked and **how** its output will be used.

## Why Purpose Statements Matter

Without a purpose statement, an agent optimizes for completeness. With one, it optimizes for relevance. A code-quality agent asked to "check this module" will produce a full report. The same agent told "this is a quick pre-merge check — just verify the happy path" will focus on what matters.

## Pattern

### In Agent Prompts (frontmatter)

Add a `purpose` field to `.claude/agents/*.md` frontmatter:

```yaml
---
name: code-quality
description: Evaluates test coverage, quality, and lint.
purpose: >
  Output informs whether to proceed to commit or delegate to test-writer.
  Focus on actionable gaps, not informational metrics.
model: claude-haiku-4-5-20251001
tools: Bash, Read, Glob, Grep
---
```

### In Manual Agent Orchestration

When calling agents via the Agent tool, prepend a purpose line:

| Context | Purpose statement |
|---------|-------------------|
| Pre-merge check | "Quick check before merge — verify happy path only" |
| PR description | "This informs a PR description — focus on user-facing changes" |
| Implementation planning | "Report file paths, line numbers, and type signatures — I need this to plan implementation" |
| Bug investigation | "Find the root cause — I'll fix it, just tell me where and why" |
| Code review | "Review for correctness and safety — skip style nits" |
| Test writing | "Code-quality reported gaps — write tests for the specific behaviors listed" |
| Release evaluation | "Check if unreleased commits warrant a release — I need a yes/no with reasoning" |

### In Skills That Fork Subagents

When a skill spawns an agent, the skill prompt should set the agent's purpose:

```markdown
## When spawning the code-reviewer agent
Purpose: "This review feeds into the PR comment — be concise, actionable, and cite line numbers."
```

## Example Purpose Statements for Common Agents

| Agent | Suggested purpose |
|-------|-------------------|
| code-quality | Output informs commit/test-writer delegation — focus on actionable gaps |
| test-writer | Code-quality reported specific gaps — write tests for listed behaviors only |
| release | Evaluate and execute release — output is the release itself or a no-release reason |
| commit | Stage and commit changes — output is commit SHA or failure details |
| pr-monitor | Watch CI and merge on green — output is merge confirmation or failure report |
| content (custom) | Draft content from session — output goes through writer agent for voice matching |
| writer (custom) | Produce voice-matched draft — output is the final publishable text |

---

# Plan Purpose Statements

**Every phase of every plan opens with a purpose block.** Applies to plan files written in plan mode, ADRs with phased rollouts, and any multi-step proposal handed to a human for a fund/no-fund decision.

## Why this exists

A plan that lists *what* happens in each phase, without *why*, cannot be evaluated — only executed. The reader cannot tell which phases are load-bearing, which are optional, what the sequencing buys, or what the plan costs beyond effort. Reviewers then approve or reject on gut feel, and mid-flight the team cannot answer "can we drop this phase?" without re-deriving the entire dependency graph.

Writing the block is also a check on the author. On a real plan (Sanity typesafety migration, 2026-07) the discipline surfaced two things the prose had hidden: three phases whose **Supports** field was empty — which is the structural argument for deferring them, stronger than the sequencing argument originally given — and the fact that the single phase carrying the entire business outcome was also the largest, least-bounded and least reversible. Neither was visible until each phase had to declare what depended on it.

## The four fields

| Field | Answers | Failure mode it prevents |
|-------|---------|--------------------------|
| **Purpose** | What question does this phase answer, or what does it make true? One sentence. | A phase that exists because it seemed like the next step |
| **Supports** | Which later phases consume its output? | Orphan phases; and the reverse — silently dropping a phase that something else needs |
| **Reduces** | Which risk does it retire? | Work with no stated payoff |
| **Introduces** | Which risk does it create or expose? | A plan that reads as pure upside |

**`Introduces` is the field authors skip, and the one reviewers need most.** Every phase costs something — a new failure mode, a workflow change for someone outside the team, an unwind that gets harder. A block with an empty `Introduces` is usually not free; it is unexamined.

**An empty `Supports` is a finding, not a formatting problem.** If nothing downstream consumes a phase, say so explicitly — that is the argument for deferring, descoping, or shipping it separately. Do not paper over it.

## Format

```markdown
> **Purpose:** one sentence — the question this phase answers.
> **Supports:** which later phases depend on it (or "nothing — deliberately optional").
> **Reduces:** the risk it retires.
> **Introduces:** the risk it creates, and what controls it.
```

**Gate phases get the long form.** A phase whose output is a *decision* rather than an artifact — a spike, a go/no-go, a timeboxed investigation — earns a fuller treatment: why the phase exists at all, each sub-question broken out with what it is for and which risk it reduces, and explicit numeric exit criteria. These are the phases most often written as a bare list of commands, and the ones where that hurts most, because the reader cannot tell a successful run from a degraded one.

## Interaction with other rules

- **`verification-integrity.md`** — `Reduces` and `Introduces` are claims. A phase claiming to reduce a risk needs a check that could actually detect that risk still present. Purpose blocks make the claim explicit and therefore falsifiable; do not let them become decoration.
- **Plan-mode workflow** — write the block when the phase is drafted, not retrofitted at the end. Retrofitted blocks rationalise the plan you already wrote; blocks written first change it.
