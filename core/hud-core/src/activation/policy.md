# Activation Selection Policy

This document is the human‑readable companion to `policy.rs`. If you change the logic, update this file and the `POLICY_TABLE` array together.

## Candidate Ranking (Highest → Lowest)

Rank order is deterministic and always applied in this order:

1. Live shells beat dead shells.
2. Path specificity: exact > child > parent.
3. Tmux preference applies **only** when:
   - a tmux client is attached, **and**
   - path specificity is tied.
4. Most recent `updated_at` wins. Invalid timestamps lose.
5. Higher PID breaks ties deterministically.

## Why This Order?

- We never allow a weaker path match to beat an exact match.
- Tmux preference is a tie‑breaker, not a filter.
- Determinism matters; HashMap iteration order should never affect outcomes.

## Examples

### Example 1 — Exact beats parent tmux

Project: `/Users/pete/Code/myproject`

| Candidate | Match | Tmux | Result |
| --- | --- | --- | --- |
| `/Users/pete/Code` (tmux) | parent | yes | loses |
| `/Users/pete/Code/myproject` (Ghostty) | exact | no | wins |

### Example 2 — Tmux tie‑breaker

Project: `/Users/pete/Code/capacitor`

| Candidate | Match | Tmux | Result |
| --- | --- | --- | --- |
| `/Users/pete/Code/capacitor` (tmux) | exact | yes | wins (if attached) |
| `/Users/pete/Code/capacitor` (Ghostty) | exact | no | loses |

### Example 3 — Deterministic tie

Two identical entries (same path, tmux flag, timestamp). Higher PID wins.

## Trace Output

When `CAPACITOR_ACTIVATION_TRACE=1`, Rust emits a `DecisionTraceFfi` with:
- Policy order
- Candidate ranking keys
- Selected PID

Swift logs the formatted trace via `formatActivationTrace(...)`.
