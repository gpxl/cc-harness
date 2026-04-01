# Testing & Validation Strategy

Comprehensive quality assurance guidelines for all projects.

## Testing Pyramid

```
                    ┌─────────────────┐
                    │  Integration    │  ← Few, expensive, after multi-phase work
                    │     Tests       │
                    ├─────────────────┤
                    │  Smoke Tests    │  ← Quick validation of critical paths
                    ├─────────────────┤
                    │  Demo Scripts   │  ← Phase/feature validation with sample data
                    ├─────────────────┤
                    │                 │
                    │   Unit Tests    │  ← Many, fast, TDD-driven
                    │    (TDD)        │
                    └─────────────────┘
```

## What to Test vs. NOT Test

| Test | Don't Test |
|------|------------|
| User-facing behavior | CSS class names / styling details |
| Accessibility | Internal component/object state |
| Critical logic (validation, errors) | DOM/HTML structure |
| Design system compliance | Third-party library internals |
| Keyboard navigation | Implementation details |

## Test Types

### 1. Unit Tests (TDD)

**When:** BEFORE implementing any feature
**Where:** Co-located next to source (e.g., `module.test.ts` next to `module.ts`, `test_module.py` in `tests/`)
**Run:** Project test command (see project CLAUDE.md)

**Requirements:**
- Write failing test first, then implement
- Test user-facing behavior, not implementation
- Must pass before committing

### 2. Demo Scripts

**When:** After completing a phase or feature
**Where:** `scripts/demo-*`

**Required Output:**
```
Phase N implements: [list]
NOT YET IMPLEMENTED: [list]
KNOWN LIMITATIONS: [expected behaviors]
```

### 3. Smoke Tests

**When:** Before deployment, after infrastructure changes
**Run:** Fast (<2 min), happy path only

**Checklist:**
- [ ] App builds without errors
- [ ] App starts successfully
- [ ] Core feature works
- [ ] External connections work (DB, APIs)

### 4. Integration Tests

**When:** After multi-phase feature complete
**Where:** Dedicated integration test directory

**Create for:**
- Multi-phase features (after final phase)
- Critical flows (auth, payment, pipelines)
- Cross-service communication

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

**During Implementation:**
1. Write unit tests (TDD) before code
2. Run tests after each change
3. Fix failures immediately

**After Phase Complete:**
1. Create/update demo script
2. Run demo and verify
3. All unit tests pass

**Before "Done":**
1. All unit tests pass
2. Demo runs successfully
3. Lint and build pass

## Session Close Protocol

Before saying "done" or "complete":

```
[ ] 1. Run tests          (fix any failures)
[ ] 2. Run demo script    (if feature has demo)
[ ] 3. Run build          (verify no errors)
[ ] 4. Smoke test         (if major change)
[ ] 5. git status         (check changes)
[ ] 6. git add            (stage files)
[ ] 7. git commit         (descriptive message)
[ ] 8. git push           (push to remote)
```

**Work is NOT done until pushed.**

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

### Python-Specific Patterns

```python
# DO: Test behavior
def test_rejects_negative_priority():
    with pytest.raises(ValueError, match="priority must be >= 0"):
        parse_task(priority=-1)

# DON'T: Test implementation
def test_line_42_executes():
    result = parse_task(priority=1)
    assert result is not None  # proves nothing
```

### TypeScript/React-Specific Patterns

```typescript
// DO: Test user-facing behavior
expect(screen.getByRole('button', { name: /submit/i })).toBeVisible()

// DON'T: Test CSS classes
expect(button.className).toMatch(/bg-black/)
```

## Accessibility & Responsiveness

- Use ARIA roles appropriately
- Test keyboard navigation
- Test screen reader compatibility
- Use semantic HTML elements
