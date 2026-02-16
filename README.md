![Capacitor banner](assets/banner.png)

# Capacitor

Capacitor is a companion app for [Claude Code](https://claude.ai/claude-code). I built it for myself to make it easier (and more fun) to work on multiple projects in parallel. Capacitor tracks all your active sessions and with a click you can instantly jump to the right session in your terminal.

Capacitor gives you one surface to see what is active, what is idle, and where to jump next. This is just the foundation. Upcoming releases will offer worktree support, and new ways to capture your ideas as they come with automatic triage, prioritization, and more.

## Why use it

- Keep project context visible without terminal tab hunting
- See live session state at a glance
- Click a project card to return to the right terminal/tmux context
- Stay focused when juggling multiple projects
- It's _fun_!

## Supported terminals

| Terminal     | Session Tracking | One-Click Activation |
| ------------ | ---------------- | -------------------- |
| Ghostty      | ✅               | ✅                   |
| iTerm2       | ✅               | ✅                   |
| Terminal.app | ✅               | ✅                   |

With more on the way if there's demand...

## Install

1. Download the latest DMG from [Releases](https://github.com/petekp/capacitor/releases).
2. Drag `Capacitor.app` into `/Applications`.
3. Launch the app.

## Quick Start

1. Open Capacitor.
2. Connect a project (or drag a project folder into the app).
3. Run Claude Code in your terminal(s) as normal.
4. Click project cards in Capacitor to jump to the right session.

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 14+
- Claude Code installed
- `tmux` strongly recommended for the best experience

## Need Help Or Want To Report A Bug?

- Use the in-app feedback form or open an issue: [GitHub Issues](https://github.com/petekp/capacitor/issues)
