# Subsystem 2: Lock Lifecycle & Liveness Verification

> **Daemon-only note (2026-02):** This audit describes pre-daemon file/lock behavior. In daemon-only mode, these paths are legacy and should not be authoritative.
**Files analyzed:**
- `core/hud-core/src/state/lock.rs`
- `core/hud-hook/src/lock_holder.rs`

## Summary

Session-based locks (`{session_id}-{pid}.lock/`) are the authoritative liveness signal. Locks are created atomically, include PID + `proc_started` for PID-reuse detection, and are released by the lock-holder when the monitored PID exits. Readers verify liveness using `proc_started` to mitigate PID reuse.

## Findings

### [LOCKS] Finding 1: Stale Lock With Reused PID Skips Re-creation

**Severity:** Medium
**Type:** Bug (edge-case correctness)
**Location:** `core/hud-core/src/state/lock.rs:524-531`

**Problem:**
`create_session_lock` treats an existing lock directory with the same PID as “already owned” and returns `None` without checking `proc_started`. If the previous lock holder failed to clean up and the PID is later reused for a new Claude process **with the same session_id**, the new process will never re-write metadata or spawn a lock-holder. That yields a stale lock that fails liveness verification, so the session runs without a lock.

**Evidence:**
The early return happens before any `proc_started` comparison:
- `create_session_lock` returns `None` when `info.pid == pid` (no `is_pid_alive_verified` check).

**Recommendation:**
When `info.pid == pid`, verify `proc_started` against the current process start time. If it doesn’t match (or is missing), treat the lock as stale and re-create it (write fresh metadata and allow lock-holder spawn).

---

## Update (2026-01-29)

- `create_session_lock` now validates `proc_started` even when `pid` matches and refreshes stale locks when mismatched or missing.
