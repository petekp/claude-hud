# Capacitor

Native macOS dashboard for Claude Code—displays project statistics, session states, and helps you context-switch between projects instantly.

## Stack

- **Platform** — Apple Silicon, macOS 14+
- **Swift App** (`apps/swift/`) — SwiftUI, 120Hz ProMotion
- **Rust Core** (`core/hud-core/`) — Business logic via UniFFI bindings

## Commands

```bash
# Quick iteration (most common)
./scripts/dev/restart-app.sh              # Rebuild Rust + Swift, relaunch debug bundle
./scripts/dev/restart-app.sh --channel alpha  # Launch with runtime alpha gating

# Rust (when changing core/)
cargo fmt                         # Format (required before commits)
cargo clippy -- -D warnings       # Lint
cargo test                        # Test

# Full rebuild (after Rust changes)
cargo build -p hud-core --release && cd apps/swift && swift build
# If using swift run directly (no bundle/Info.plist), set channel explicitly:
CAPACITOR_CHANNEL=dev swift run
```

**First-time setup:** `./scripts/dev/setup.sh`

## Structure

```
capacitor/
├── core/hud-core/src/      # Rust: engine.rs, sessions.rs, projects.rs, ideas.rs
├── core/hud-hook/src/      # Rust: CLI hook handler (handle.rs, cwd.rs)
├── apps/swift/Sources/     # Swift: App.swift, Models/, Views/ (Footer/, Projects/, Navigation/)
└── .claude/docs/           # Architecture docs, feature specs
```

## Core Principle: Sidecar Architecture

**Capacitor observes Claude Code—it doesn't replace it.**

- Read from `~/.claude/` — transcripts, config (Claude's namespace)
- Write to `~/.capacitor/` — session state, shell tracking (our namespace)
- Never call Anthropic API directly — invoke `claude` CLI instead

## Key Files

| Purpose | Location |
|---------|----------|
| HudEngine facade | `core/hud-core/src/engine.rs` |
| Session state | `core/hud-core/src/sessions.rs` |
| Hook event config | `core/hud-core/src/setup.rs` |
| Shell CWD tracking | `core/hud-hook/src/cwd.rs` |
| Terminal activation | `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` |
| UniFFI bindings | `apps/swift/Sources/Capacitor/Bridge/hud_core.swift` |

## State Tracking

Hooks → **daemon** → Capacitor reads daemon snapshots only

- **Daemon socket:** `~/.capacitor/daemon.sock`
- **Daemon storage/logs:** `~/.capacitor/daemon/`
- **Hook binary:** `~/.local/bin/hud-hook`

**Resolution:** daemon sessions and shell state are authoritative (no file-based fallback).

## Telemetry + Transparent UI

Use the local telemetry hub when debugging runtime behavior or feeding context to coding agents.

- **Launch UI + server:** `./scripts/run-transparent-ui.sh` (opens `docs/transparent-ui/capacitor-interfaces-explorer.html`)
- **Headless server:** `node scripts/transparent-ui-server.mjs`
- **Agent briefing (compact):** `GET /agent-briefing?limit=200&shells=recent&shell_limit=25`
- **Agent briefing (full shells):** `GET /agent-briefing?shells=all`

Server runs on `http://localhost:9133` by default. See `docs/transparent-ui/README.md` for full endpoint list and env vars.

## Common Gotchas

- **Rebuild after Swift changes** — Run `./scripts/dev/restart-app.sh` after modifying Swift UI code to verify changes compile and render correctly
- **Layout padding for floating mode** — Header/footer clearance uses 64pt, content edge uses 12pt. Update ProjectsView + ProjectDetailView together.
- **Always run `cargo fmt`** — CI enforces formatting
- **Dev builds need dylib** — After Rust rebuilds: `cp target/release/libhud_core.dylib apps/swift/.build/arm64-apple-macosx/debug/`
- **Hook symlink, not copy** — Use `ln -s target/release/hud-hook ~/.local/bin/hud-hook` (copying triggers Gatekeeper SIGKILL)
- **UniFFI Task shadows Swift Task** — Use `_Concurrency.Task` explicitly in async code
- **UniFFI bindings after FFI changes** — `cargo run --bin uniffi-bindgen generate --library target/release/libhud_core.dylib --language swift --out-dir apps/swift/bindings && cp apps/swift/bindings/hud_core.swift apps/swift/Sources/Capacitor/Bridge/`
- **OSLog invisible for debug builds** — Use `FileHandle.standardError.write()` for telemetry; capture with `./Capacitor 2> /tmp/log.log &`
- **Alpha gating is runtime** — Channel resolves env → Info.plist → `~/.capacitor/config.json` → default (`.dev` for debug, `.prod` for release). `swift run` ignores Info.plist, so set `CAPACITOR_CHANNEL=alpha` (or use `./scripts/dev/restart-app.sh --channel alpha`) when testing alpha gating. Feature overrides exist via `CAPACITOR_FEATURES_ENABLED` / `CAPACITOR_FEATURES_DISABLED`.
- **Terminal activation prefers known parent apps** — If the newest shell entry has `parent_app=unknown` (missing `TERM_PROGRAM`), Ghostty activation can fail. The resolver should prefer shells with known `parent_app` before timestamp tie‑breakers.

**Full gotchas reference:** `.claude/docs/gotchas.md`

## Documentation

| Need | Document |
|------|----------|
| Development workflows | `.claude/docs/development-workflows.md` |
| Release procedures | `.claude/docs/release-guide.md` |
| Architecture deep-dive | `.claude/docs/architecture-overview.md` |
| Debugging | `.claude/docs/debugging-guide.md` |
| Terminal support matrix | `.claude/docs/terminal-switching-matrix.md` |
| Side effects reference | `.claude/compiled/side-effects.md` |
| All gotchas | `.claude/docs/gotchas.md` |

## Plans

Implementation plans in `.claude/plans/` with status prefixes: `ACTIVE-`, `DRAFT-`, `REFERENCE-`
