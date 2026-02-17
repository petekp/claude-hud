![Capacitor banner](assets/banner.png)

# Capacitor

Capacitor is a companion app for [Claude Code](https://claude.ai/claude-code) (more coding agents on the way, starting with Codex). I built it because I was tired of coding agent tools that try to be the terminal, the editor, the git client, and the chat window all at once. None of those things end up as good as the tools you already use.

If you've ever lost track of which terminal window or tmux pane has which session, that's what Capacitor is for. It keeps your sessions visible and one click away. More features on are the way, ones that further streamline your process and respect your tooling preferences.

## Download

**[Download the latest alpha release](https://github.com/petekp/capacitor/releases)** (Apple Silicon, macOS 14+)

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

## How it works

Capacitor is a sidecar — it observes Claude Code without replacing any part of it.

- On first launch, it symlinks a hook binary to `~/.local/bin/hud-hook` and registers it in Claude Code's `~/.claude/settings.json`
- A background daemon (`com.capacitor.daemon`) is installed as a macOS LaunchAgent and starts at login to track session state
- The hook fires on Claude Code events (session start/end, tool use, etc.) and forwards them to the daemon over a Unix socket (`~/.capacitor/daemon.sock`)
- Capacitor reads the daemon's state to show you what's happening — it never calls the Anthropic API directly

## Data & privacy

- **Reads:** `~/.claude/` (transcripts, settings) — Claude Code's namespace
- **Writes:** `~/.capacitor/` (session state, daemon logs) — Capacitor's namespace
- **Modifies:** `~/.claude/settings.json` to add hook entries (never removes or changes other settings; writes are atomic via temp file + rename)
- **No analytics or telemetry are sent anywhere.** The "Include anonymized telemetry" toggle in Settings only controls whether app/daemon metadata is attached to GitHub issue drafts when you submit feedback — nothing is sent in the background
- Project paths are redacted by default in feedback; you can opt in to include them for debugging

## Permissions

Capacitor uses AppleScript to switch between terminal windows. On first use, macOS will prompt you to grant **Automation** access. If you dismiss the prompt, terminal switching won't work — you can re-grant it in **System Settings > Privacy & Security > Automation**.

## Settings

Open Settings with `⌘,`. Available preferences:

- **Floating Mode** — borderless window that can be positioned anywhere
- **Always on Top** — window stays above other windows
- **Play Ready Chime** — audio notification when Claude finishes a task
- **Check for updates automatically** — periodic update checks (Sparkle-based)
- **Feedback privacy** — opt into anonymized telemetry; project paths stay redacted unless you explicitly enable them

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘O` | Connect project |
| `⌘1` | Vertical layout |
| `⌘2` | Dock layout |
| `⌘⇧T` | Toggle Floating Mode |
| `⌘⇧P` | Toggle Always on Top |
| `⌘[` | Navigate back |
| `⌘,` | Settings |

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 14+
- Claude Code installed
- `tmux` recommended (Capacitor can restore exact pane context)

## Troubleshooting

**Projects aren't appearing** — Make sure hooks are installed. Look for the status indicator in the app and click "Fix All" if prompted.

**Terminal switching doesn't work** — Grant Automation permission in System Settings > Privacy & Security > Automation.

**Daemon not running** — The app auto-starts the daemon. If issues persist, check `~/.capacitor/daemon/` for logs.

**State seems stuck** — Restart the app. If it persists, check daemon health: `tail -f ~/.capacitor/daemon/daemon.stderr.log`

For more help, open a [GitHub issue](https://github.com/petekp/capacitor/issues).

## Uninstall

1. Quit Capacitor
2. Remove the app: `rm -rf /Applications/Capacitor.app`
3. Remove data: `rm -rf ~/.capacitor`
4. Remove hook binary: `rm ~/.local/bin/hud-hook`
5. Remove daemon binary: `rm ~/.local/bin/capacitor-daemon`
6. Remove LaunchAgent: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.capacitor.daemon.plist && rm ~/Library/LaunchAgents/com.capacitor.daemon.plist`
7. Remove hook entries from `~/.claude/settings.json` (search for `hud-hook` and remove those entries)
8. Optionally clear preferences: `defaults delete com.capacitor.app`

## License

MIT — see [LICENSE](LICENSE) for details.

## Feedback

Use the in-app feedback form, or open a [GitHub issue](https://github.com/petekp/capacitor/issues).
