---
paths:
  - "**/*.swift"
  - "**/*.xcodeproj/**"
  - "**/electron/**"
  - "**/ios/**"
  - "**/playwright*"
  - "**/scripts/visual-testing/**"
  - "**/.claude/skills/**"
  - "**/.claude/agents/**"
---
# Computer Control Release

Any tool that hands an agent control of a real, user-owned interactive surface — the desktop
(`computer-use`), the iOS Simulator's live panel, or the user's actual logged-in Chrome
(`claude-in-chrome`) — should be released the moment active use ends, not held for the rest of a
task "just in case." Requesting or attaching again later is cheap; holding is not free for the
user, who cannot naturally use that surface themselves while an agent has it. (Rationale:
`docs/reference/rule-histories.md`.)

## The rule

| Tool | Take control | Release it |
|------|--------------|------------|
| iOS Simulator (`mcp__Claude_Code_iOS_Simulator__control`) | `attach` right before showing the user something live | `detach` as soon as that verification/demo phase ends and the next step doesn't need the panel visible |
| Computer-use (`mcp__computer-use__*`) | `request_access` scoped to only the application(s) the immediate step needs | Stop issuing further actions once the driven interaction is done — don't keep polling/screenshotting "just to watch" unless asked to. If the exchange was more than trivial, say so when done ("done clicking around in X — it's yours again"); the user shouldn't have to guess whether the agent might still be mid-action |
| Claude in Chrome (`mcp__claude-in-chrome__*`) | Only when the task specifically needs the user's real, logged-in session — otherwise default to the sandboxed in-app Browser pane, which isn't the user's own surface and is out of scope for this rule | Close any tabs opened for the task (`tabs_close_mcp`) once done with them, rather than leaving the user's browser parked on a task page |

## Judgement: phase transitions, not every tool call

Don't release and immediately re-acquire between tightly-sequenced actions inside one continuous
interactive flow (tap, screenshot, tap, screenshot, all verifying the same feature) — that trades
"held too long" for "churns needlessly," which is its own cost. Release when the *phase* of work
changes: verification is done and the next step is unrelated code editing, a build, reading files,
or anything else that doesn't need the surface visible. Within a single flow, hold it; across a
flow boundary, let go.

## What this doesn't change

Attach-early guidance stays correct — opening as soon as it's useful to the user. This rule adds the
missing other half: closing just as promptly once the reason for holding it has passed.

## Relationship to other rules

- **`windowed-gate-serialization.md`** — that rule serializes *parallel* agents' windowed gates; this one bounds how long a *single* agent holds one surface. Compose them.
