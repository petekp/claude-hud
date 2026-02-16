![Capacitor banner](assets/banner.png)

# Capacitor

Capacitor is a companion app for [Claude Code](https://claude.ai/claude-code). I built it because I was tired of coding agent tools that try to be the terminal, the editor, the git client, and the chat window all at once. None of those things end up as good as the tools you already use.

If you've ever lost track of which terminal window or tmux pane has which session, that's what Capacitor is for. It keeps your sessions visible and one click away.

## Download

**[Download the latest alpha release](https://github.com/petekp/capacitor/releases/latest)** (Apple Silicon, macOS 14+)

> Capacitor is in early alpha. Expect rough edges. [Report issues here.](https://github.com/petekp/capacitor/issues)

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

1. Download the latest DMG from the [Releases page](https://github.com/petekp/capacitor/releases).
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
