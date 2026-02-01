# Daemon-Based Architecture Migration Plan (End-to-End)

This document is an **exhaustive, agent-ready plan** to migrate Capacitor's state tracking and activation pipeline from multi-writer JSON files to a **single-writer daemon** with transactional storage. It includes context, invariants, data model, IPC contract, rollout strategy, and detailed implementation steps.

## 0. Why This Migration Exists

### Current Pain (confirmed in audits)

- Multiple processes (hud-hook, hud-core cleanup, Swift UI) **read-modify-write the same JSON files**.
- PID liveness is verified inconsistently across subsystems (cleanup uses PID-only; lock logic uses proc_started).
- State corruption or parse errors could previously result in **silent resets** (e.g., `sessions.json` becomes empty).
- Lock metadata writes are not atomic; crash can leave half-written directories.
- Activity tracking is atomic but **last-writer-wins** under concurrency.

### Target Outcome

- **Single writer** for all state (daemon).
- **Transactional storage** (SQLite/WAL) with replayable event log.
- Hooks + App become clients (IPC), no user-facing daemon command.
- **Daemon-only**: file-based fallback is removed; the daemon is required.

---

## 1. Current System Map (legacy reference)

> **Daemon-only note (2026-02):** The table below describes pre-daemon artifacts.
> In daemon-only mode, these file paths are **legacy** and should not be written/read as authoritative state.

### Primary Artifacts (current)

| Artifact                                         | Writer(s)                                 | Reader(s)                         | Notes                                         |
| ------------------------------------------------ | ----------------------------------------- | --------------------------------- | --------------------------------------------- |
| `~/.capacitor/sessions.json`                     | Legacy | Legacy | Historical snapshot (daemon-only disables writes/reads) |
| `~/.capacitor/sessions/{session_id}-{pid}.lock/` | Legacy | Legacy | Historical locks (daemon-only disables writes/reads) |
| `~/.capacitor/ended-sessions/{session_id}`       | Legacy | Legacy | Historical tombstones (daemon-only disables writes/reads) |
| `~/.capacitor/file-activity.json`                | Legacy | Legacy | Historical activity fallback (daemon-only disables writes/reads) |
| `~/.capacitor/shell-cwd.json`                    | Legacy | Legacy | Historical shell snapshot (daemon-only uses IPC) |
| `~/.capacitor/shell-history.jsonl`               | Legacy | Legacy | Historical shell history (daemon-only uses IPC) |
| `~/.capacitor/hud-hook-heartbeat`                | `hud-hook handle`                         | Setup UI                          | Heartbeat for hook health                     |
| `~/.claude/settings.json`                        | `hud-core setup`                          | Claude                            | Must preserve other settings                  |
| `~/.local/bin/hud-hook`                          | `hud-core setup` / Swift installer        | hooks                             | Symlink required (Gatekeeper)                 |

---


## 2.1 Daemon-only status (current)

- **Daemon is authoritative** for sessions, shell state, activity, and process liveness.
- **File-based artifacts are legacy** and must not be used as source of truth.
- **Hooks/app should error** when daemon is down (no fallback writes/reads).
- **Lock directories are deprecated** and should not be created in daemon-only mode.

## 2. Target Architecture (Daemon-Based)

### Core idea

A **local daemon** is the **only writer** of state. Hooks and the Swift app become **clients** via IPC. The daemon persists to SQLite (WAL) + an append-only event log for replay.

### Responsibilities

- Ingest events from hooks (SessionStart, PostToolUse, ShellCwd, etc.)
- Maintain canonical state (sessions, activity, shell state, tombstones)
- Track PID identity (`proc_started`) centrally via `process_liveness`
- Expose read APIs for the Swift app
- Export JSON snapshots for backwards compatibility (optional during migration)

### Non-Goals

- No change to user CLI workflow (`claude`, `codex`, etc.)
- No new user-facing daemon commands
- No breaking change to hook installation or symlink strategy

---

## 3. Invariants (Must Hold During Migration)

