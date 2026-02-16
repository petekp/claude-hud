![Capacitor banner](assets/banner.png)

# Capacitor

Capacitor is a native macOS sidecar for [Claude Code](https://claude.ai/claude-code).
It shows live session state across your projects and lets you jump back to the right terminal with one click.

## Status

Early public alpha (`0.2.0-alpha.1`). The focus right now is getting terminal activation solid — finding the right window, the right tmux session, every time.

## What's working

- Live session state in a native macOS UI
- Project list with pinning/reordering and active-vs-idle grouping
- One-click activation — click a project, land in its terminal
- Finds your existing terminal or tmux session first, opens a new one if it can't

Behind feature flags (off by default):

- idea capture
- project details
- workstreams
- project creation
- llm features

## Supported terminals

| Terminal | Session Tracking | One-Click Activation | Notes |
| --- | --- | --- | --- |
| Ghostty | ✅ | ✅ | Recommended default |
| iTerm2 | ✅ | ✅ | AppleScript window/tab activation |
| Terminal.app | ✅ | ✅ | AppleScript window/tab activation |

Other terminals might work but haven't been tested yet.

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 14+
- Claude Code installed
- `tmux` if you want session reuse

## Install

### Release build

Download the latest DMG from [Releases](https://github.com/petekp/capacitor/releases), then drag `Capacitor.app` to `/Applications`.

### Build from source

```bash
git clone https://github.com/petekp/capacitor.git
cd capacitor
./scripts/dev/setup.sh
./scripts/dev/restart-app.sh --channel alpha
```

## First run setup

First launch walks you through hooks and shell integration. You can do it all from the app — no need to hand-edit `~/.claude/settings.json`.

## Daily usage

1. Connect a project from the UI (or drag a folder in).
2. Keep Claude Code running in your terminals as usual.
3. Click any project card to focus/switch to its terminal context.

## Activation reliability

Terminal activation is manually tested across all supported terminals before each release. Still some kinks to iron out, but the core path is solid.

## Development

### Useful commands

```bash
# One-time bootstrap
./scripts/dev/setup.sh

# Build + run debug app bundle
./scripts/dev/restart-app.sh --channel alpha

# Fast full local checks
./scripts/dev/run-tests.sh

# Swift-only test loop
cd apps/swift && swift test

# Resolver-focused daemon tests
cargo test -p capacitor-daemon resolver_ -- --nocapture
```

### Project structure

```text
apps/swift/            SwiftUI macOS app
core/daemon/           Rust daemon (routing, reducer, telemetry state)
core/daemon-protocol/  Shared daemon protocol types
core/hud-core/         Rust core library exposed via UniFFI to Swift
core/hud-hook/         Hook CLI that forwards Claude events/CWD updates
docs/                  Specs, ADRs, runbooks, and QA evidence
scripts/               Bootstrap, run, release, and maintenance scripts
```

## Rough edges

- Deliberately small scope — reliability over features.
- Remote/SSH setups probably don't work well yet.
- Multi-terminal edge cases outside the supported matrix might fall back to opening a new terminal.

## Issues

Bug reports and feature requests: [GitHub Issues](https://github.com/petekp/capacitor/issues)

## License

MIT — see [LICENSE](LICENSE) for details.
