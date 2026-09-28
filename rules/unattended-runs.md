---
paths:
  - "**/.claude/skills/**"
  - "**/.claude/agents/**"
  - "**/.claude/rules/**"
  - "**/*worktree*"
---
# Unattended Runs (A Text-Only Turn End Is a Report, Not Completion)

Claude Opus 5.5 reports progress as it works, and some of those reports end the turn with text
instead of a tool call. A loop with nobody watching that reads such a turn as "task finished" stops
halfway and records a partial run as a complete one. Anthropic documents this and the mitigations
in *Prompting Claude Opus 5.5* § Unattended agentic runs
(`https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5`).
This rule applies them to the harness.

**Scope: runs with no human to answer.** Scheduled tasks and cron-launched routines, `/loop` in dynamic
mode, Workflow scripts, and fix-round loops driven by a script. **Interactive sessions are out of
scope.** Someone is there to answer, and a check-in there is the correct behavior.

## The protocol

| Situation at end of turn | Do |
|---|---|
| Text only, open checklist items, no blocker stated | Continue: send a short message naming the open items, and ask for the blocker if one of them is stuck (template below) |
| Text only, and it states a blocker only the user can clear, or one the agent is deliberately kept from | Stop and surface it. That is the kind of stop you want |
| A background command, Codex job or subagent it started is still running | Not done. Wait for it (`codex-wait.sh` PID bridge, `codex-dispatch-protocol.md` §3), then return its output as the next message |
| 2–3 automatic continuations already sent on the same task | Stop and hand the run to a human for review. A run that is genuinely stuck must end visibly, not loop |

**The checklist is the instrument.** The task's parts must live somewhere the model updates and the
loop can read: beads (`bd` issues for the run), or a file named in the prompt. Without one, "open
items" is the model's own opinion, and the loop cannot tell a report from a finish
(`verification-integrity.md` § Instruments).

A cheaper model can serve as the check instead: state the completion condition up front, and have
it compare the conversation against that condition at each end of turn. When the condition is
unmet, its reason becomes the next user message. The same 2–3 cap applies.

### Continuation message

```text
Open items remain: <item>, <item>. Continue with them. If one is blocked, name what blocks it.
```

Name the items. A bare "continue" invites another summary.

## Standing instruction for unattended prompts

In the system prompt or preamble of an **unattended** skill, agent or routine, include a paragraph
that names the early stops the run must not make and the ones it should. Put it there from the
first request, because adding it mid-session changes the prompt prefix. It should cover:

- **Unwanted stops:** a summary that announces the next step without taking it; an offer to
  continue unless the user objects; a list of decisions none of which actually blocks the work;
  stopping because the turn feels long or a milestone was reached.
- **Wanted stops:** nothing can move without the user, or what blocks the work is deliberately
  protected from the agent.
- **Status notes and recommendations** go in the same message as the next tool call.
- **Confirmation for risky or irreversible actions still applies.** This paragraph never overrides
  it, or any gate in `agent-enforcement.md`.

The guide's own example paragraph (same section) is a good starting point to adapt. Expect somewhat
more tool calls and tokens per run. **Never add it to interactive skills or agents.**

## Relationship to other rules

- `codex-job-status-integrity.md`: `queued`/`running` is not a deliverable. This rule is the same
  principle applied to the model's own turn boundary.
- `codex-dispatch-protocol.md` §4a: the cross-round runaway signature. The 2–3 continuation cap here
  is the within-task counterpart.
- `verification-integrity.md`: a loop that cannot tell "finished" from "paused to report" is an
  instrument that cannot tell healthy from not looking.
