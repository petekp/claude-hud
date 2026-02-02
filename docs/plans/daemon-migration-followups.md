# Daemon Migration Follow-Ups

## Observations to Revisit

- UI hitching 2-3x per second during daemon migration (likely refresh/polling pressure; investigate main-thread work + log volume).
- Session state heuristics gaps to port into daemon pipeline:
  - Esc/interrupted response leaves session stuck in Working indefinitely.
  - Terminating a session while Working transitions to Ready (should go Idle/End).

## Tracking

- Last noted: 2026-02-02
- Owner: TBD
- Status: Open

## Potential Enhancements

- Parallel sessions per project: aggregate per-project state (e.g., any Working wins) instead of last-writer-wins.
  - Current behavior: UI picks most recent session per project.
  - Idea: collapse multiple sessions with priority Working > Waiting > Compacting > Ready, with optional session count badge.
