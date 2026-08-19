# Pipeline Contract (Gate Once, Consume the Result)

The lint+test+build triple is run **once per HEAD**, by whoever gets there first, and every
later step in the pipeline **consumes the recorded result instead of re-running it**.

## Recorded results

| Emitted by | Exact line | Means |
|---|---|---|
| Orchestrator or commit agent | `VERIFY RESULT: PASS\|FAIL sha=<short-sha>` | The project's verify (`verify_cmd`, or `test_cmd && lint_cmd && build_cmd`) ran on that tree |
| code-quality agent | `CODE QUALITY RESULT: PASS\|FAIL sha=<short-sha> covered=<test,lint,coverage>` | Those gates ran on that tree; `covered=` says which |

Capture the exit code by redirect-to-file, never through a pipe (`verification-integrity.md`).

## Consume, don't re-run

A record is valid when `git rev-parse --short HEAD` still equals its `sha` **and** no file
was edited after it was emitted. Then don't re-run — cite the line. If HEAD moved, a file
changed since, or `covered=` lacks the gate you need, run it once and emit a fresh line.

## Size-based fast path

Diff ≤50 changed lines, no logic under the project's `package_dir`, no UI: use the
auto-merge label, skip the review subagent, skip browser validation. Say so in one line.

## For orchestrators

Pass **this file by reference** to subagents ("gate protocol: `~/.claude/rules/pipeline-contract.md`")
rather than restating gate instructions in each prompt. Never report a gate as passed when it
was deferred — say which step still owes it.
