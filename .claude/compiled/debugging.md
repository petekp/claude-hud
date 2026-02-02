<!-- @task:debugging @load:debugging -->
# Debugging (Daemon-First)

## Health + Logs
```bash
launchctl print gui/$(id -u)/com.capacitor.daemon
printf '{"protocol_version":1,"method":"get_health","id":"health","params":null}\n' | nc -U ~/.capacitor/daemon.sock
ls -la ~/.capacitor/daemon/daemon.stderr.log
tail -50 ~/.capacitor/daemon/daemon.stderr.log
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

