# Capacitor Daemon IPC (v1)

This document defines the local IPC contract for `capacitor-daemon`.

## Transport

- Socket path: `~/.capacitor/daemon.sock`
- Socket directory permissions: `~/.capacitor` is enforced to `0700`
- Socket file permissions: `~/.capacitor/daemon.sock` is enforced to `0600`
- Peer auth policy: same local user only (`peer_uid == daemon_euid`)
- Encoding: one JSON request per connection, optional trailing newline
- Response: one JSON object, newline-terminated
- Protocol version: `1`

## Request Envelope

```json
{
  "protocol_version": 1,
  "method": "get_health",
  "id": "req-123",
  "params": {}
}
```

Fields:
- `protocol_version` (required): must be `1`
- `method` (required): one of the methods listed below
- `id` (optional): echoed in responses
- `params` (optional): method-specific payload

## Response Envelope

Success:

```json
{
  "ok": true,
  "id": "req-123",
  "data": {}
}
```

Error:

```json
{
  "ok": false,
  "id": "req-123",
  "error": {
    "code": "invalid_params",
    "message": "project_path is required"
  }
}
```

## Methods

### `get_health`

Returns daemon runtime metadata plus observability snapshots.

Response shape:

```json
{
  "status": "ok",
  "pid": 12345,
  "version": "0.1.27",
  "protocol_version": 1,
  "dead_session_reconcile_interval_secs": 15,
  "security": {
    "peer_auth_mode": "same_user",
    "rejected_connections": 4
  },
  "runtime": {
    "active_connections": 2,
    "max_active_connections": 64,
    "build_hash": "abc123def456"
  },
  "dead_session_reconcile": {
    "startup": {
      "runs": 1,
      "repaired_sessions": 0,
      "last_run_at": "2026-02-14T15:00:00Z",
      "last_repair_at": null
    }
  },
  "hem_shadow": {},
  "routing": {
    "enabled": false,
    "dual_run_enabled": true,
    "snapshots_emitted": 1000,
    "dual_run_comparisons": 1000,
    "legacy_vs_are_status_mismatch": 1,
    "legacy_vs_are_target_mismatch": 6,
    "confidence_high": 900,
    "confidence_medium": 80,
    "confidence_low": 20,
    "last_snapshot_at": "2026-02-14T15:00:00Z",
    "rollout": {
      "agreement_gate_target": 0.995,
      "min_comparisons_required": 1000,
      "min_window_hours_required": 168,
      "comparisons": 1000,
      "volume_gate_met": true,
      "window_gate_met": true,
      "status_agreement_rate": 0.999,
      "target_agreement_rate": 0.994,
      "first_comparison_at": "2026-02-01T09:00:00Z",
      "last_comparison_at": "2026-02-14T09:00:00Z",
      "window_elapsed_hours": 312,
      "status_gate_met": true,
      "target_gate_met": false,
      "status_row_default_ready": true,
      "launcher_default_ready": false
    }
  },
  "backoff": {}
}
```

Notes:
- `security.peer_auth_mode`: currently `"same_user"` and enforced on every socket connection.
- `security.rejected_connections`: count of rejected peer-auth + overload connection attempts since daemon start.
- `runtime.active_connections`: currently active in-flight socket request handlers.
- `runtime.max_active_connections`: hard connection ceiling; requests above this return `too_many_connections`.
- `runtime.build_hash`: daemon build identity (`CAPACITOR_DAEMON_BUILD_HASH`, fallback to package version).
- `routing.rollout.status_row_default_ready`: daemon-computed readiness signal for status-row cutover health.
- `routing.rollout.launcher_default_ready`: daemon-computed readiness signal for launcher cutover health.
- Both gates require:
  - `routing.feature_flags.dual_run=true`
  - `routing.rollout.comparisons >= routing.rollout.min_comparisons_required`
  - `routing.rollout.window_elapsed_hours >= routing.rollout.min_window_hours_required`
  - agreement rate(s) meeting `routing.rollout.agreement_gate_target`.
- Cleanup policy distinction:
  - Daemon default-ready booleans are operational readiness evidence used during rollout.
  - Legacy path deletion is an operational policy in the ARE runbook and requires 14 consecutive days of sustained gate readiness with `dual_run_enabled=true`, with counter resets on regressions.
- Swift runtime policy:
  - Status row and launcher consume daemon routing snapshots directly.
  - Swift shell-derived routing/shadow-compare fallback is no longer used.

### `get_shell_state`

Returns shell CWD telemetry snapshot.

```json
{
  "version": 1,
  "shells": {
    "1234": {
      "cwd": "/Users/pete/Code/project",
      "tty": "/dev/ttys003",
      "parent_app": "tmux",
      "tmux_session": "dev",
      "tmux_client_tty": "/dev/ttys004",
      "updated_at": "2026-01-30T12:00:00Z"
    }
  }
}
```

### `get_process_liveness`

Request:

