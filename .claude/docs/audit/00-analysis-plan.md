# Hook System Audit Plan (Session State Detection)

## Scope
Audit the hook-driven session state detection pipeline that feeds Capacitor's UI:

Claude Code hooks → `hud-hook` CLI → daemon IPC → reducer/store → `hud-core` session detection → UI/health diagnostics.

## Known Issues Sweep (Initial)
- CLAUDE.md highlights "daemon-first" session state (no file-based fallback) and "hook symlink, not copy" (Gatekeeper SIGKILL) as operational gotchas.
- README documents hook config and emphasizes SessionEnd must be synchronous.
- No hook-specific TODO/FIXME/HACK found in relevant code paths.
- Recent commits include "Update daemon-first docs" and "Fix terminal activation fallbacks" (potentially adjacent but not hook pipeline).

## Subsystem Map
| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Hook Config + Install | `core/hud-core/src/setup.rs` | FS: read/write `~/.claude/settings.json`, verify binary | High |
| 2 | Hook Ingestion (CLI) | `core/hud-hook/src/main.rs`, `handle.rs`, `cwd.rs`, `daemon_client.rs` | stdin read, heartbeat write, IPC | High |
| 3 | Event Types + Mapping | `core/hud-core/src/state/types.rs` | none | High |
| 4 | Daemon Reducer + Store | `core/daemon/src/reducer.rs`, `session_store.rs`, `activity.rs`, `replay.rs` | DB: read/write | High |
| 5 | Session Detection API | `core/hud-core/src/sessions.rs`, `core/hud-core/src/agents/*` | DB: read via daemon IPC | High |
| 6 | Health + Diagnostics | `core/hud-core/src/engine.rs`, `core/hud-core/src/types.rs` | FS: heartbeat mtime | Medium |
| 7 | Swift Session Consumers | `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift`, `apps/swift/Sources/Capacitor/Models/ActiveProjectResolver.swift` | UI state updates | Medium |
| 8 | Swift FFI Surface | `apps/swift/Sources/Capacitor/Bridge/hud_core.swift` | none (bindings) | Low |
| 9 | Targeted Tests | `apps/swift/Tests/CapacitorTests/*`, `core/daemon/src/state.rs` | none | Medium |

## Methodology
- Read each subsystem end-to-end.
- Apply stateful/concurrency/validation checklists where relevant.
- Record findings with severity, evidence, and recommendations.
