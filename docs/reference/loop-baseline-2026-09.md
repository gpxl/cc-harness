# Bounded Review Loop Baseline — 2026-09

| Measure | Baseline |
|---|---|
| Review rounds per branch, StemLab `.build/merge-gate/acks`, 08-30→09-04 | 1, 1, 2, 5, 6, 4, 2 |
| PR #410 | session: 12 rounds; 22 commits; 19 `fix(` |
| PR #415 | 4 rounds; blockers 4→9→6; one fabricated |
| Session `5f8ebb39` | 2,360 assistant messages; 963 Bash; 60 Agent; 65 `merge-gate` invocations; 156 `test.sh`; 90 `swift build` |
| Peer messages per session | 29, 20, 17, 15, 14 |
| Feature PR open→merge | #390: 74h; #392: 59h; #391: 49h |
| Rule rewrites in this repo | 11 in 8 days |

| Target | Budget |
|---|---|
| Rounds | ≤2 typical; hard cap 3 |
| `fix(` after first review | ≤3 |
| `merge-gate` runs | ≤2 per PR |
| Peer messages | ≤6 per session |
| Assistant messages | ≤150 per merged PR |
| Feature PR | ≤12h |
| Post-merge escapes | not above ≈2 per 10 PRs |

| Gate | Measure | On fail |
|---|---|---|
| A — after the rule+gate land | Next 5 merged StemLab PRs: rounds ≤3, `fix(` ≤3, gate runs ≤2, ack fields parse | Fix the instrument or the text; never raise the cap. |
| B | Next 5 sessions: peer messages ≤6, assistant messages/PR ≤150 | — |
| C | 10 PRs: escapes not above baseline | Widen the budget to 4 only on a bead proving a round ≥4 would have caught an escape. |
