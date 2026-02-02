<!-- @task:side-effects @load:side-effects -->
# Side Effects (Daemon-Only Summary)

## Authoritative Writes
- `~/.capacitor/daemon/state.db` — daemon state store
- `~/.capacitor/daemon/daemon.*.log` — daemon stdout/stderr
- `~/.capacitor/hud-hook-heartbeat` — hook proof-of-life
- `~/.capacitor/config.json` — user prefs
- `~/.capacitor/projects.json` — project cache
- `~/.capacitor/ideas.json` — ideas
- `~/.capacitor/stats_cache.json` — stats cache
- `~/.local/bin/hud-hook` — symlinked hook binary
- `~/.claude/settings.json` — hooks section only (preserve other settings)

## Legacy (Non-Authoritative)
- `~/.capacitor/sessions.json`
- `~/.capacitor/sessions/*.lock/`
- `~/.capacitor/shell-cwd.json`
- `~/.capacitor/file-activity.json`
- `~/.capacitor/ended-sessions/*`

## IPC
- Socket: `~/.capacitor/daemon.sock`
- Clients: `hud-hook`, Swift app, `hud-core`

