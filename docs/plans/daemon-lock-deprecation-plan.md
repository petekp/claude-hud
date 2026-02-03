# Daemon Lock Deprecation Plan

**Status:** completed (historical)

**Note:** As of 2026-02-02 the system is daemon-only; lock directories and lock-holder
compatibility have been removed. This plan is preserved for historical context.

This document defines the migration path from filesystem lock directories
(`~/.capacitor/sessions/{session_id}-{pid}.lock/`) to daemon-owned liveness
(`process_liveness` table + `get_process_liveness` IPC).

## Goals

- Preserve correctness for existing installs during migration.
- Avoid user-visible regressions during daemon rollout.
- Provide a clear timeline for removing lock directories.

## Phase A — Compatibility (Historical)

**Status:** completed

- Hooks previously created lock directories for compatibility.
- Daemon liveness was preferred when `CAPACITOR_DAEMON_ENABLED=1`.
- `hud-core` cleanup/lock checks routed through daemon with local fallback.
- Lock-holder used daemon-aware identity verification where possible.

**Note:** The project direction is now **daemon-only**; locks are no longer authoritative.

## Phase B — Read-only locks (Historical)

**Status:** completed

- Hooks stop creating new lock directories when daemon is healthy.
- Existing lock directories are treated as **legacy artifacts**, not authoritative state.
- UI diagnostics should surface whether lock dir mode is active (debug only).

**Gate to enter Phase B:**
- daemon liveness coverage verified across all hook event types.
- `process_liveness` replay is stable on daemon restart.

## Phase C — Removal (Completed)

- Stop reading lock directories entirely.
- Remove lock cleanup logic from `hud-core`.
- Remove lock-holder subprocess from hooks.

**Gate to enter Phase C:**
- daemon auto-start + crash recovery stable.
- fallback policy updated (daemon required).
- migration telemetry shows lock fallback usage near zero.

## Implementation Checklist

- Add a daemon health check to decide whether to write locks. (Done)
- Define a daemon health probe (use `get_health` IPC with timeout). (Done)
- Lock-mode/lock-health toggles removed (daemon-only; no compatibility).
- Hook installation normalizes commands to include `CAPACITOR_DAEMON_ENABLED=1` only.

## Open Questions (Resolved)

- Lock directories are not retained; the daemon is authoritative.
- No debug flag remains for re-enabling lock creation.
