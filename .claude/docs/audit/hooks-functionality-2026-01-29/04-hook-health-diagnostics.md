# Subsystem 4: Hook Health Diagnostics & Tests

> **Daemon-only note (2026-02):** This audit describes pre-daemon file/lock behavior. In daemon-only mode, these paths are legacy and should not be authoritative.
**Files analyzed:**
- `core/hud-core/src/engine.rs`
- `core/hud-core/src/setup.rs`
- `core/hud-core/src/state/store.rs`
- `core/hud-hook/src/handle.rs`

## Summary

Hook health is inferred from the heartbeat file `~/.capacitor/hud-hook-heartbeat`, which the hook binary touches on every valid, actionable hook event (after parsing + session_id/tombstone checks). Diagnostics combine setup status (binary + config) with health (heartbeat). The “Test Hooks” button validates heartbeat freshness and state file I/O.

## Findings

### [HEALTH] Finding 1: Hook Health Can Report False Positives After Binary Verification

**Severity:** High
**Type:** Bug (incorrect diagnostics)
**Location:**
- `core/hud-core/src/setup.rs:333-347`
- `core/hud-hook/src/handle.rs:48-49` and `core/hud-hook/src/handle.rs:406-427`
- `core/hud-core/src/engine.rs:756-784`

**Problem:**
`verify_hook_binary()` runs `hud-hook handle` with empty JSON to check executability. `hud-hook` touches the heartbeat file **before** reading input. This means any setup check or install flow refreshes the heartbeat even when no real hook events have fired. As a result, `check_hook_health()` (and therefore `get_hook_diagnostic()` and `run_hook_test()`) can falsely report that hooks are firing.

**Evidence:**
- `verify_hook_binary` launches `hud-hook handle` and writes `{}` to stdin.
- (Pre-fix) `handle::run()` called `touch_heartbeat()` before parsing input or validating the event.
- `check_hook_health()` trusts heartbeat freshness as the signal.

**Recommendation:**
Add a “no-heartbeat” mode for verification (e.g., env var like `HUD_HOOK_VERIFY=1` that skips `touch_heartbeat()`), or run a different subcommand for verification. Ensure diagnostics only count heartbeats from real hook events.

### [HEALTH] Finding 2: Hook Test Can Clobber Concurrent Session Updates

**Severity:** Medium
**Type:** Race condition
**Location:**
- `core/hud-core/src/engine.rs:1001-1042`
- `core/hud-core/src/state/store.rs:126-153`

**Problem:**
`test_state_file_io()` loads `sessions.json`, inserts a test record, and saves the entire file. If hooks are firing concurrently, their writes can be lost because this save overwrites the file with the stale snapshot plus the test record. Cleanup repeats the same pattern.

**Evidence:**
- `StateStore::save()` always writes the full `sessions` map to disk.
- The test performs a read–modify–write cycle with no locking or merge.

**Recommendation:**
Avoid writing to the live state file when hooks may be active. Options:
- Use a separate test file under `~/.capacitor/` for the I/O check.
- Or add file locking / optimistic retry logic (load → save only if file unchanged).

---

## Update (2026-01-29)

- Heartbeat now updates only after a valid hook event is parsed, so `verify_hook_binary()` no longer refreshes it.
- `run_hook_test()` now uses an isolated test file in the storage directory, avoiding writes to `sessions.json`.
