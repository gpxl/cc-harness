# Memory Discipline

Reinforcements beyond the built-in memory exclusion rules. Apply these when saving or recalling memories.

## Project-Specific Exclusions

Do NOT save memories that store:

| Excluded | Why | Where it belongs |
|----------|-----|-----------------|
| Architecture diagrams, code patterns | Derivable by reading code | Code comments, CLAUDE.md |
| File paths, function signatures | Change frequently → stale recommendations | Grep/Glob at recall time |
| Debugging solutions, fix recipes | The fix is in the code | Commit messages, code comments |
| Known bugs, feature gaps | Ephemeral; tracked elsewhere | Issue tracker, CLAUDE.md |
| Pipeline run status, progress logs | Ephemeral task state | Git history, issue tracker |
| Weekly goals, sprint items | Roll over; perpetually stale | Issue tracker, standup notes |
| Directory paths to external tools | Paths change | CLAUDE.md, project README |

## Recall-Time Verification

Before acting on any memory that names a specific artifact:

| Memory references | Verify with |
|-------------------|-------------|
| A file path | `ls` or Glob — confirm it exists |
| A function or flag | Grep — confirm it still exists |
| A config key or env var | Read the config file |
| A UI element or feature | Read the component code |
| Project state (open/closed) | Issue tracker or `git log` |

"The memory says X exists" ≠ "X exists now."

## What IS Worth Saving

| Type | Example |
|------|---------|
| User preferences & expertise | "User prefers functional style; avoid class-based patterns" |
| Process feedback (corrections + confirmations) | "Don't mock DB in integration tests — got burned last quarter" |
| Strategic vision not in code | "MVP targets solo developers, not teams" |
| Subtle framework gotchas | "Next.js App Router requires 'use client' for hooks in server components" |
| Account/resource constraints | "Free tier API — batch requests to stay under rate limits" |
