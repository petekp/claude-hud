![Capacitor banner](assets/banner.png)

# Capacitor

Capacitor is a native macOS sidecar for [Claude Code](https://claude.ai/claude-code).
It shows live session state across your projects and gets you back to the right terminal context with one click.

## Status

Capacitor is in a small public alpha focused on terminal activation reliability.

- Current workspace version: `0.2.0-alpha.1`
- Audience: individual power users and small teams already running Claude Code locally
- Release focus: predictable project-card activation, not broad feature surface

## What You Get In Alpha

- Live session state tracking in a native macOS UI
- Project list with pinning/reordering and active-vs-idle grouping
- One-click activation with deterministic latest-click-wins behavior
- Reuse-first routing to existing terminal/tmux context, with controlled fallback when needed

Feature flags defaulted off in alpha channel:

- idea capture
- project details
- workstreams
- project creation
- llm features

## Supported Terminals (Alpha Release Gate)

| Terminal | Session Tracking | One-Click Activation | Notes |
| --- | --- | --- | --- |
| Ghostty | ✅ | ✅ | Recommended default |
| iTerm2 | ✅ | ✅ | AppleScript window/tab activation |
| Terminal.app | ✅ | ✅ | AppleScript window/tab activation |

Other terminals and IDE-integrated terminals may partially work but are not release-gated for alpha.

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 14+
- Claude Code installed
- `tmux` installed for tmux-session reuse workflows

## Install

### Release Build

Download the latest DMG from [Releases](https://github.com/petekp/capacitor/releases), then drag `Capacitor.app` to `/Applications`.

### Build From Source

```bash
git clone https://github.com/petekp/capacitor.git
cd capacitor
./scripts/dev/setup.sh
./scripts/dev/restart-app.sh --channel alpha
```

## First Run Setup

On first launch, Capacitor shows setup guidance to install/verify required hooks and shell integration.
You can complete setup from the app; manual editing of `~/.claude/settings.json` is optional.

## Daily Usage

1. Connect a project from the UI (or drag a folder in).
2. Keep Claude Code running in your terminals as usual.
3. Click any project card to focus/switch to its terminal context.

## Manual QA And Evidence

Terminal activation behavior is governed by a strict UX contract and manual test matrix:

- Contract: `docs/TERMINAL_ACTIVATION_UX_SPEC.md`
- Manual matrix: `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md`
- Latest full human rerun evidence: `docs/manual-qa/2026-02-15-terminal-activation-manual-qa.md`

## Development

### Useful Commands

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

### Project Structure

```text
apps/swift/            SwiftUI macOS app
core/daemon/           Rust daemon (routing, reducer, telemetry state)
core/daemon-protocol/  Shared daemon protocol types
core/hud-core/         Rust core library exposed via UniFFI to Swift
core/hud-hook/         Hook CLI that forwards Claude events/CWD updates
docs/                  Specs, ADRs, runbooks, and QA evidence
scripts/               Bootstrap, run, release, and maintenance scripts
```

## Known Alpha Limits

- Scope is intentionally narrow and reliability-first.
- Remote/SSH contexts are not the primary validated path.
- Multi-terminal edge cases outside the supported matrix may degrade to fallback launch behavior.

## Issue Reporting

- Bug reports: [GitHub Issues](https://github.com/petekp/capacitor/issues)
