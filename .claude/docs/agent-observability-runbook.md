# Agent Observability Runbook

Canonical runtime observability guide for coding agents working in this repo.

If you only remember one command, use:

```bash
./scripts/dev/agent-observe.sh check
```

Equivalent make target:

```bash
make observe-check
```

One-shot baseline verification:

```bash
make observe-smoke
```

## Canonical Sources (Trust Order)

1. Daemon SQLite state (`~/.capacitor/daemon/state.db`) for durable truth.
2. Daemon IPC snapshots (`~/.capacitor/daemon.sock`) for current state.
3. Daemon/hook/app logs for causal traces.
4. Transparent UI endpoints for fast local aggregation and live telemetry stream.
5. Remote ingest telemetry for feedback analytics only (not runtime truth).

## Single Entry-Point Tool

Use this wrapper for almost all agent debugging:

```bash
./scripts/dev/agent-observe.sh help
```

Or via make:

```bash
make observe-help
```

### High-value commands

```bash
./scripts/dev/agent-observe.sh health
./scripts/dev/agent-observe.sh sessions
./scripts/dev/agent-observe.sh projects
./scripts/dev/agent-observe.sh shells
./scripts/dev/agent-observe.sh activity 120
./scripts/dev/agent-observe.sh routing-snapshot /Users/petepetrash/Code/capacitor
./scripts/dev/agent-observe.sh routing-diagnostics /Users/petepetrash/Code/capacitor
./scripts/dev/agent-observe.sh briefing 200
./scripts/dev/agent-observe.sh telemetry 200
```

Make equivalents:

```bash
make observe-health
make observe-projects
make observe-sessions
make observe-shells
make observe-activity LIMIT=120
make observe-briefing LIMIT=200
make observe-telemetry LIMIT=200
```

### SQL against authoritative state

```bash
./scripts/dev/agent-observe.sh sql "SELECT event_type, COUNT(*) AS n FROM events GROUP BY event_type ORDER BY n DESC;"
./scripts/dev/agent-observe.sh sql "SELECT session_id, state, project_path, updated_at FROM sessions ORDER BY updated_at DESC LIMIT 25;"
./scripts/dev/agent-observe.sh sql "SELECT category, COUNT(*) AS n FROM hem_shadow_mismatches GROUP BY category ORDER BY n DESC;"
```

Make equivalent:

```bash
make observe-sql QUERY='SELECT event_type, COUNT(*) AS n FROM events GROUP BY event_type ORDER BY n DESC;'
```

### Tail key logs

```bash
./scripts/dev/agent-observe.sh tail app
./scripts/dev/agent-observe.sh tail daemon-stderr
./scripts/dev/agent-observe.sh tail daemon-stdout
tail -f ~/.capacitor/hud-hook-debug*.log
```

Make equivalents:

```bash
make observe-tail-app
make observe-tail-daemon-stderr
make observe-tail-daemon-stdout
```

## Canonical Paths

```text
Daemon socket:            ~/.capacitor/daemon.sock
Daemon DB:                ~/.capacitor/daemon/state.db
Daemon stderr log:        ~/.capacitor/daemon/daemon.stderr.log
Daemon stdout log:        ~/.capacitor/daemon/daemon.stdout.log
App debug log:            ~/.capacitor/daemon/app-debug.log
Hook debug logs:          ~/.capacitor/hud-hook-debug*.log
Hook heartbeat marker:    ~/.capacitor/hud-hook-heartbeat
Transparent UI server:    http://localhost:9133
```

You can print resolved paths from your environment with:

```bash
./scripts/dev/agent-observe.sh paths
```

## Transparent UI Endpoints

```text
GET /daemon-snapshot
GET /agent-briefing?limit=200&shells=recent&shell_limit=25
GET /telemetry?limit=200
GET /telemetry-stream
GET /routing-snapshot?project_path=...
GET /routing-diagnostics?project_path=...
GET /routing-rollout
```

Notes:

- `/telemetry` and `/telemetry-stream` are local in-memory buffers.
- Durable history and source-of-truth queries must use daemon IPC + SQLite.

## Correlation Workflow (Recommended)

1. Start with current state:

```bash
./scripts/dev/agent-observe.sh health
./scripts/dev/agent-observe.sh projects
./scripts/dev/agent-observe.sh sessions
```

2. Pull recent activity and routing evidence:

```bash
./scripts/dev/agent-observe.sh activity 200
./scripts/dev/agent-observe.sh routing-diagnostics /absolute/project/path
```

3. Confirm durable event trail:

```bash
./scripts/dev/agent-observe.sh sql "SELECT id, recorded_at, event_type, session_id, pid FROM events ORDER BY rowid DESC LIMIT 200;"
```

4. Cross-check causal logs:

```bash
./scripts/dev/agent-observe.sh tail daemon-stderr
./scripts/dev/agent-observe.sh tail app
tail -f ~/.capacitor/hud-hook-debug*.log
```

5. Use Transparent UI only as aggregation/live view:

```bash
./scripts/dev/agent-observe.sh briefing 200
./scripts/dev/agent-observe.sh stream
```

## Remote Ingest Scope (Important)

Remote `/v1/telemetry` persists only quick-feedback allowlisted events.
Do not use it for runtime state debugging.

## Failure Triage Shortcuts

If daemon looks unhealthy:

```bash
./scripts/dev/agent-observe.sh health
launchctl print gui/$(id -u)/com.capacitor.daemon
./scripts/dev/agent-observe.sh tail daemon-stderr
```

If project/session state looks wrong:

```bash
./scripts/dev/agent-observe.sh projects
./scripts/dev/agent-observe.sh sessions
./scripts/dev/agent-observe.sh sql "SELECT session_id, state, project_path, updated_at, state_changed_at FROM sessions ORDER BY updated_at DESC;"
./scripts/dev/agent-observe.sh sql "SELECT id, recorded_at, event_type, session_id FROM events ORDER BY rowid DESC LIMIT 200;"
```

If shell/tmux focus looks wrong:

```bash
./scripts/dev/agent-observe.sh shells
./scripts/dev/agent-observe.sh routing-diagnostics /absolute/project/path
tail -f ~/.capacitor/hud-hook-debug*.log
```
