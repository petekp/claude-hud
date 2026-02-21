# Transparent UI Learn/Live Dashboard

Transparent UI is the local architecture-learning + live-debug dashboard for the daemon-owned Ambient Routing Engine (ARE) architecture.

The restored interface includes:
- `Learn` tab: architecture graph walkthroughs + contracts
- `Live` tab: daemon snapshot explorer, unified telemetry timeline, activation trace view, session-machine inspector

Data sources:
- daemon routing snapshot state (`get_routing_snapshot`)
- rollout gate health (`get_health.data.routing.rollout`)
- live app telemetry events posted to `/telemetry`

## Quick Start

```bash
scripts/run-transparent-ui.sh
```

This starts the local server on `http://localhost:9133` and opens:

- `docs/transparent-ui/capacitor-interfaces-explorer.html`

## Server Endpoints

Base URL (default): `http://localhost:9133`

### `GET /daemon-snapshot`
Returns a combined snapshot from daemon IPC:
- `sessions`
- `project_states`
- `activity`
- `shell_state` (trimmed by default)
- `health`
- `routing`:
  - `project_path` (selected automatically, or from query override)
  - `snapshot`
  - `diagnostics`
  - `rollout`
  - `health`

Query params:
- `project_path` (optional)
- `workspace_id` (optional)
- `shells` (`recent` default, `all`)
- `shell_limit` (default `25`)

### `GET /routing-snapshot?project_path=/abs/path[&workspace_id=ws]`
Proxy to daemon `get_routing_snapshot`.

### `GET /routing-diagnostics?project_path=/abs/path[&workspace_id=ws]`
Proxy to daemon `get_routing_diagnostics`.

### `GET /routing-rollout`
Returns routing health + rollout gate from daemon `get_health`.

### `GET /telemetry?limit=50`
Returns most recent in-memory telemetry events.

### `POST /telemetry`
Appends a telemetry event to the in-memory buffer.

Example:

```bash
curl -X POST http://localhost:9133/telemetry \
  -H 'Content-Type: application/json' \
  -d '{"type":"activation_decision","message":"are_snapshot","payload":{"project":"capacitor"}}'
```

### `GET /telemetry-stream` (SSE)
Streams telemetry events as they are received.

Note: `/activation-trace` is no longer served. Use `/telemetry-stream` for live SSE.

### `GET /agent-briefing?limit=200&shells=recent&shell_limit=25`
Agent-focused compact payload containing:
- summary counts + daemon/routing summary
- latest combined snapshot
- last N telemetry events
- endpoint registry

Optional query params:
- `limit` (default `200`)
- `shells` (`recent` default, `all`)
- `shell_limit` (default `25`)
- `project_path` (optional)
- `workspace_id` (optional)

## Environment Variables

- `PORT` (default: `9133`)
- `CAPACITOR_DAEMON_SOCK` (default: `~/.capacitor/daemon.sock`)
- `CAPACITOR_TELEMETRY_LIMIT` (default: `500`)
- `CAPACITOR_BRIEFING_SHELL_LIMIT` (default: `25`)

## For Coding Agents

Use Transparent UI as the local ARE observability hub:

- Canonical runbook: `.claude/docs/agent-observability-runbook.md`
- Canonical helper: `./scripts/dev/agent-observe.sh`

- `GET /daemon-snapshot` for current daemon + routing state.
- `GET /routing-rollout` for gate progression and readiness booleans.
- `GET /routing-snapshot?project_path=...` for project-scoped routing decision evidence.
- `GET /telemetry?limit=200` and `GET /telemetry-stream` for app-level events.
- `GET /agent-briefing?...` for a single compact payload.

Quick commands:

```bash
./scripts/dev/agent-observe.sh check
./scripts/dev/agent-observe.sh snapshot
./scripts/dev/agent-observe.sh briefing 200
./scripts/dev/agent-observe.sh telemetry 200
./scripts/dev/agent-observe.sh stream
```

The HTML dashboard defaults:
- snapshot: `http://localhost:9133/daemon-snapshot`
- telemetry: `http://localhost:9133/telemetry`
- live SSE: `http://localhost:9133/telemetry-stream`

This service is intentionally local and in-memory for telemetry events. If persistence is needed, extend the server to write telemetry to disk or SQLite.

## App Wiring

Swift app telemetry target:

- `CAPACITOR_TELEMETRY_URL` (default: `http://localhost:9133/telemetry`)
- `CAPACITOR_TELEMETRY_DISABLED=1` disables emission

Recommended telemetry types for ARE debugging:
- `activation_decision`
- `routing_snapshot_refresh_error`
- `daemon_health`
- `active_project_resolution`
