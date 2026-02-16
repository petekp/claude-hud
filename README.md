![Capacitor banner](assets/banner.png)

# Capacitor

Capacitor is a companion app for [Claude Code](https://claude.ai/claude-code) (more coding agents on the way, starting with Codex). I built it because I was tired of coding agent tools that try to be the terminal, the editor, the git client, and the chat window all at once. None of those things end up as good as the tools you already use.

If you've ever lost track of which terminal window or tmux pane has which session, that's what Capacitor is for. It keeps your sessions visible and one click away. More features on are the way, ones that further streamline your process and respect your tooling preferences.

## Download

**[Download the latest alpha release](https://github.com/petekp/capacitor/releases/latest)** (Apple Silicon, macOS 14+)

Capacitor is in early alpha. Expect rough edges. [Report issues here.](https://github.com/petekp/capacitor/issues)

## Why use it

- Keep project context visible without terminal tab hunting
- See live session state at a glance
- Click a project card to return to the right terminal/tmux context
- Stay focused when juggling multiple projects
- It's _fun_!

## How terminal switching works

When you click a project card, Capacitor tries to get you back to the right place:

| Workflow | Ghostty | iTerm2 | Terminal.app |
| --- | --- | --- | --- |
| Single window, single pane | ✅ | ✅ | ✅ |
| Multiple tmux panes | ✅ | ✅ | ✅ |
| Switch between tmux sessions | ✅ | ✅ | ✅ |
| Reattach detached tmux sessions | ✅ | ✅ | ✅ |

If a matching session or pane exists, Capacitor focuses it. If there's an existing terminal window, it reuses it instead of spawning a new one. If nothing can be recovered, it falls back to opening a new window.

Only Ghostty, iTerm2, and Terminal.app are supported right now. More on the way if there's demand.

**Known rough edges:** multi-window ambiguity is currently a Ghostty-specific limitation. I'm patiently awaiting Ghostty AppleScript support to enable reliable per-window targeting there.

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
- `tmux` recommended (Capacitor can restore exact pane context)

## Feedback

Use the in-app feedback form, or open a [GitHub issue](https://github.com/petekp/capacitor/issues).
