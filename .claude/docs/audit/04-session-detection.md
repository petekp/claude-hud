# Subsystem Audit: Session Detection API

**Files reviewed**
- `core/hud-core/src/sessions.rs`
- `core/hud-core/src/agents/claude.rs`
- `core/hud-core/src/state/daemon.rs`

**Purpose**
Reads session snapshots from the daemon and maps them to `ProjectSessionState` and `AgentSession` for consumers.

**Notes**
- Session detection uses daemon snapshots as the sole source of truth.
- Path normalization is handled in `state/path_utils.rs` for consistent matching.

**Findings**
No issues found in this subsystem.

