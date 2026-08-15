# Computer Control Release

Any tool that hands an agent control of a real, user-owned interactive surface — the desktop
(`computer-use`), the iOS Simulator's live panel, or the user's actual logged-in Chrome
(`claude-in-chrome`) — should be released the moment active use ends, not held for the rest of a
task "just in case." Requesting or attaching again later is cheap; holding is not free for the
user, who cannot naturally use that surface themselves while an agent has it.

<!-- HISTORY (hidden from context, kept for maintainers):

## Why this rule exists

These tools are structurally different from ordinary file/shell tools: they take over something the
user owns and would otherwise be using themselves — their screen, their simulator window, their
logged-in browser. The existing tool-level instructions already cover the *first* half of this well
(attach/request early, as soon as it's useful to show the user something) but say little about the
second half: handing it back. Left unaddressed, the default failure mode is an agent that opens a
live surface for a legitimate reason early in a task, then keeps working through several unrelated
steps — edits, builds, reads — with that surface still attached, simply because nothing in the loop
ever prompted it to close.

This is the single-agent, single-surface analogue of `windowed-gate-serialization.md` (which
addresses N *parallel* agents flooding the user's desktop with windows at once): a different failure
mode — duration instead of concurrency — but the same underlying resource. Both rules treat the
user's screen and attention as shared and exclusive, not as idle capacity an agent can assume it can
occupy indefinitely.
-->

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
