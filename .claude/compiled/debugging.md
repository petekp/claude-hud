<!-- @task:debugging @load:debugging -->
# Debugging (Daemon-First)

## Telemetry Hub (Transparent UI)
```bash
./scripts/run-transparent-ui.sh
```
Endpoints (http://localhost:9133):
- `GET /agent-briefing?limit=200&shells=recent&shell_limit=25`
- `GET /agent-briefing?shells=all`
- `GET /daemon-snapshot`
- `GET /telemetry?limit=200`
- `GET /telemetry-stream` (SSE)
- `GET /activation-trace` (SSE)

Notes:
- Telemetry is in-memory; restarting clears events.
- Swift app posts structured telemetry automatically to `/telemetry`.

## Telemetry Event Glossary (Swift)

Activation
- `activation_start` — activation request began for a project.
- `activation_decision` — Rust decision result + fallback candidate.
- `activation_primary_result` — primary action success/failure.
- `activation_fallback_result` — fallback action success/failure (only if primary failed).
- `activation_trace` — formatted decision trace (when tracing enabled).
- `activation_log` — verbose activation breadcrumb (mirrors DebugLog).

Daemon + IPC
- `daemon_health` — daemon status poll (healthy/unhealthy/disabled).
- `daemon_ipc_error` — socket send/receive/parse error.
- `daemon_install_error` — daemon binary install failed.
- `daemon_kickstart_error` — LaunchAgent kickstart failed.

Shell + Project Resolution
- `shell_state_refresh` — shell snapshot updated or failed.
- `shell_selection` — how the active shell was chosen.
- `active_project_resolution` — which project is currently active (manual/Claude/shell).
- `active_project_override` — manual override set or cleared.

## Efficient Debug Ops (Copy/Paste)

Get a compact, agent-ready snapshot:
```bash
curl -s 'http://localhost:9133/agent-briefing?limit=200&shells=recent&shell_limit=25'
```

Stream live telemetry (stop with Ctrl+C):
```bash
curl -N http://localhost:9133/telemetry-stream
```

Stream activation traces only:
```bash
curl -N http://localhost:9133/activation-trace
```

Filter telemetry to a single type (requires jq):
```bash
curl -s 'http://localhost:9133/telemetry?limit=200' | jq '.events[] | select(.type=="daemon_ipc_error")'
```

Quick shell snapshot for a path (requires jq):
```bash
curl -s http://localhost:9133/daemon-snapshot | jq --arg path "/Users/you/Code/project" '
  .shell_state.shells | to_entries[] |
  select(.value.cwd | contains($path)) |
  {pid: .key, cwd: .value.cwd, tty: .value.tty, parent: .value.parent_app, updated: .value.updated_at}
'
```

## Health + Logs
```bash
launchctl print gui/$(id -u)/com.capacitor.daemon
printf '{"protocol_version":1,"method":"get_health","id":"health","params":null}\n' | nc -U ~/.capacitor/daemon.sock
ls -la ~/.capacitor/daemon/daemon.stderr.log
tail -50 ~/.capacitor/daemon/daemon.stderr.log
ls -la ~/.capacitor/daemon/app-debug.log
tail -50 ~/.capacitor/daemon/app-debug.log
```

## State Snapshots
```bash
printf '{"protocol_version":1,"method":"get_sessions","id":"sessions","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_project_states","id":"projects","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_shell_state","id":"shell","params":null}\n' | nc -U ~/.capacitor/daemon.sock
```

## Common Symptoms → First Checks
- **Offline banner** → `get_health`, daemon stderr log, LaunchAgent state
- **State stuck Working/Ready** → `get_sessions` + `get_project_states`, check PID liveness
- **Shell highlight stuck** → `get_shell_state` contents vs expected cwd/tty

## Daemon-Only Note
Legacy files (`sessions.json`, `shell-cwd.json`, lock dirs) are non-authoritative in daemon-only mode.
