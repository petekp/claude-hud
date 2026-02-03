# Subsystem 3: Swift App Consumption

### [Swift App] Finding 1: `isLocked` naming still reflects lock-file era

**Severity:** Low
**Type:** Legacy naming
**Location:** `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:139-156` and `apps/swift/Sources/Capacitor/Models/DaemonClient.swift`

**Problem:**
Swift still consumes `is_locked` from the daemon and exposes it as `isLocked` in `ProjectSessionState`. This implies lock-file semantics which no longer exist.

**Evidence:**
`SessionStateManager.mergeDaemonProjectStates` maps `state.isLocked` directly into the session state, and `DaemonClient` decodes `is_locked` (`DaemonClient.swift` JSON keys).

**Recommendation:**
Align the name with daemon meaning (e.g., `hasSession`/`isActive`) or add a clarifying comment that this is “non-idle session state,” not a lock.

---

### [Swift App] Finding 2: Comment overstates where state logic lives

**Severity:** Low
**Type:** Stale docs
**Location:** `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:6-13`

**Problem:**
The header comment says “All state logic (staleness, lock detection, resolution) lives in Rust.” In practice, the daemon is authoritative, but the Swift client still maps/merges states and uses `isLocked` directly. This isn’t a behavior bug, but the comment can mislead.

**Recommendation:**
Update the comment to say “All state logic is authoritative in the daemon; this class is a dumb client that maps daemon fields.”