1. **No user command changes**: `claude`, `codex`, hook triggers continue unchanged.
2. **Single writer**: once daemon is enabled, all writes go through it.
3. **No legacy fallback**: if daemon is down, hook/app surface errors; no file-based mode.
4. **Symlink strategy stays**: `~/.local/bin/hud-hook` must remain a symlink.
5. **Exact-path session correctness**: session state is never inferred from parent directories.
6. **Activity is secondary**: activity should never override explicit session state.
7. **Daemon is invisible**: must auto-start and auto-recover without user action.
8. **PID identity is daemon-owned**: process identity should be sourced from `process_liveness`.
9. **Lock deprecation is safe**: when lock creation is disabled, do not delete existing locks.

---

## 4. IPC Contract (Initial Draft)

### Transport

- Unix Domain Socket at `~/.capacitor/daemon.sock`.
- Newline-delimited JSON (one request per line) for phase 1.

### Message Types

**Event Ingest**

- `Event.SessionStart`
- `Event.UserPromptSubmit`
- `Event.PreToolUse`
- `Event.PostToolUse`
- `Event.PermissionRequest`
- `Event.PreCompact`
- `Event.Notification`
- `Event.SessionEnd`
- `Event.Stop`
- `Event.ShellCwd`

**Queries**

- `GetSessions`
- `GetShellState`
- `GetProcessLiveness`
- `GetActivity`
- `GetHealth`

**Response format**

- `{ "ok": true, "data": ... }`
- `{ "ok": false, "error": { "code": "...", "message": "..." } }`

### Versioning

- All messages include `protocol_version`.
- Daemon rejects or downgrades if version mismatch.

---

## 5. Data Model (SQLite)

### Tables

1. `events`
   - id (pk)
   - recorded_at (RFC3339 string)
   - event_type (snake_case string from protocol serialization)
   - session_id
   - pid
   - payload (full `EventEnvelope` JSON)

2. `sessions`
   - session_id
   - pid
   - state
   - cwd
   - updated_at
   - state_changed_at
   - metadata (working_on, project_dir, permission_mode, etc.)

3. `activity`
   - session_id
   - project_path
   - file_path
   - tool
   - timestamp

4. `shell_state`
   - pid
   - cwd
   - tty
   - parent_app
   - tmux_session
   - tmux_client_tty
   - updated_at

5. `process_liveness`
   - pid
   - proc_started
   - last_seen_at

6. `tombstones`
   - session_id
   - created_at
   - expires_at

### Notes

- `session_id + pid` is the **unique key** for sessions.
- Session-level rollups can be computed on query.
- Activity remains bounded by count/time windows per session.
- Phase 3 persists `events` + `shell_state` + session/activity/tombstone rollups; `process_liveness` was pulled forward to support early daemon-side liveness checks.
- Boundary detection for activity attribution now lives in the daemon (no `hud-core` dependency).
- Always derive `event_type` strings using the shared protocol serializer (avoid hardcoding).

---

## 6. Migration Phases

### Current Progress (as of 2026-01-31)

- Done: Swift `DaemonClient` (Unix socket + newline framing + timeout) and daemon-only `ShellStateStore` (no JSON fallback).
- Done: Daemon health UI (debug-only).
- Done: LaunchAgent install + bundled daemon binary install (app startup writes LaunchAgent + kickstarts).
- Done: Default hook commands include `CAPACITOR_DAEMON_ENABLED=1` and `CAPACITOR_DAEMON_LOCK_HEALTH=auto`.
- Done: `process_liveness` pruning on daemon startup (24h max age).
- Done: cleanup uses daemon liveness for lock-holder PID checks (remove PID-only fallback).
- Done: daemon startup backoff to mitigate crash loops.
- Done: orphaned-session cleanup skips when lock mode is read-only/off.
- Done: hud-hook sends events/shell CWD to daemon and **returns errors** when daemon is unavailable (no file writes).
- Remaining highest-leverage: remove any lingering legacy lock-holder cleanup references once safe.

### Recent Learnings / Observations

