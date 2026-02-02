# Hooks Functionality Audit Plan

> **Daemon-only note (2026-02):** This audit describes pre-daemon file/lock behavior. In daemon-only mode, these paths are legacy and should not be authoritative.
**Date:** 2026-01-29
**Scope:** Claude Code hook ingestion, lock lifecycle, hook configuration/installation, hook health diagnostics/testing, activity pipeline, and shell CWD tracking.

**Files in scope (primary):**
- `core/hud-hook/src/main.rs`
- `core/hud-hook/src/handle.rs`
- `core/hud-hook/src/lock_holder.rs`
- `core/hud-hook/src/cwd.rs`
- `core/hud-hook/src/logging.rs`
- `core/hud-core/src/setup.rs`
- `core/hud-core/src/engine.rs`
- `core/hud-core/src/state/lock.rs`
- `core/hud-core/src/state/store.rs`
- `core/hud-core/src/state/types.rs`
- `core/hud-core/src/activity.rs`
- `scripts/sync-hooks.sh`

---

## Pre-analysis Sweep

- **Docs reviewed:** `CLAUDE.md`, `README.md` (hooks setup), `.claude/docs/gotchas.md`, `.claude/docs/side-effects-map.md`.
- **Existing audits referenced:** `.claude/docs/audit/10-hook-configuration.md`, `.claude/docs/audit/12-hud-hook-system.md`.
- **TODO/FIXME/HACK scan:** No hook-related TODOs found (only unrelated ones in validation/bindings).
- **Recent commits:** Last 20 commits include UI/features; no recent hook code changes in that window.
- **Issue tracker:** Not accessible in this environment.

---

## Subsystem Decomposition

| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Hook event ingestion & session state updates | `core/hud-hook/src/handle.rs`, `core/hud-core/src/state/store.rs`, `core/hud-core/src/state/types.rs` | FS: `~/.capacitor/sessions.json`, `~/.capacitor/ended-sessions/*`, `~/.capacitor/hud-hook-heartbeat`, `~/.capacitor/file-activity.json`; spawns lock-holder | High |
| 2 | Lock lifecycle & liveness verification | `core/hud-core/src/state/lock.rs`, `core/hud-hook/src/lock_holder.rs` | FS: `~/.capacitor/sessions/*.lock/`; process liveness checks | High |
| 3 | Hook configuration & binary management | `core/hud-core/src/setup.rs`, `scripts/sync-hooks.sh` | FS: `~/.claude/settings.json`, `~/.local/bin/hud-hook` (symlink) | High |
| 4 | Hook health diagnostics & tests | `core/hud-core/src/engine.rs`, `core/hud-core/src/types.rs`, `core/hud-core/src/setup.rs` | FS: heartbeat read, sessions.json read/write | Medium |
| 5 | Activity file pipeline | `core/hud-hook/src/handle.rs`, `core/hud-core/src/activity.rs` | FS: `~/.capacitor/file-activity.json` | Medium |
| 6 | Shell CWD hook | `core/hud-hook/src/cwd.rs` | FS: `~/.capacitor/shell-cwd.json`, `~/.capacitor/shell-history.jsonl` | Medium |

---

## Methodology

- Read every line in the hook pipeline and dependent state/lock modules.
- Verify state machine transitions against docs and staleness rules.
- Check atomicity and concurrency behavior for file writes.
- Inspect error handling and cleanup paths for stale state.
- Record findings with severity, type, evidence, and recommendations.

