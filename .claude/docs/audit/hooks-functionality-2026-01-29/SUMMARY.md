# Hooks Functionality Audit Summary

> **Daemon-only note (2026-02):** This audit describes pre-daemon file/lock behavior. In daemon-only mode, these paths are legacy and should not be authoritative.
**Date:** 2026-01-29
**Scope:** Hook ingestion, locks, configuration, diagnostics/tests, activity pipeline, shell CWD hook.

## Findings by Severity

- **High:** 1
- **Medium:** 3
- **Low:** 1

## Findings (Priority Order)

1. **[HEALTH] Hook health false positives after binary verification**
   - `core/hud-core/src/setup.rs:333-347`, `core/hud-hook/src/handle.rs:48-49`, `core/hud-hook/src/handle.rs:406-427`, `core/hud-core/src/engine.rs:756-784`
   - Diagnostics can report hooks firing even when no real hook events occurred.

2. **[HEALTH] Hook test can clobber concurrent session updates**
   - `core/hud-core/src/engine.rs:1001-1042`, `core/hud-core/src/state/store.rs:126-153`
   - `run_hook_test()` performs read–modify–write on `sessions.json` without coordination.

3. **[LOCKS] Stale lock with reused PID skips re-creation**
   - `core/hud-core/src/state/lock.rs:524-531`
   - If a stale `{session_id}-{pid}.lock` remains and the PID is reused, lock creation is skipped.

4. **[ACTIVITY] Dual activity formats add conversion overhead and drift risk**
   - `core/hud-hook/src/handle.rs:430-521`, `core/hud-core/src/activity.rs:108-199`
   - Hook writes `files[]`; engine converts to `activity[]` on every load.

5. **[CONFIG] TOCTOU race can clobber settings.json changes**
   - `core/hud-core/src/setup.rs:615-690`
   - Low-probability window between read and write.

## Recommended Fix Order

1. Prevent `verify_hook_binary()` (and related flows) from touching the heartbeat file.
2. Make `run_hook_test()` use an isolated test file or add optimistic locking.
3. In `create_session_lock`, validate `proc_started` even when `pid` matches.
4. Consolidate activity format writing/reading to a single canonical format.
5. Add locking or mtime/hash checks for settings.json or document the low-risk race.

## Remediation Status (2026-01-29)

- ✅ Heartbeat false positives fixed: heartbeat now updates only after a valid hook event is parsed.
- ✅ Hook test clobber risk fixed: `run_hook_test()` writes an isolated test file, not `sessions.json`.
- ✅ PID reuse edge case fixed: `create_session_lock` refreshes stale locks when `proc_started` mismatches.
- ✅ Activity format consolidation: hook now writes native `activity` format and migrates legacy `files` on write.
- ⚠️ settings.json TOCTOU remains a documented low-risk edge case.

**Change report:** `CHANGE-REPORT.md`
