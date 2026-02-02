<!-- @task:hooks @load:hooks -->
# Hooks (Daemon-Only)

## Binary + Install
```bash
cargo build -p hud-hook --release
ln -sf target/release/hud-hook ~/.local/bin/hud-hook
./scripts/sync-hooks.sh --force
```

## Behavior
- Hooks emit events to daemon over IPC
- If daemon is unavailable: surface error (no file fallback)
- Heartbeat file updated only on valid events

## Event Types (v1)
`session_start`, `user_prompt_submit`, `pre_tool_use`, `post_tool_use`,
`permission_request`, `pre_compact`, `notification`, `stop`, `session_end`, `shell_cwd`

## Quick Smoke
```bash
printf '{"protocol_version":1,"method":"get_health","id":"health","params":null}\n' | nc -U ~/.capacitor/daemon.sock
```

