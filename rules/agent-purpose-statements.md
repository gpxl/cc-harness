# Agent Purpose Statements

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