- Daemon-only enforcement is now live in hooks and shell CWD: when daemon is unavailable, they return errors (no file fallback).
- File-based readers are being removed; daemon is now the sole source of truth for project status and shell state.
- Daemon health UI is debug-only; release builds should not surface daemon status.
- File-based startup cleanup has been stripped down to only kill orphaned lock-holders (no sessions/activity/tombstone cleanup).
- Hook and shell CWD legacy write paths have been deleted; tests tied to JSON/lock/tombstone files were removed accordingly.
- Removed legacy JSON/storage helpers (`ActivityStore`, `StateStore`, resolver, `state_check` bin) and daemonized agent/session detection.
- Claude agent detection now prefers daemon session snapshots; when daemon is enabled, adapter mtime caching is effectively disabled to avoid stale file reads. If this becomes too chatty, add a daemon snapshot generation/etag for caching.
- Daemon session snapshots currently omit some optional metadata (e.g., `working_on`, `permission_mode`, `project_dir`). Either extend the protocol or accept reduced detail in agent lists during daemon-first operation.
- Staleness gating for Ready sessions now depends on daemon-provided `state_changed_at` + optional `is_alive`. Ensure the daemon always emits RFC3339 timestamps for these fields.
- Remaining cleanup work: purge any lingering lock-holder cleanup references once all legacy processes are gone.
- Swift UniFFI bindings were regenerated after daemon-only doc cleanup to keep Bridge comments in sync.
- Dev tooling now prefers the repo-built `hud-hook` binary (avoids silently pointing to the installed app during daemon migration).
- App session state no longer falls back to `hud-core` (daemon disabled clears session state instead of reading JSON).

### Phase 0 — Design & Spec (1–2 days)

- Write a short spec for IPC, data model, and daemon-only behavior.
- Confirm JSON snapshots are removed entirely.
- Confirm launchd strategy (LaunchAgent + auto-restart).

### Phase 1 — Daemon MVP (2–4 days)

- Create new crate `core/daemon`.
- Add shared protocol crate `core/daemon-protocol` to prevent schema drift.
- Implement IPC server + in-memory state (shell CWD first).
- Implement `get_health` + `get_shell_state`.
- Add logging to `~/.capacitor/daemon.log` (or tracing defaults during dev).

### Phase 2 — Hook Client (3–5 days)

- Add a small IPC client to `hud-hook`.
- On event: send to daemon; on failure, **return an error** (no file-based writes).
- Add env flag `CAPACITOR_DAEMON_ENABLED=1` (now normalized into hook commands).
- Allow socket override via `CAPACITOR_DAEMON_SOCKET`.

### Phase 3 — App Client + SQLite Persistence (4–7 days)

- Add `DaemonClient` in Swift (Unix socket, newline framing, timeout/size limits). (Done)
- App reads daemon state only (no JSON fallback). (Done)
- Wire first read path to daemon (`ShellStateStore` → `get_shell_state`). (Done)
- Surface daemon status in Setup/Diagnostics UI. (Done)
- Replace in-memory state with SQLite WAL. (Done; sessions/activity/tombstones persisted, shell_state cached)
- Append to `events` table for replay. (Done)
- Rebuild state on startup if cache tables empty/corrupt. (Done)
- Add replay integration test (event log → rebuilt state). (Done)
- Add IPC read endpoints for sessions/activity/tombstones. (Done)
- Extend IPC smoke test to cover sessions/activity/tombstones. (Done)
- App session state now merges daemon session snapshots into the UI (project_path-based). (Done; lock liveness still heuristic)
- Done: audited file-based readers (sessions.json, file-activity.json, shell-cwd.json) and removed JSON fallbacks from the app and session detection.

### Phase 4 — Liveness + Locks Simplification (2–4 days)

- Centralize PID+proc_started logic in daemon. (Done; daemon process_liveness + daemon-aware checks)
- Remove lock directories entirely (daemon-only, no compatibility shim). (Done)
- Add `process_liveness` table and update per incoming event. (Done)
- Expose `get_process_liveness` query for daemon-first PID identity checks. (Done on daemon + hud-core client)
- Route `hud-core` cleanup checks through daemon liveness only. (Done; local fallback removed)
- Remove lock-holder PID checks entirely; daemon-only builds no longer spawn lock-holders. (Done)
- Rebuild `process_liveness` from event log on daemon startup if table is empty. (Done)
- Prune `process_liveness` rows older than 24 hours on daemon startup. (Done)
- Lock-mode/lock-health toggles removed (daemon-only; no compatibility).

