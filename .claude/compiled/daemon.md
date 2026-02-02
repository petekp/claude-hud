<!-- @task:daemon-health @load:daemon -->
# Daemon IPC (Quick Reference)

## Socket + Format
- Socket: `~/.capacitor/daemon.sock`
- One JSON request per connection, newline-terminated
- `protocol_version` must be `1`

## Methods (v1)
- `get_health`
- `get_shell_state`
- `get_process_liveness`
- `get_sessions`
- `get_project_states`
- `get_activity`
- `get_tombstones`
- `event`

## Example Requests
```bash
printf '{"protocol_version":1,"method":"get_health","id":"health","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_shell_state","id":"shell","params":null}\n' | nc -U ~/.capacitor/daemon.sock
```

## Event Envelope (summary)
Required fields vary by `event_type`.
- Common: `event_id`, `recorded_at` (RFC3339), `event_type`
- Session events: `session_id`, `pid`, `cwd`
- `shell_cwd`: `pid`, `cwd`, `tty`

## Daemon-Only Rule
- Do **not** fall back to file writes when daemon is unavailable.
- Surface errors; rely on LaunchAgent to recover.
