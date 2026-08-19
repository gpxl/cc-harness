# Pipeline Contract (Gate Once, Consume the Result)

The lint+test+build triple is run **once per working tree**, by whoever gets there first, and every
later step in the pipeline **consumes the recorded result instead of re-running it**.

## Recorded results

| Emitted by | Exact line | Means |
|---|---|---|
| Orchestrator or commit agent | `VERIFY RESULT: PASS\|FAIL sha=<short-sha> tree=<short-tree>` | The project's verify (`verify_cmd`, or `test_cmd && lint_cmd && build_cmd`) ran on that tree |
| code-quality agent | `CODE QUALITY RESULT: PASS\|FAIL sha=<short-sha> tree=<short-tree> covered=<test|test-scoped,lint,coverage>` | Those gates ran on that tree; `covered=` says which |

Capture the exit code by redirect-to-file, never through a pipe (`verification-integrity.md`), then stamp the record:

```bash
stamp() { ( export GIT_INDEX_FILE="$(mktemp -u)"; git read-tree HEAD && git add -A >/dev/null 2>&1 && echo "sha=$(git rev-parse --short HEAD) tree=$(git rev-parse --short "$(git write-tree)")"; rm -f "$GIT_INDEX_FILE" ); }; stamp
```

It builds the tree in a **throwaway index** — the real index and the stash are never touched —
and `git add -A` honours `.gitignore`, so the hash covers tracked *and* untracked-but-not-ignored
files. Use it verbatim. Stash-based one-liners are **banned** for this: `git stash` does not
capture untracked files, so a new file leaves the hash unchanged and a stale green reads as
fresh.

`tree=` is the **working-tree** hash: committing the verified tree does not change it, so one
record stays valid through commit → PR → merge **as long as nothing — tracked or untracked —
changed**. Re-stamp after every edit; and note that a squash-merge onto a moved `main` produces a
**new tree** that no earlier record covers. `sha=` is forensic only.

## Consume, don't re-run

A record is valid when the command above prints the same `tree=` **and** no file was edited
after it was emitted. Then don't re-run — cite the line. If the tree changed or `covered=`
lacks the gate you need, run it once and emit a fresh line.

## Size-based fast path

Diff ≤50 changed lines, no logic under the project's `package_dir`, no UI: use the
auto-merge label, skip the review subagent, skip browser validation. Say so in one line.

## For orchestrators

Pass **this file by reference** to subagents ("gate protocol: `~/.claude/rules/pipeline-contract.md`")
rather than restating gate instructions in each prompt. Never report a gate as passed when it
was deferred — say which step still owes it.
