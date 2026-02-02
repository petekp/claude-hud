# Subsystem 1: Hook Event Ingestion & Session State Updates

> **Daemon-only note (2026-02):** This audit describes pre-daemon file/lock behavior. In daemon-only mode, these paths are legacy and should not be authoritative.
**Files analyzed:**
- `core/hud-hook/src/handle.rs`
- `core/hud-core/src/state/store.rs`
- `core/hud-core/src/state/types.rs`

## Summary

The hook ingestion pipeline correctly maps Claude Code hook events into session state transitions, writes to `sessions.json` atomically, and uses tombstones to suppress late events after `SessionEnd`. Lock creation is delegated to the lock subsystem and triggered on session-establishing events. File activity is recorded in a lightweight format (analyzed separately in Subsystem 5).

## Checklist Review

- **Correctness:** Event→state mapping aligns with `state/types.rs` and docs.
- **Atomicity:** `StateStore::save()` uses temp + rename for crash safety.
- **Race conditions:** Last-writer-wins is accepted; tombstones mitigate late-event races.
- **Cleanup:** `SessionEnd` removes record, activity entry, and lock (in that order).
- **Error handling:** Save errors propagate; non-critical failures are logged.

## Findings

No issues found in this subsystem beyond the activity-format duplication covered in Subsystem 5.