```json
{
  "protocol_version": 1,
  "method": "get_process_liveness",
  "params": { "pid": 12345 }
}
```

Response (found):

```json
{
  "pid": 12345,
  "proc_started": 1706570812,
  "current_start_time": 1706570812,
  "last_seen_at": "2026-01-30T00:03:00Z",
  "is_alive": true,
  "identity_matches": true
}
```

Response (not found):

```json
{
  "found": false,
  "pid": 12345
}
```

### `get_routing_snapshot`

Request:

```json
{
  "protocol_version": 1,
  "method": "get_routing_snapshot",
  "params": {
    "project_path": "/Users/pete/Code/capacitor",
    "workspace_id": "workspace-1"
  }
}
```

`workspace_id` is optional. If omitted, daemon resolves workspace from `project_path`.

Validation:
- `project_path` must be non-empty.
- Dangerous root-like paths are rejected.
- Existing paths are canonicalized and must remain within the current user's home directory.
- Violations return `invalid_project_path`.

Response:

```json
{
  "version": 1,
  "workspace_id": "workspace-1",
  "project_path": "/Users/pete/Code/capacitor",
  "status": "attached",
  "target": {
    "kind": "tmux_session",
    "value": "caps"
  },
  "confidence": "high",
  "reason_code": "TMUX_CLIENT_ATTACHED",
  "reason": "Attached tmux client detected for this workspace.",
  "evidence": [
    {
      "evidence_type": "tmux_client",
      "value": "/dev/ttys015",
      "age_ms": 120,
      "trust_rank": 1
    }
  ],
  "updated_at": "2026-02-14T15:00:00Z"
}
```

### `get_routing_diagnostics`

Request:

```json
{
  "protocol_version": 1,
  "method": "get_routing_diagnostics",
  "params": {
    "project_path": "/Users/pete/Code/capacitor"
  }
}
```

Uses the same `project_path` validation and `invalid_project_path` error semantics as `get_routing_snapshot`.

Response:

```json
{
  "snapshot": {},
  "signal_ages_ms": {
    "tmux_client": 250
  },
  "candidate_targets": [
    {
      "kind": "tmux_session",
      "value": "caps"
    }
  ],
  "conflicts": [],
  "scope_resolution": "path_exact"
}
```

### `get_config`

Returns daemon routing runtime config view.

```json
{
  "tmux_signal_fresh_ms": 5000,
  "shell_signal_fresh_ms": 600000,
  "shell_retention_hours": 24,
  "tmux_poll_interval_ms": 1000
}
```

### `get_sessions`

Returns current daemon session records.

### `get_project_states`

Returns project-level synthesized state records.

Project state payload includes:
- `session_id`: representative session that owns the resolved project state.
- `latest_session_id`: most recently updated session for the project (used for recency-sensitive UX).

### `get_activity`

Returns activity stream rows. Supports optional `session_id` and `limit`.

### `get_tombstones`

Returns tombstoned sessions.

### `event`

Writes a single event envelope to the daemon.

Event types:
- `session_start`
- `user_prompt_submit`
- `pre_tool_use`
- `post_tool_use`
- `post_tool_use_failure`
- `permission_request`
- `pre_compact`
- `notification`
- `subagent_start`
- `subagent_stop`
- `stop`
- `teammate_idle`
- `task_completed`
- `session_end`
- `shell_cwd`

Validation rules:
- `event_id` required, max 128 chars
- `recorded_at` required, RFC3339
- Session events require `session_id` and `cwd`
- `shell_cwd` requires `pid`, `cwd`, `tty`
- `notification` requires `notification_type`
- `stop` requires `stop_hook_active`

## Operational Notes

- Connection flood behavior:
  - Hard in-flight cap is `64` handlers.
  - Excess connections are rejected immediately with `too_many_connections`.
  - Daemon remains responsive after overload once capacity is available.
- Read timeout behavior:
  - Requests must arrive promptly after connect.
  - Idle clients receive `read_timeout`.
- Replay behavior:
  - Catch-up cursor is durable (`daemon_meta.last_applied_event_rowid`).
  - Replay selection is rowid-ordered, not timestamp-window ordered.
  - New rowids are processed exactly once after restart, including slight out-of-order timestamps.
- Local daemon log policy:
  - LaunchAgent stdout/stderr logs live under `~/.capacitor/daemon/`.
  - App-side startup now trims oversized daemon stdout/stderr logs before registration/kickstart.

## Error Codes

- `empty_request`
- `read_timeout`
- `read_error`
- `request_too_large`
- `invalid_json`
- `protocol_mismatch`
- `unknown_method`
- `invalid_params`
- `invalid_event_id`
- `invalid_timestamp`
- `invalid_pid`
- `missing_field`
- `unauthorized_peer`
- `too_many_connections`
- `invalid_project_path`
- `routing_error`
- `serialization_error`
- `liveness_error`
- `sessions_error`
- `project_states_error`
- `activity_error`
- `tombstone_error`
