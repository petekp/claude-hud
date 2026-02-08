# Transparent UI Telemetry Hub

This directory contains the standalone debug UI and a local telemetry server that streams live app state.

The UI has two tabs:
- **Learn** — Architecture graph walkthrough with flow walkthroughs (Realtime, Dashboard, Activation)
- **Live** — Real-time debugging with daemon snapshot, unified event timeline, and activation trace scoring

## Quick Start

```bash
scripts/run-transparent-ui.sh
```

This starts the local server on `http://localhost:9133` and opens:

- `docs/transparent-ui/capacitor-interfaces-explorer.html`

## Server Endpoints

Base URL (default): `http://localhost:9133`

### `GET /activation-trace` (SSE)
Streams activation decision traces parsed from `~/.capacitor/daemon/app-debug.log`.

### `GET /daemon-snapshot`
Returns live daemon state snapshots (sessions, project_states, shell_state) by querying `~/.capacitor/daemon.sock`.

### `GET /telemetry?limit=50`
Returns the most recent telemetry events stored in memory.

### `POST /telemetry`
Append a telemetry event to the in-memory buffer.

Example:

```bash
curl -X POST http://localhost:9133/telemetry \
  -H 'Content-Type: application/json' \
  -d '{"type":"activation","message":"primary action failed","payload":{"project":"capacitor"}}'
```

### `GET /telemetry-stream` (SSE)
Streams telemetry events as they are received.

### `GET /agent-briefing?limit=200&shells=recent&shell_limit=25` (API-only)
Returns a single JSON payload with (no UI panel — agents consume this endpoint directly):
- summary counts for sessions/projects/shells/telemetry
- latest daemon snapshot (shells trimmed by default)
- last N telemetry events
- endpoint registry

Params:
- `limit` (default `200`): number of telemetry events included
- `shells` (`recent` default, `all` for full inventory)
- `shell_limit` (default `25`): max shells when `shells=recent`

## Environment Variables

- `PORT` (default: `9133`)
- `CAPACITOR_TRACE_LOG` (default: `~/.capacitor/daemon/app-debug.log`)
- `CAPACITOR_DAEMON_SOCK` (default: `~/.capacitor/daemon.sock`)
- `CAPACITOR_TELEMETRY_LIMIT` (default: `500`)
- `CAPACITOR_BRIEFING_SHELL_LIMIT` (default: `25`)

## For Coding Agents

Agents can treat this as the system telemetry hub. Useful calls:

- `GET /daemon-snapshot` to understand current state.
- `GET /telemetry?limit=200` to pull recent events.
- Subscribe to `GET /telemetry-stream` for live event flow.
- `GET /agent-briefing?limit=200&shells=recent&shell_limit=25` for a compact payload.
- `GET /agent-briefing?shells=all` if you need the full shell inventory.

This is intentionally local + transient (in-memory). If you need persistence, extend the server to write events to disk or to the daemon DB.

## App Wiring

The Swift app now emits structured telemetry automatically. Configure with:

- `CAPACITOR_TELEMETRY_URL` (default: `http://localhost:9133/telemetry`)
- `CAPACITOR_TELEMETRY_DISABLED=1` to turn it off

Activation decisions, IPC errors, and daemon lifecycle errors are posted automatically.
