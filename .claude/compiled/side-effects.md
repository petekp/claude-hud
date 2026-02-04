<!-- @task:side-effects @load:side-effects -->
# Side Effects (Daemon-Only Summary)

## Authoritative Writes
- `~/.capacitor/daemon/state.db` — daemon state store
- `~/.capacitor/daemon/daemon.*.log` — daemon stdout/stderr
- `~/.capacitor/hud-hook-heartbeat` — hook proof-of-life
- `~/.capacitor/config.json` — user prefs
- `~/.capacitor/projects.json` — tracked projects list
- `~/.capacitor/stats-cache.json` — stats cache
- `~/.local/bin/hud-hook` — symlinked hook binary
- `~/.claude/settings.json` — hooks section only (preserve other settings)

## Legacy (Non-Authoritative)
Legacy files are deprecated in daemon-only mode and should not be used. If they exist from old installs, they can be deleted.

## IPC
- Socket: `~/.capacitor/daemon.sock`
- Clients: `hud-hook`, Swift app, `hud-core`
