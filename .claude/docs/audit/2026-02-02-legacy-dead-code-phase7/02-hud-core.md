# Subsystem 2: hud-core State Derivation

### [hud-core] Finding 1: Local staleness rules override daemon state

**Severity:** High
**Type:** Design flaw / legacy logic
**Location:** `core/hud-core/src/sessions.rs:117-157`

**Problem:**
`project_state_from_daemon()` re-interprets daemon state locally, downgrading `Working/Waiting → Ready` after `ACTIVE_STATE_STALE_SECS` and `Ready → Idle` after `STALE_THRESHOLD_SECS`. This conflicts with the daemon’s authoritative TTL policy and updated_at-based staleness (8s Working→Ready, Ready persists until TTL). Any client using hud-core will diverge from the daemon truth, reintroducing the very inconsistency the migration removed.

**Evidence:**
Lines 125-139 apply the local timers on top of the daemon state (`sessions.rs:117-157`). These constants live in `core/hud-core/src/state/types.rs:143-150` and are different from daemon TTLs.

**Recommendation:**
Remove local staleness transitions in `project_state_from_daemon()` and rely entirely on daemon state. If any client still needs local heuristics, move them into the daemon and expose explicit derived fields (or a clearly named “best-effort” client mode).

---

### [hud-core] Finding 2: Staleness constants are stale and inconsistent with daemon

**Severity:** Medium
**Type:** Stale docs / legacy config
**Location:** `core/hud-core/src/state/types.rs:143-150`

**Problem:**
`STALE_THRESHOLD_SECS` (300s) and `ACTIVE_STATE_STALE_SECS` (30s) encode old, file-based logic that is now inconsistent with daemon behavior. Keeping these constants encourages accidental divergence and makes future changes risky.

**Evidence:**
`state/types.rs:143-150` defines the constants, and `sessions.rs:125-139` uses them to override daemon results.

**Recommendation:**
Delete these constants along with the corresponding overrides in `sessions.rs`, or replace them with daemon-configured values exposed via IPC if needed for UI hints.

---

### [hud-core] Finding 3: Activity fallback can resurrect legacy heuristics

**Severity:** Medium
**Type:** Legacy logic
**Location:** `core/hud-core/src/sessions.rs:39-86`

**Problem:**
When no daemon sessions are available, hud-core falls back to `activity_snapshot` and can mark a project as `Working` based solely on recent file activity. This reintroduces a non-authoritative heuristic that may show “working” even when the daemon has no active session, especially if IPC is transiently down or if file activity is unrelated to Claude activity.

**Evidence:**
`project_state_from_activity()` uses daemon activity as a fallback and emits a working state (`sessions.rs:39-86`).

**Recommendation:**
Either remove this fallback or gate it behind an explicit “best-effort/offline” mode so daemon-only clients don’t misreport state.

---

### [hud-core] Finding 4: Dead test references removed `ProcessLivenessSnapshot`

**Severity:** Medium
**Type:** Dead code / test failure
**Location:** `core/hud-core/src/state/daemon.rs:272-287`

**Problem:**
The test `parses_process_liveness_payload` uses `ProcessLivenessSnapshot`, which no longer exists. This will fail under `cargo test` and indicates partial removal of the process-liveness snapshot flow.

**Evidence:**
`core/hud-core/src/state/daemon.rs:283` references `ProcessLivenessSnapshot`, with no definition anywhere in the codebase.

**Recommendation:**
Remove the test (and any unused process-liveness snapshot parsing) or reintroduce the type and actual IPC path if this data is still required.

---

### [hud-core] Finding 5: Hook mapping comment is outdated

**Severity:** Low
**Type:** Stale docs
**Location:** `core/hud-core/src/state/types.rs:152-165`

**Problem:**
The comment states the canonical hook→state mapping is implemented in `core/hud-hook/`. With daemon-only architecture, the authoritative mapping is now in the daemon reducer. This doc can mislead future updates.

**Evidence:**
The mapping comment explicitly points to `core/hud-hook/` while daemon reducer is now the single writer.

**Recommendation:**
Update the comment to reference the daemon reducer as authoritative, or remove the comment if it’s now redundant.
