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

Capacitor is a sidecar — it watches Claude Code without replacing anything.

On first launch, it installs a small hook binary (`~/.local/bin/hud-hook`) and adds entries to Claude Code's `~/.claude/settings.json`. A background daemon starts at login (`com.capacitor.daemon` LaunchAgent) and listens for Claude Code events over a Unix socket. When you start a session, the hook fires and tells the daemon what's happening. Capacitor reads the daemon's state and shows it to you.

It never calls the Anthropic API. It just observes.

## Data & privacy

Capacitor reads from `~/.claude/` (transcripts, settings — Claude Code's namespace) and writes to `~/.capacitor/` (session state, daemon logs — ours). It also adds hook entries to `~/.claude/settings.json`, but never touches your other settings. Writes are atomic (temp file + rename).

No data is sent to Anthropic or any remote server. The app has a local telemetry emitter that posts to `localhost:9133` for the optional dev debugging UI — it doesn't go anywhere unless you explicitly run that server. The "Include anonymized telemetry" toggle in Settings controls whether app metadata gets attached to GitHub issue drafts when you submit feedback. Project paths are redacted in feedback by default — you can opt in if it helps with debugging.

## Permissions

Capacitor uses AppleScript to switch terminal windows, so macOS will ask for Automation access the first time. If you dismiss the prompt, terminal switching won't work. You can re-grant it later in System Settings > Privacy & Security > Automation.

## Settings

`⌘,` opens Settings. You can toggle:

- Floating mode (borderless, position anywhere)
- Always on top
- Ready chime (plays a sound when Claude finishes)
- Automatic update checks
- Feedback privacy (anonymized telemetry for issue drafts, project path inclusion)

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘O` | Connect project |
| `⌘1` | Vertical layout |
| `⌘2` | Dock layout |
| `⌘⇧T` | Toggle floating mode |
| `⌘⇧P` | Toggle always on top |
| `⌘[` | Navigate back |
| `⌘,` | Settings |

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 14+
- Claude Code installed
- `tmux` recommended (Capacitor can restore exact pane context)

## Troubleshooting

**Projects not showing up?** Check the hooks status indicator in the app. If it says something's wrong, click "Fix All."

**Terminal switching broken?** You probably dismissed the Automation permission prompt. Go to System Settings > Privacy & Security > Automation and grant it.

**Daemon issues?** The app starts the daemon automatically. If something seems off, check `~/.capacitor/daemon/` for logs: `tail -f ~/.capacitor/daemon/daemon.stderr.log`

More help: [open a GitHub issue](https://github.com/petekp/capacitor/issues).

## Uninstall

To fully remove Capacitor and everything it installed:

1. Quit the app
2. `rm -rf /Applications/Capacitor.app`
3. `rm -rf ~/.capacitor`
4. `rm ~/.local/bin/hud-hook`
5. `rm ~/.local/bin/capacitor-daemon`
6. `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.capacitor.daemon.plist 2>/dev/null; rm -f ~/Library/LaunchAgents/com.capacitor.daemon.plist`
7. Remove `hud-hook` entries from `~/.claude/settings.json`
8. Optionally: `defaults delete com.capacitor.app`

## License

MIT — see [LICENSE](LICENSE).

## Feedback

Use the in-app feedback form, or open a [GitHub issue](https://github.com/petekp/capacitor/issues).
