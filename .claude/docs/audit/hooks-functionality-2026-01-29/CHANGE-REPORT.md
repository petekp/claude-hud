# Hooks Functionality Audit — Change Report

> **Daemon-only note (2026-02):** This audit describes pre-daemon file/lock behavior. In daemon-only mode, these paths are legacy and should not be authoritative.
**Date:** 2026-01-29
**Scope:** Remediation for findings in hooks functionality audit.

## What Changed (Summary)

1. **Heartbeat accuracy:** `hud-hook` now updates the heartbeat only after parsing a valid hook event, preventing false positives caused by binary verification.
2. **Hook test safety:** `run_hook_test()` writes an isolated sessions-format file in `~/.capacitor/` rather than modifying live `sessions.json`. It also verifies `sessions.json` is writable when it exists.
3. **PID reuse lock refresh:** `create_session_lock()` now validates `proc_started` even when PID matches and refreshes stale locks if the PID was reused.
4. **Activity format consolidation:** `hud-hook` now writes native `activity` entries (with `project_path`), migrating legacy `files` arrays on write; legacy relative paths resolve against the session CWD; `ActivityStore::load()` remains backward compatible.
5. **Test coverage:** Added tests for tombstone/heartbeat gating, activity migration merge/dedupe + absolute-path handling, lock selection and live takeover, and safe state-file health checks. Lock tests now skip gracefully if process start time is unavailable.
6. **Documentation updates:** Multiple docs and audits updated to remove inaccuracies and reflect the new behavior.

## Detailed Changes

### 1) Heartbeat accuracy

- **Problem:** `verify_hook_binary()` invoked `hud-hook handle`, which touched the heartbeat before parsing input, causing false-positive health.
- **Fix:** Move `touch_heartbeat()` to after event parsing so only real hook events update heartbeat.
- **Files:**
  - `core/hud-hook/src/handle.rs`
  - `core/hud-core/src/engine.rs` (docstring update)
  - `.claude/docs/side-effects-map.md`
  - `.claude/docs/audit/00-current-system-map.md`
  - `.claude/docs/audit/14-recovery-safety-net.md`
  - `.claude/docs/audit/hooks-functionality-2026-01-29/04-hook-health-diagnostics.md`
  - `.claude/docs/audit/12-hud-hook-system.md`

### 2) Hook test I/O safety

- **Problem:** `run_hook_test()` performed read–modify–write on `sessions.json`, risking clobber of concurrent hook updates.
- **Fix:** Use an isolated test file in the storage root; validate that the live state file is readable, but never write to it.
- **Addendum:** If `sessions.json` exists, verify it is writable to avoid false-positive health checks on read-only files.
- **Files:**
  - `core/hud-core/src/engine.rs`
  - `.claude/docs/audit/hooks-functionality-2026-01-29/04-hook-health-diagnostics.md`
  - `.claude/docs/audit/14-recovery-safety-net.md`

### 3) PID reuse lock refresh

- **Problem:** If a stale `{session_id}-{pid}.lock` remained and the PID was reused, `create_session_lock()` returned early without checking `proc_started`, leaving no valid lock for the new process.
- **Fix:** Validate `proc_started` even when PID matches; refresh lock metadata if mismatch is detected.
- **Files:**
  - `core/hud-core/src/state/lock.rs`
  - `.claude/docs/audit/hooks-functionality-2026-01-29/02-lock-lifecycle.md`

### 4) Activity format consolidation

- **Problem:** `hud-hook` wrote legacy `files[]` entries; `ActivityStore` converted on every load.
- **Fix:** Hook now writes native `activity[]` entries with `project_path`; migrates legacy `files` arrays on write. Legacy relative paths are resolved against the session CWD before boundary detection. `ActivityStore::load()` remains backward compatible.
- **Files:**
  - `core/hud-hook/src/handle.rs`
  - `core/hud-core/src/activity.rs` (doc header)
  - `.claude/docs/side-effects-map.md`
  - `.claude/docs/gotchas.md`
  - `.claude/docs/audit/09-activity-files.md`
  - `.claude/docs/audit/hooks-functionality-2026-01-29/05-activity-pipeline.md`
  - `.claude/docs/audit/12-hud-hook-system.md`
  - `.claude/docs/audit/00-current-system-map.md`

### 5) Documentation alignment

- **What:** Updated audit artifacts to reflect fixes and clarify remaining low‑risk TOCTOU in settings.json.
- **Files:**
  - `.claude/docs/audit/hooks-functionality-2026-01-29/SUMMARY.md`
  - `.claude/docs/audit/hooks-functionality-2026-01-29/03-hook-configuration.md`
  - `.claude/docs/audit/hooks-functionality-2026-01-29/04-hook-health-diagnostics.md`
  - `.claude/docs/audit/hooks-functionality-2026-01-29/05-activity-pipeline.md`

### 6) Test coverage improvements

- **What:** Added unit tests for heartbeat/tombstone skip behavior, legacy activity merge/dedupe + absolute path migration, lock selection among concurrent sessions, lock takeover handoff, and safe health-check I/O. Lock tests skip when process start time is unavailable to avoid CI flakiness.
- **Files:**
  - `core/hud-hook/src/handle.rs`
  - `core/hud-core/src/state/lock.rs`
  - `core/hud-core/src/engine.rs`

## Tests Run

```
cargo test -p hud-core create_session_lock
cargo check -p hud-hook
cargo test -p hud-hook record_file_activity
cargo test -p hud-core lock
cargo test -p hud-hook handle
cargo test -p hud-core test_state_file_io_does_not_modify_live_sessions_file
```

## Residual Risks / Deferred Items

- **Settings.json TOCTOU:** Still a low‑risk edge case; no locking added. Documented in audit and gotchas.