### Phase 5 — Launchd + Reliability (2–4 days)

- Add LaunchAgent (auto-start + auto-restart). (Done)
- Add health checks; daemon required when down. (Done: app probes health; crash-loop policy improved with backoff snapshot.)
- Add crash loop backoff.
- Install LaunchAgent from the app at startup (label `com.capacitor.daemon`). (Done)
- Default hook commands enable daemon routing (`CAPACITOR_DAEMON_ENABLED=1`). (Done)

### Phase 6 — Cleanup & Removal (1–3 days)

- Remove file-based writes from hooks. (Done)
- Remove JSON-based cleanup logic. (Done; startup cleanup only scans for legacy lock-holders)
- Remove remaining file-based state helpers (ActivityStore/StateStore/resolver + tests + state_check bin). (Done)
- Do not keep JSON snapshots.
### Phase 7 — Robustness & Policy (2–5 days)

Goal: eliminate the remaining **signal-quality** brittleness by making session lifecycle,
aggregation, and UI cadence explicit and deterministic.

**7.1 Session TTL / expiry (daemon-side)**
- Add `last_event_at` (or reuse `updated_at`) to enforce a **session expiry policy**.
- Policy proposal:
  - If no event for **N minutes**, transition to `Idle` or drop the session.
  - If `is_alive == false`, drop session immediately.
  - If `is_alive == nil` (unknown), keep until TTL then drop.
- Persist TTL decisions in `sessions` and/or keep in-memory with periodic prune.

**7.2 Project-level aggregation (daemon-side)**
- Add a daemon query that returns **project-level state**, not raw sessions.
- Aggregation rule: **Working > Waiting > Compacting > Ready > Idle** (max severity).
- Include `latest_activity_at` for tie-breaking and UI “most recent” ordering.
- Swift app reads **aggregated project states** only (no local aggregation).

**7.3 Explicit session heartbeat (optional, but strongly recommended)**
- If hooks can emit periodic “heartbeat” events, TTL decisions become reliable.
- If heartbeat is not feasible, TTL is still required to avoid stuck Ready/Working states.

**7.4 UI refresh contract**
- Standardize the UI polling interval (e.g., every 2–3s with backoff on failure).
- Remove any client-side heuristics that reinterpret session state.

**7.5 Diagnostics + debug tooling**
- Add a daemon “policy snapshot” endpoint (optional) so the UI/debug panel can show TTL/aggregation decisions.
- Add tests for TTL expiry and aggregation order to prevent regressions.

---

## 7. Implementation Checklist (Detailed)

### Repository changes

- Add `core/daemon/` crate
- Add `core/daemon-protocol/` shared IPC schema crate
- Update workspace `Cargo.toml`
- Add logging config for daemon (tracing)
- Add SQLite dependency (rusqlite or sqlx)
- Add process inspection dependency (sysinfo) for `proc_started`
- Bundle `capacitor-daemon` into the app and install it to `~/.local/bin` via symlink.
- Add daemon-local project boundary detector (to avoid `hud-core` dependency). (Done)

### Hook changes

- Add IPC client (connect to `~/.capacitor/daemon.sock`)
- Feature flag guard (`CAPACITOR_DAEMON_ENABLED`)
- Socket override (`CAPACITOR_DAEMON_SOCKET`)
- Return errors on IPC failure (no file fallback)
- Use daemon-only liveness checks (local fallback removed)
- Drop lock-mode/lock-health toggles (daemon-only; no compatibility).
- Normalize hook commands to include `CAPACITOR_DAEMON_ENABLED=1` for daemon-first routing.

### HUD core changes

- Add daemon liveness client (`get_process_liveness`) behind `CAPACITOR_DAEMON_ENABLED`
- Route cleanup liveness checks through daemon only
- Remove lock-mode/lock-health toggles (daemon-only; no compatibility support)
- Move agent adapters (Claude) to daemon-first session snapshots; ensure metadata parity if needed

### Swift changes

