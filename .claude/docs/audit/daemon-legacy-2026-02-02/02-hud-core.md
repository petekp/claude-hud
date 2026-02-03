# Subsystem 02: Hud Core State/Activation

## Findings

### [HUD-CORE] Finding 1: Legacy lock-holder cleanup still runs in daemon-only mode

**Severity:** Medium
**Type:** Dead code
**Location:** `core/hud-core/src/state/cleanup.rs:1-80`

**Problem:**
`cleanup_orphaned_lock_holders()` enumerates processes and SIGTERMs any legacy `hud-hook lock-holder` processes whose monitored PID is dead. With “no back-compat/legacy support,” this cleanup path should no longer be necessary and still performs process-level side effects.

**Evidence:**
The cleanup function explicitly searches for `hud-hook lock-holder` processes and kills them (`core/hud-core/src/state/cleanup.rs:13-75`).

**Recommendation:**
Remove the legacy lock-holder cleanup or gate it behind a one-time migration flag. In daemon-only mode, startup cleanup should be daemon-focused only.

---

### [HUD-CORE] Finding 2: CleanupStats exposes legacy counters that are never set

**Severity:** Medium
**Type:** Stale docs
**Location:** `core/hud-core/src/state/cleanup.rs:113-142`

**Problem:**
`CleanupStats` includes counters for lock/tombstone/activity/session cleanup, but `run_startup_cleanup()` only populates `orphaned_processes_killed`. The other fields are always zero and imply cleanup work that no longer exists.

**Evidence:**
- Struct fields include `locks_removed`, `legacy_locks_removed`, `tombstones_removed`, etc. (`core/hud-core/src/state/cleanup.rs:113-129`).
- `run_startup_cleanup()` only sets `orphaned_processes_killed` (`core/hud-core/src/state/cleanup.rs:137-141`).

**Recommendation:**
Remove the unused fields or rework cleanup to return a daemon-centric stats struct. Update Swift logging accordingly.

---

### [HUD-CORE] Finding 3: `normalize_path_for_hashing` is unused and lock-specific

**Severity:** Low
**Type:** Dead code
**Location:** `core/hud-core/src/state/path_utils.rs:53-59`

**Problem:**
`normalize_path_for_hashing` is exported but has no in-repo call sites and is still described as lock-hashing support, which is no longer relevant in daemon-only mode.

**Evidence:**
Function definition and lock-specific doc comment (`core/hud-core/src/state/path_utils.rs:53-59`); no call sites in the repo.

**Recommendation:**
Remove the function or rename/re-document if it remains part of a public API.

---

### [HUD-CORE] Finding 4: Lock-based state docs are stale after daemon-only migration

**Severity:** Low
**Type:** Stale docs
**Location:** `core/hud-core/src/state/types.rs:143-157`, `core/hud-core/src/engine.rs:130-132`

**Problem:**
Docs still claim that hooks create locks and that `add_project` reconciles orphaned locks. In daemon-only mode, these statements are no longer accurate.

**Evidence:**
- Hook→state mapping claims “creates lock” (`core/hud-core/src/state/types.rs:155-157`).
- `add_project` doc mentions “reconciles any orphaned locks” (`core/hud-core/src/engine.rs:130-132`).

**Recommendation:**
Update these comments to describe daemon liveness and remove lock-based wording.

---

### [HUD-CORE] Finding 5: Activation docs still reference `shell-cwd.json`

**Severity:** Low
**Type:** Stale docs
**Location:** `core/hud-core/src/activation.rs:15-42`

**Problem:**
Activation docs say Swift “reads shell-cwd.json,” but the app now fetches shell state from the daemon. The JSON shape is compatible, but the file itself is deprecated.

**Evidence:**
Module doc and `ShellCwdStateFfi` comment (`core/hud-core/src/activation.rs:15-42`).

**Recommendation:**
Update docs to state that shell state comes from daemon IPC (with legacy JSON shape).

