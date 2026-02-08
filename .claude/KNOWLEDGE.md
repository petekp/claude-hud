# Knowledge Manifest
<!-- Auto-generated. Source: .claude/docs/*, .claude/plans/*, CLAUDE.md, docs/* -->

## Task Context Map

| Context | Load | Search |
|---|---|---|
| Daemon IPC / state tracking | docs/daemon-ipc.md, .claude/docs/architecture-overview.md, .claude/compiled/daemon.md | daemon.sock, get_sessions, get_shell_state |
| Hook behavior / install | core/hud-hook/, .claude/docs/development-workflows.md, .claude/compiled/hooks.md | hud-hook, sync-hooks, hook events |
| Swift UI + app state | apps/swift/, .claude/docs/architecture-overview.md, .claude/compiled/rules.md | AppState, HudEngine, SwiftUI |
| UniFFI bindings | CLAUDE.md, .claude/docs/development-workflows.md | uniffi-bindgen, hud_core.swift |
| Terminal activation | .claude/docs/terminal-switching-matrix.md, .claude/docs/terminal-activation-test-matrix.md, .claude/compiled/terminal.md | tmux, Ghostty, Warp |
| Debugging / telemetry hub | .claude/docs/debugging-guide.md, docs/transparent-ui/README.md | agent-briefing, telemetry-stream, activation-trace |
| Debugging / daemon health | .claude/docs/debugging-guide.md, .claude/compiled/debugging.md | daemon stderr, get_health |
| Side effects / storage | .claude/compiled/side-effects.md | state.db, daemon.sock |
| Session UI state | .claude/compiled/ui-state.md | Working, Ready, Idle |
| Migration / invariants | docs/architecture-decisions/005-daemon-based-state-service.md, .claude/docs/architecture-deep-dive.md, .claude/compiled/migration.md | daemon-only, lock deprecation |

## Always-Loaded Facts

### Commands
| Action | Command |
|---|---|
| Restart app (dev) | `./scripts/dev/restart-app.sh` |
| Build Rust core | `cargo build -p hud-core --release` |
| Swift build/run | `cd apps/swift && swift build && swift run` |
| Daemon health | `printf '{"protocol_version":1,"method":"get_health","id":"health","params":null}\n' | nc -U ~/.capacitor/daemon.sock` |
| Telemetry hub | `./scripts/run-transparent-ui.sh` |
| Regen UniFFI | `cargo run --bin uniffi-bindgen generate --library target/release/libhud_core.dylib --language swift --out-dir apps/swift/bindings && cp apps/swift/bindings/hud_core.swift apps/swift/Sources/Capacitor/Bridge/` |

### Paths
| Purpose | Path |
|---|---|
| Daemon socket | `~/.capacitor/daemon.sock` |
| Daemon logs | `~/.capacitor/daemon/daemon.stderr.log` |
| Hook binary | `~/.local/bin/hud-hook` (symlink) |
| Telemetry hub | `docs/transparent-ui/` + `scripts/transparent-ui-server.mjs` |
| Rust core | `core/hud-core/` |
| Swift app | `apps/swift/Sources/Capacitor/` |

### Critical Rules
- Daemon-only: no file fallbacks for session/shell state.
- Hook binary must be a symlink; copies can be Gatekeeper-killed.
- Use `_Concurrency.Task` in Swift files that import UniFFI.
- Run `cargo fmt` before commits; CI enforces formatting.
- Ghostty/Warp can’t focus specific windows—treat as best-effort.

## Chunk Index

| Topic | Location | Summary |
|---|---|---|
| Daemon IPC | .claude/compiled/daemon.md | Protocol, endpoints, example requests |
| Build + UniFFI | .claude/compiled/workflows.md | Build, run, regen, health checks |
| Critical rules | .claude/compiled/rules.md | Hard constraints + invariants |
| Terminal behavior | .claude/compiled/terminal.md | tmux/terminal limits + test matrix |
| Debugging | .claude/compiled/debugging.md | Health checks, state snapshots |
| Side effects | .claude/compiled/side-effects.md | Authoritative writes + legacy |
| Migration | .claude/compiled/migration.md | Invariants + status |
| UI state | .claude/compiled/ui-state.md | Session state rules |
| Hooks | .claude/compiled/hooks.md | Install + events |
