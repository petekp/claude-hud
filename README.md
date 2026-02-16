![Capacitor banner](assets/banner.png)

# Capacitor

Capacitor is a native macOS sidecar for [Claude Code](https://claude.ai/claude-code).
It shows live session state across your projects and lets you jump back to the right terminal with one click.

## Status

Capacitor is in a small public alpha focused on terminal activation reliability.

- Current workspace version: `0.2.0-alpha.1`
- Audience: individual power users and small teams already running Claude Code locally
- Release focus: reliable project-card activation, not broad feature surface

## What you get in alpha

- Live session state in a native macOS UI
- Project list with pinning/reordering and active-vs-idle grouping
- One-click activation — always opens the most recently clicked project
- Finds your existing terminal or tmux session first, falls back to a new one if needed

These features are behind flags and off by default in alpha:

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

Other terminals and IDE-integrated terminals may partially work but haven't been tested for this release.

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 14+
- Claude Code installed
- `tmux` installed for tmux-session reuse workflows

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

On first launch, Capacitor walks you through installing the required hooks and shell integration.
You can do it all from the app — editing `~/.claude/settings.json` by hand is optional.

## Daily usage

1. Connect a project from the UI (or drag a folder in).
2. Keep Claude Code running in your terminals as usual.
3. Click any project card to focus/switch to its terminal context.

## Activation reliability

Terminal activation is manually tested across all supported terminals before each release.

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

## Known alpha limits

- The alpha is deliberately small in scope — reliability over features.
- Remote/SSH setups haven't been the focus and may not work well yet.
- Multi-terminal edge cases outside the supported matrix may fall back to launching a new terminal.

## Issue reporting

Bug reports and feature requests: [GitHub Issues](https://github.com/petekp/capacitor/issues)

## License

MIT — see [LICENSE](LICENSE) for details.
