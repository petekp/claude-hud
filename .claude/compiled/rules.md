<!-- @task:core-rules @load:rules -->
# Core Rules (Daemon-Only)

## Sidecar Boundaries
- Read: `~/.claude/` (Claude Code data/config)
- Write: `~/.capacitor/` (Capacitor-owned state)
- Never call Anthropic API directly; use `claude` CLI

## Daemon-Only State
- Authority: daemon IPC (`~/.capacitor/daemon.sock`)
- Legacy files (`sessions.json`, `shell-cwd.json`, locks) are **non-authoritative**
- If daemon is down: surface error; do not silently fall back

## Telemetry Hub (Agent Briefing)
- Start: `./scripts/run-transparent-ui.sh` (local server + UI)
- Compact briefing: `GET /agent-briefing?limit=200&shells=recent&shell_limit=25`
- Full shells: `GET /agent-briefing?shells=all`
- Live streams: `/telemetry-stream`, `/activation-trace`

## Hooks
- `hud-hook` must be a **symlink** to `target/release/hud-hook`
- Hooks emit events over IPC; no direct file writes in daemon-only mode

## Swift + UniFFI
- Use `_Concurrency.Task` (avoid `Task` name clash)
- After Rust FFI changes: regen bindings and copy to `Sources/Capacitor/Bridge/`

## Session States
- Canonical: `Working`, `Ready`, `Idle`, `Compacting`, `Waiting`
- No “Thinking” state

## Terminal Limits
- Ghostty/Warp: no window/tab selection APIs → best-effort only
