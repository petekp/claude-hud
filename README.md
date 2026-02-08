# Capacitor

![Capacitor logomark](assets/logomark.svg)

A native macOS dashboard for [Claude Code](https://claude.ai/claude-code). Capacitor shows the state of every Claude session at a glance and lets you jump to the right terminal with one click.

This repo is focused on the public alpha. Capacitor is an observe-only sidecar: no workstreams, no idea capture, no project details.

## Features (Alpha)

- Real-time session state tracking: Working, Ready, Compacting, Idle
- Project dashboard with pinning, reordering, and pause/unhide
- One-click terminal activation for supported terminals
- Two layouts: Vertical and Dock

## Supported Terminals (Alpha)

Only these terminals are supported for one-click activation in the alpha:

| Terminal | Session Tracking | Project Activation | Notes |
|---------|------------------|--------------------|-------|
| **Ghostty** | ✅ | ✅ | Recommended | 
| **iTerm2** | ✅ | ✅ | AppleScript tab selection |
| **Terminal.app** | ✅ | ✅ | AppleScript tab selection |

Other terminals and IDE-integrated terminals are not supported in the alpha.

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4)
- macOS 14.0+ (Sonoma or later)
- Claude Code installed and configured

## Installation

### From Release (Recommended)

Download the latest DMG from [Releases](https://github.com/petekp/capacitor/releases), open it, and drag Capacitor to Applications.

### Building from Source

```bash
# Clone and setup (installs toolchains, builds everything, configures hooks)
git clone https://github.com/petekp/capacitor.git
cd capacitor
./scripts/dev/setup.sh

# Run the app
./scripts/dev/restart-app.sh

# Run with a specific channel (affects feature gating)
./scripts/dev/restart-app.sh --channel alpha
# Or when using swift run directly:
CAPACITOR_CHANNEL=alpha swift run
```

## Setup

Capacitor uses Claude Code hooks to track session state. On first launch, the app provides a setup card to install hooks and shell integration for your shell.

If you prefer to configure manually, add the following hooks to your Claude settings (`~/.claude/settings.json`):

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_ENABLED=1 $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_ENABLED=1 $HOME/.local/bin/hud-hook handle" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_ENABLED=1 $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
    "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_ENABLED=1 $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
    "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_ENABLED=1 $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_ENABLED=1 $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_ENABLED=1 $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
    "PreCompact": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_ENABLED=1 $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_ENABLED=1 $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }]
  }
}
```

Note: `SessionEnd` runs synchronously (no `async`/`timeout`) to ensure cleanup completes before the session exits.

## Add Projects

Click **Connect Project** or drop a folder onto the app. Capacitor detects Claude Code projects by looking for:

- `CLAUDE.md`
- `.claude/`
- `.git/`
- `package.json`, `Cargo.toml`, etc.

## Keyboard Shortcuts

- `⌘1` Vertical layout
- `⌘2` Dock layout
- `⌘⇧T` Toggle floating mode
- `⌘⇧P` Toggle always-on-top
- `⌘⇧?` Help
- `ESC` Back (where applicable)

## Known Limitations (Alpha)

- Only Ghostty, iTerm2, and Terminal.app are supported for one-click activation
- IDE-integrated terminals are not supported
- Workstreams, idea capture, and project details are disabled
- Remote/SSH sessions are not tracked

## Report Issues

File bugs at: https://github.com/petekp/capacitor/issues

## Architecture (Dev)

```
capacitor/
├── core/hud-core/       # Rust business logic
│   └── src/
│       ├── engine.rs    # FFI facade (UniFFI)
│       ├── sessions.rs  # Session state detection
│       ├── projects.rs  # Project management
│       ├── ideas.rs     # Idea capture system (disabled in alpha)
│       └── stats.rs     # Token usage parsing
│
├── core/hud-hook/       # Rust CLI hook handler
│   └── src/
│       ├── handle.rs    # Hook event processing
│       └── cwd.rs       # Shell CWD tracking
│
├── apps/swift/          # SwiftUI macOS app
│   └── Sources/Capacitor/
│       ├── Models/      # AppState, managers
│       ├── Views/       # UI components
│       └── Bridge/      # UniFFI bindings
│
└── scripts/             # Build and release tools
```

## Development

See `scripts/dev/` for setup and run helpers. The app uses a Rust core with UniFFI bindings.
