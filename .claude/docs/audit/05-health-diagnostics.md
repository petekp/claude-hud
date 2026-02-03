# Subsystem Audit: Hook Health + Diagnostics

**Files reviewed**
- `core/hud-core/src/engine.rs`

**Purpose**
Detects hook health via heartbeat file and exposes diagnostic summaries to the UI.

---

### [HEALTH] Finding 1: Stale heartbeat is treated as healthy when any session is active

**Severity:** Medium
**Type:** Design flaw
**Location:** `core/hud-core/src/engine.rs:789-795`

**Problem:**
If the heartbeat file is stale but the daemon reports any active session, the hook health check reports `Healthy`. This can mask a real hook failure when a session is stuck in `Working/Waiting` and hooks are no longer firing, delaying detection of the failure.

**Evidence:**
- Stale heartbeat is overridden to `Healthy` when `has_active_daemon_session` returns true. (`core/hud-core/src/engine.rs:789-795`)

**Recommendation:**
Only override stale heartbeat to `Healthy` if there has been recent activity (e.g., last event within a reasonable window) or if the heartbeat age is below a higher tolerance. Otherwise, surface `Stale` so the UI can prompt the user to re-enable hooks.

