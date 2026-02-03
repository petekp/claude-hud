# Subsystem 1: Daemon Core State & Aggregation

### [Daemon Core] Finding 1: `is_locked` field is legacy naming

**Severity:** Low
**Type:** Stale docs / legacy naming
**Location:** `core/daemon/src/state.rs:303-312`

**Problem:**
`ProjectState` exposes `is_locked` even though locks are no longer part of the daemon architecture. The value is currently `state != Idle`, which is effectively “has a non-idle session.” The name implies lock-file semantics that no longer exist, which can mislead client logic and future maintainers.

**Evidence:**
`ProjectState` is populated with `is_locked = aggregate.state != Idle` (`state.rs:303-312`), and the Swift client maps it to `isLocked` (see `apps/swift/Sources/Capacitor/Models/DaemonClient.swift`).

**Recommendation:**
Rename `is_locked` to `has_session` or `is_active` across the daemon protocol and clients. If rename is too disruptive right now, add an explicit comment in the protocol schema or client code clarifying that `is_locked` means “non-idle session state.”
