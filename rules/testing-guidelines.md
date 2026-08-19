# Testing & Validation Strategy

Many fast unit tests at the base; few, expensive integration tests at the top. Every test must answer: "If someone breaks this behavior, will this test catch it?"

## What to Test vs. NOT Test

| Test | Don't Test |
|------|------------|
| User-facing behavior | CSS class names / styling details |
| Accessibility | Internal component/object state |
| Critical logic (validation, errors) | DOM/HTML structure |
| Design system compliance | Third-party library internals |
| Keyboard navigation | Implementation details |

## Test Types

| Type | When | Where | Requirements |
|------|------|-------|--------------|
| Unit (TDD) | BEFORE implementing any feature | Co-located next to source (`module.test.ts` beside `module.ts`; `test_module.py` in `tests/`) | Write the failing test first; test user-facing behavior, not implementation; must pass before committing |
| Demo script | After completing a phase or feature | `scripts/demo-*` | Output states `Phase N implements: [list]`, `NOT YET IMPLEMENTED: [list]`, `KNOWN LIMITATIONS: [list]` |
| Smoke | Before deployment, after infrastructure changes | — | Fast (<2 min), happy path only: builds, starts, core feature works, external connections (DB, APIs) work |
| Integration | After a multi-phase feature is complete | Dedicated integration test directory | Multi-phase features (after final phase), critical flows (auth, payment, pipelines), cross-service communication |

Bug fixes and new modules need unit tests only. Single-phase features add a demo script; multi-phase features add integration tests at the end. Major refactors want all four.

## Test Quality Checklist (All Languages)

| # | Check | Severity |
|---|-------|----------|
| Q1 | Empty test body or `assert True` / `expect(true).toBe(true)` | **FAIL** — blocks commit |
| Q2 | Test with no assertions (only calls, no assert/expect/raises) | **FAIL** — blocks commit |
| Q3 | Mock assertions only check `.called` / `toHaveBeenCalled()` without verifying args | WARN |
| Q4 | Test re-implements source logic (tautological) | WARN |
| Q5 | Only happy-path tests — no error/edge-case coverage | WARN |
| Q6 | Tests implementation details (CSS classes, private state, DOM structure) | WARN |
| Q7 | Asserts on private/internal state when public API exists | WARN |
| Q8 | Validation schemas, API endpoints, config keys, or enum switches where not all are exercised (behavioral completeness gap) | WARN |

WARN findings do not block. The code-quality agent files them as tracker tasks in the same run it reports them (`agents/code-quality.md`) — don't leave them to the orchestrator.

### Anti-Patterns

| Pattern | Why it's bad |
|---------|-------------|
| `assert func(x) == func(x)` | Tautology — always passes |
| Mock `.called` with no arg check | Proves call happened, not correctness |
| Copying production logic into expected values | If the logic is wrong, the test is wrong too |
| One test per uncovered line | Fragile, meaningless, breaks on refactor |
| `assert result is not None` as only check | No meaningful verification |

### Principles

Test the contract, not the implementation (assert outcomes, not that line N ran). Use realistic, production-shaped inputs. One behavior per test, named after what it verifies. Edge cases (empty, None, zero, boundary) and error paths are first-class, not extras.

## Session Close Protocol

Before saying "done" or "complete":

```
[ ] 1. Tests pass, demo script runs (if the feature has one), smoke test (if major)
[ ] 2. Verify (lint + test + build) — run ONCE, record the result; see pipeline-contract.md
[ ] 3. git status (read-only check of what changed)
[ ] 4. code-quality → commit agent (stages, commits, pushes, opens PR)
```

Never run `git add` / `commit` / `push` by hand (`agent-enforcement.md`). **Work is NOT done until pushed and the PR is open.**

## Accessibility & Responsiveness

Use semantic HTML and appropriate ARIA roles; test keyboard navigation and screen reader compatibility.