- Add `DaemonClient.swift` (socket client + response framing)
- Integrate in `ShellStateStore` (daemon-only)
- Add UI status indicator for daemon health
- Install LaunchAgent + bundled daemon binary from the app (auto-start).

### Docs

- Update system map, side-effects map, and gotchas (system map + side-effects map updated)
- Add daemon install/health notes (added to development workflows)

---

## 8. Testing Plan

### Unit Tests

- Daemon event parsing
- State transitions per event type
- SQLite persistence + replay
- Event log → `shell_state` rebuild (tempfile-backed integration test)
- Process liveness upsert (pid, proc_started, last_seen_at)
- Event log → `process_liveness` rebuild (tempfile-backed integration test)
- IPC smoke test: `GetHealth` + `Event` + `GetProcessLiveness`
- IPC smoke test: `GetSessions` + `GetActivity` + `GetTombstones` (now validates full lifecycle)
- Hook daemon-down: error surfaced (no file writes)
- Cleanup daemon-down: error surfaced (no local cleanup)

### Integration Tests

- `hud-hook` -> daemon -> query
- Daemon down -> error surfaced (no fallback)
- Daemon restart with replay
- Cleanup uses daemon liveness only; legacy lock-holder processes should be gone

### Regression Tests

- Activation matrix (Swift)
- Hook health + heartbeat logic
- Multi-shell same session_id handling

### Practical Smoke Checklist (Manual)

1. Start the daemon locally:
   - `cargo run -p capacitor-daemon`
   - Alternatively, verify LaunchAgent is loaded: `launchctl print gui/$(id -u)/com.capacitor.daemon`
2. Verify health via the socket:
   - Send `{"protocol_version":1,"method":"get_health","id":"health","params":null}` to `~/.capacitor/daemon.sock`
   - Expect `{ "status": "ok", ... }`
3. Emit an event and verify liveness:
   - Send `Event.SessionStart` with your PID.
   - Call `GetProcessLiveness` for that PID.
   - Expect `found=true` and `identity_matches=true`.
4. Verify daemon-down behavior:
   - Stop the daemon.
   - Run a hook event (e.g., `SessionStart`) and confirm the hook returns an error.
5. Verify lock deprecation:
   - Confirm lock directories are no longer created by hooks.

**Manual run (2026-01-31):**
- LaunchAgent installed and running (`launchctl print gui/$(id -u)/com.capacitor.daemon` shows running).
- Daemon socket responds to `get_health` with `status: ok`.
- Offline banner appears after bootout; Retry restores daemon.
- Banner clears ~5 seconds after Retry.

---

## 9. Rollout Strategy

- **Alpha**: daemon auto-start when app launches; hooks set `CAPACITOR_DAEMON_ENABLED=1`; daemon required
- **Beta**: daemon required everywhere
- **Stable**: daemon required everywhere

---

## 10. Definition of Done

- Daemon receives all hook events in prod builds
- App reads state from daemon only
- SQLite WAL persistence with replay is stable
- All prior audit issues (JSON race, PID reuse, silent wipe) are eliminated
- Launchd auto-start is reliable and documented
- **Session TTL policy enforced** (no stuck Working/Ready)
- **Project-level aggregation** used by the app (no UI-side aggregation)
- **UI refresh contract** standardized and documented

---

## 11. Open Questions

- (Removed) JSON snapshots are not part of the daemon-only plan.
- Should daemon export metrics (Prometheus-style) or just logs?
- How should event schema evolve without breaking old hooks?
- Do we need any legacy disk seeding now that replay from the event log restores shell state?
- `process_liveness` rows are pruned after 24 hours; revisit if telemetry shows stale entries matter.
- Do we need an in-app toggle for daemon enablement (GUI apps don’t inherit shell env vars)?

---

## 12. Quick Start for Agents

1. Create `core/daemon` with minimal IPC loop.
2. Implement `GetHealth` and `Event.SessionStart`.
3. Add IPC client in `hud-hook` (daemon-only, no fallback).
4. Add Swift daemon client and read integration.
5. Enable via `CAPACITOR_DAEMON_ENABLED=1` (or run the app to install LaunchAgent).

---

This plan is intended to be authoritative for migration work. Any deviation should update this document to keep agent context aligned.
