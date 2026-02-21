# Capacitor

A fun, glanceable, bring-your-own terminal UI for navigating multiple coding agent sessions in parallel.

## Stack

- **Platform** — Apple Silicon, macOS 14+
- **Swift App** (`apps/swift/`) — SwiftUI, 120Hz ProMotion
- **Rust Core** (`core/hud-core/`) — Business logic via UniFFI bindings

## Commands

```bash
# Quick iteration (most common)
./scripts/dev/restart-current.sh          # Rebuild + relaunch using current channel/profile context
./scripts/dev/restart-alpha-stable.sh     # Switch context to alpha+stable, then relaunch
./scripts/dev/restart-alpha-frontier.sh   # Switch context to alpha+frontier, then relaunch

# Rust (when changing core/)
cargo fmt                         # Format (required before commits)
cargo clippy -- -D warnings       # Lint
cargo test                        # Test

# Full rebuild (after Rust changes)
cargo build -p hud-core --release && cd apps/swift && swift build
# Advanced launch control:
./scripts/dev/restart-app.sh --channel alpha --profile stable
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

## Telemetry

Launch with `./scripts/run-transparent-ui.sh` (server on `localhost:9133`). Use `/daemon-snapshot` for one-shot state, `/agent-briefing` for agent context. See `.claude/docs/debugging-guide.md` for full endpoint list and troubleshooting.

For coding-agent runtime debugging, use the canonical observability runbook and helper:

- Runbook: `.claude/docs/agent-observability-runbook.md`
- Helper CLI: `./scripts/dev/agent-observe.sh`
- Make targets: `make observe-help` (and `make observe-*`)

Quick start:

```bash
./scripts/dev/agent-observe.sh check
make observe-smoke
./scripts/dev/agent-observe.sh health
./scripts/dev/agent-observe.sh projects
./scripts/dev/agent-observe.sh sessions
```

## Common Gotchas

- **Rebuild after Swift changes** — Run `./scripts/dev/restart-app.sh` to verify changes compile and render
- **Always run `cargo fmt`** — CI enforces formatting
- **Dev builds need dylib** — After Rust rebuilds: `cp target/release/libhud_core.dylib apps/swift/.build/arm64-apple-macosx/debug/`
- **Hook symlink, not copy** — Use `ln -s target/release/hud-hook ~/.local/bin/hud-hook` (copying triggers Gatekeeper SIGKILL)
- **UniFFI Task shadows Swift Task** — Use `_Concurrency.Task` explicitly in async code
- **Swift app links release Rust core** — After any `core/hud-core` change, run `cargo build -p hud-core --release` before `swift run`

**Full gotchas reference:** `.claude/docs/gotchas.md`
