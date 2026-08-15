# Testing & Validation Strategy

Comprehensive quality assurance guidelines for all projects. Many fast unit tests at the base; few, expensive integration tests at the top.

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
| Unit (TDD) | BEFORE implementing any feature | Co-located next to source (`module.test.ts` beside `module.ts`; `test_module.py` in `tests/`) | Write the failing test first; test user-facing behavior, not implementation; must pass before committing. Run with the project test command (see project CLAUDE.md) |
| Demo script | After completing a phase or feature | `scripts/demo-*` | Output must state `Phase N implements: [list]`, `NOT YET IMPLEMENTED: [list]`, `KNOWN LIMITATIONS: [expected behaviors]` |
| Smoke | Before deployment, after infrastructure changes | — | Fast (<2 min), happy path only: app builds, app starts, core feature works, external connections (DB, APIs) work |
| Integration | After a multi-phase feature is complete | Dedicated integration test directory | Create for multi-phase features (after final phase), critical flows (auth, payment, pipelines), cross-service communication |

## When to Use Each Test

| Scenario | Unit | Demo | Smoke | Integration |
|----------|:----:|:----:|:-----:|:-----------:|
| New component/module | Yes | - | - | - |
| Bug fix | Yes | - | - | - |
| Single-phase feature | Yes | Yes | - | - |
| Multi-phase feature | Yes | Yes/phase | - | Yes final |
| Pre-deployment | - | - | Yes | - |
| Major refactor | Yes | Yes | Yes | Yes |

## Test Requirements by Phase

- **During implementation:** write unit tests (TDD) before code, run them after each change, fix failures immediately.
- **After a phase completes:** create/update the demo script, run it and verify, all unit tests pass.
- **Before "done":** all unit tests pass, demo runs successfully, lint and build pass.

## Session Close Protocol

Before saying "done" or "complete":

```
[ ] 1. Run tests          (fix any failures)
[ ] 2. Run demo script    (if feature has demo)
[ ] 3. Run build          (verify no errors)
[ ] 4. Smoke test         (if major change)
[ ] 5. git status         (check changes — read-only)
[ ] 6. Commit agent       (code-quality → commit agent stages, commits, pushes, opens PR —
                           never run git add / commit / push by hand; see agent-enforcement.md)
```

**Work is NOT done until pushed and the PR is open** (via the commit agent).

---

## Test Quality Checklist (All Languages)

Every test must answer: "If someone breaks this behavior, will this test catch it?"

### Quality Gates

| # | Check | Severity |
|---|-------|----------|
| Q1 | Empty test body or `assert True` / `expect(true).toBe(true)` | **FAIL** — blocks commit |
| Q2 | Test with no assertions (only calls, no assert/expect/raises) | **FAIL** — blocks commit |
| Q3 | Mock assertions only check `.called` / `toHaveBeenCalled()` without verifying args | WARN |
| Q4 | Test re-implements source logic (tautological) | WARN |
| Q5 | Only happy-path tests — no error/edge-case coverage | WARN |
| Q6 | Tests implementation details (CSS classes, private state, DOM structure) | WARN |
| Q7 | Asserts on private/internal state when public API exists | WARN |
| Q8 | Module has validation schemas, API endpoints, config keys, or enum switches where not all are exercised by tests (behavioral completeness gap) | WARN |

### Anti-Patterns

| Pattern | Why it's bad |
|---------|-------------|
| `assert func(x) == func(x)` | Tautology — always passes |
| Mock `.called` with no arg check | Proves call happened, not correctness |
| Copying production logic into expected values | If the logic is wrong, the test is wrong too |
| One test per uncovered line | Fragile, meaningless, breaks on refactor |
| `assert result is not None` as only check | No meaningful verification |

### Principles

| Principle | Apply when |
|-----------|-----------|
| Test the contract, not the implementation | Always — assert outcomes, not that line N ran |
| Use realistic inputs | Always — production-like data, not `{"a": 1}` |
| One behavior per test | Always — name the test after what it verifies |
| Edge cases are first-class | If inputs can be empty, None, zero, boundary — test them |
| Error paths are first-class | If it can raise/throw, test that it does correctly |

### Agent Workflow

```
code change → code-quality (evaluate) → FAIL? → test-writer (fix) → code-quality (re-verify)
                                       → PASS  → track warnings as tasks → commit
```

- **code-quality agent**: evaluates coverage, lint, Q1-Q8 quality — does not write tests
- **test-writer agent**: writes behavioral tests when code-quality reports gaps
- **commit agent**: gates on `CODE QUALITY RESULT: PASS` for source changes

## Accessibility & Responsiveness

- Use ARIA roles appropriately
- Test keyboard navigation
- Test screen reader compatibility
- Use semantic HTML elements
