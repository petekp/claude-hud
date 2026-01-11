# HUD Daemon

**Status:** Reserved for future remote/mobile client integration

The HUD Daemon provides precise state tracking by spawning Claude with `--output-format stream-json` and parsing the structured message stream. This approach is based on Happy Engineering's battle-tested implementation.

## Current Architecture Decision

**We're using hooks for local TUI sessions, not the daemon.**

Why? Claude's `--output-format stream-json` replaces the interactive TUI with JSON output. You can't have both Claude's native TUI and structured JSON from the same process.

For local desktop use, hooks provide "good enough" state tracking without sacrificing the TUI experience.

See [ADR-001: State Tracking Approach](../../docs/architecture-decisions/001-state-tracking-approach.md) for the full rationale.

## When to Use the Daemon

Use the daemon when:
- Building mobile client relay integration
- Building programmatic/scripted Claude interactions
- Testing state tracking precision
- Implementing remote session support

## Building

```bash
cd apps/daemon
npm install
npm run build
```

## Usage

```bash
# Run with a prompt (JSON output, no TUI)
hud-claude-daemon -p "explain this code"

# Run interactive session (JSON output)
hud-claude-daemon

# Resume a session
hud-claude-daemon --resume <session-id>
```

## Architecture

```
hud-claude-daemon
       │
       ▼
  query() spawns Claude
  with --output-format stream-json
       │
       ▼
  readline parses JSON messages
       │
  ┌────┴────┐
  ▼         ▼
Formatted  StateTracker ───▶ ~/.claude/hud-session-states.json
Output     RelayClient  ───▶ (future: WebSocket relay)
```

## Key Components

| Component | File | Purpose |
|-----------|------|---------|
| SDK Types | `src/sdk/types.ts` | Message type definitions |
| Query | `src/sdk/query.ts` | Spawns Claude, parses stream |
| Stream | `src/sdk/stream.ts` | Async message stream |
| StateTracker | `src/daemon/state.ts` | Writes to state file |
| RelayClient | `src/daemon/relay.ts` | Placeholder for remote sync |
| CLI | `src/cli/index.ts` | Entry point |

## Future Work

When mobile client development begins:

1. Implement WebSocket relay server
2. Connect RelayClient to relay server
3. Consider mode-switching loop (like Happy) if seamless local/remote is needed
