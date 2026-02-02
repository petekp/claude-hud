<!-- @task:ui-state @load:ui-state -->
# Session UI State (Daemon-First)

## Canonical States
`Working`, `Ready`, `Idle`, `Compacting`, `Waiting`

## Source of Truth
- Sessions + project states come from daemon IPC
- Use daemon `state_changed_at` and process liveness for staleness checks

## Rules of Thumb
- If daemon reports session active → UI should show non-idle state
- If no active session and no recent activity → `Idle`
- Activity should never override explicit session state

## Debug Checks
```bash
printf '{"protocol_version":1,"method":"get_sessions","id":"sessions","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_project_states","id":"projects","params":null}\n' | nc -U ~/.capacitor/daemon.sock
```

