# Subsystem Audit: Daemon Reducer + Session State Aggregation

**Files reviewed**
- `core/daemon/src/reducer.rs`
- `core/daemon/src/session_store.rs`
- `core/daemon/src/state.rs`
- `core/daemon/src/activity.rs`

**Purpose**
Applies hook events to session records, handles tombstones, TTL pruning, and emits aggregated project session states for the UI.

---

### [DAEMON-STATE] Finding 1: Active sessions downgrade to Ready after 8s of inactivity

**Severity:** High
**Type:** Bug
**Location:** `core/daemon/src/state.rs:22-26`, `core/daemon/src/state.rs:479-493`, `core/daemon/src/state.rs:263-299`

**Problem:**
`effective_session_state` demotes `Working` and `Waiting` sessions to `Ready` after 8 seconds without a new event. This is used for `project_states_snapshot`, which drives the UI. For normal Claude responses or permission prompts that last longer than 8 seconds, the UI can incorrectly show `Ready` while the session is still working or waiting.

**Evidence:**
- `ACTIVE_STATE_STALE_SECS` is set to 8 seconds. (`core/daemon/src/state.rs:22-26`)
- `effective_session_state` switches `Working/Waiting` to `Ready` after that age. (`core/daemon/src/state.rs:479-493`)
- `project_states_snapshot` uses `effective_session_state` for the aggregated state returned to the app. (`core/daemon/src/state.rs:263-299`)

**Recommendation:**
Remove the 8-second demotion or replace it with a safer heuristic (e.g., only demote after a much longer threshold, or use hook heartbeat freshness to detect actual staleness). If the goal is to prevent stuck states, rely on TTL pruning or explicit hook health diagnostics instead of forcing `Ready` so quickly.

