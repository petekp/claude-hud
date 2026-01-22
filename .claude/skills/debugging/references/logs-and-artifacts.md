# Logs and Artifacts

Use these paths for targeted inspection. Prefer small slices via `jq`, `rg`, `tail`, and `stat`.

## HUD / Capacitor (HUD-owned)

- `~/.capacitor/sessions.json` — v3 session state store (primary state signal).
- `~/.capacitor/hud-hook-events.jsonl` — sanitized hook event log (JSONL).
- `~/.capacitor/hud-state-snapshots/` — outputs from `scripts/state-snapshot.sh`.
- `~/.capacitor/stats-cache.json` — stats cache (if stats or activity anomalies arise).

## Claude Code (CLI-owned)

- `~/.claude/sessions/*.lock/` — lock directories (`pid`, `meta.json`) for liveness.
- `~/.claude/projects/<encoded-path>/<session-id>.jsonl` — transcript history (sensitive).
- `~/.claude/debug/` — Claude Code debug logs (see `docs/claude-code-artifacts.md`).
- `~/.claude/history.jsonl` — global command history.
- `~/.claude/shell-snapshots/`, `~/.claude/todos/`, `~/.claude/file-history/` — ancillary artifacts.

## Config and Hook Locations

- `~/.claude/settings.json` and `~/.claude/settings.local.json` — user hooks/permissions.
- `.claude/settings.json` and `.claude/settings.local.json` — project hooks/settings.
- `~/.claude/scripts/hud-state-tracker.sh` — installed hook script (compare with repo).

## Path Encoding Note

Claude Code encodes project paths as `-` separated directories in `~/.claude/projects/`.
Example: `/Users/pete/Code/app` → `-Users-pete-Code-app`.

## Env Overrides

- `HUD_HOOK_LOG_FILE` — override `~/.capacitor/hud-hook-events.jsonl`.
- `HUD_HOOK_LOG_MAX_BYTES` — log rotation size.
- `HUD_STATE_SNAPSHOT_DIR` — override snapshot output directory.

## Redaction Guidance

- Do not surface prompt bodies, tool_input/tool_response, or transcript contents.
- Extract only metadata (timestamps, events, state transitions, tool names).
