# Adding a New CLI Agent to Claude HUD

> A step-by-step tutorial for integrating a new coding assistant CLI (like Aider, Codex, or Cursor) into Claude HUD's multi-agent tracking system.
> Estimated implementation time: 4 milestones, ~2-3 hours of focused work

## Overview

Claude HUD uses an **adapter pattern** to support multiple CLI coding assistants. Each agent has its own adapter that knows how to detect installation, find session state files, and translate that agent's internal state into HUD's universal state model.

This tutorial will teach you how to add a new agent by implementing the `AgentAdapter` trait. By the end, you'll understand:

- The adapter trait and its contract
- How to detect if the CLI is installed
- How to find and parse session state
- How to map agent-specific states to universal states
- How to test your adapter with fixtures
- How to register your adapter in the system

## Background & Context

### The Multi-Agent Architecture

Claude HUD tracks coding assistant sessions across multiple projects. Originally built for Claude Code, the system was refactored to support any CLI agent using a Starship-style adapter pattern.

The key insight: every CLI agent tracks session state *somewhere*. Claude Code uses `~/.claude/hud-session-states-v2.json` and lock files. Aider might use `~/.aider/`. Codex might use a different approach entirely. The adapter pattern abstracts these differences.

**Core files:**
- `core/hud-core/src/agents/mod.rs:17-46` — The `AgentAdapter` trait definition
- `core/hud-core/src/agents/types.rs` — Universal types (`AgentState`, `AgentSession`, `AgentType`)
- `core/hud-core/src/agents/registry.rs` — Registry that manages all adapters
- `core/hud-core/src/agents/claude.rs` — Reference implementation (most complex)
- `core/hud-core/src/agents/stubs.rs` — Stub adapters for unimplemented agents

### The Universal State Model

All agents map to four universal states:

| Universal State | Meaning | Example Source States |
|-----------------|---------|----------------------|
| `Idle` | No active session | No state file, CLI not running |
| `Ready` | Session exists, waiting for input | Claude's "ready", idle prompts |
| `Working` | Actively processing | API calls in flight, thinking |
| `Waiting` | Blocked on user action | Permission prompts, confirmations |

Your adapter translates the agent's internal state representation to these universal states.

### Session Identity

Sessions are identified by a composite key: `(agent_type, session_id)`. Session IDs are only unique within an agent type—two different agents could have the same session ID.

The `AgentSession` struct (`types.rs:71-85`) carries:
- `agent_type` — Which agent (Claude, Codex, etc.)
- `agent_name` — Human-readable name
- `state` — Universal state
- `session_id` — Agent-specific session identifier
- `cwd` — Working directory of the session
- `detail` — Optional state detail (e.g., "compacting context")
- `working_on` — What the session is currently doing
- `updated_at` — RFC3339 timestamp of last update

## Technical Landscape

### State Detection Flow

When the HUD needs to know an agent's state for a project:

```
HudEngine.get_agent_sessions(project_path)
    → AgentRegistry.detect_all_sessions(project_path)
        → For each installed adapter:
            → adapter.detect_session(project_path)
                → Check if session exists at this path
                → Parse state from agent's state files
                → Map to AgentSession with universal state
```

### The AgentAdapter Trait

```rust
pub trait AgentAdapter: Send + Sync {
    // REQUIRED: Unique lowercase identifier
    fn id(&self) -> &'static str;

    // REQUIRED: Human-readable display name
    fn display_name(&self) -> &'static str;

    // REQUIRED: Is this CLI installed on the system?
    fn is_installed(&self) -> bool;

    // REQUIRED: Detect session at this project path
    fn detect_session(&self, project_path: &str) -> Option<AgentSession>;

    // OPTIONAL: One-time initialization
    fn initialize(&self) -> Result<(), AdapterError> { Ok(()) }

    // OPTIONAL: Return ALL known sessions
    fn all_sessions(&self) -> Vec<AgentSession> { vec![] }

    // OPTIONAL: State file mtime for cache invalidation
    fn state_mtime(&self) -> Option<SystemTime> { None }
}
```

### Registration in the Registry

New adapters are registered in `registry.rs:186-195`:

```rust
fn create_adapters() -> Vec<Arc<dyn AgentAdapter>> {
    vec![
        Arc::new(ClaudeAdapter::new()),
        Arc::new(CodexAdapter::new()),
        Arc::new(AiderAdapter::new()),
        // ... your adapter goes here
    ]
}
```

### The AgentType Enum

You'll need to add your agent to the `AgentType` enum (`types.rs:24-33`):

```rust
pub enum AgentType {
    Claude,
    Codex,
    Aider,
    // ... your type here
    Other,
}
```

This is a UniFFI-exposed enum, so it must be flat (no data variants).

## Design Rationale

### Why Adapters Over Generics?

We use trait objects (`Arc<dyn AgentAdapter>`) rather than generics because:
1. **Dynamic registration** — Adapters are created at runtime
2. **UniFFI compatibility** — Trait objects work well with FFI
3. **Simplicity** — No complex type parameters

### Why Require `Send + Sync`?

The registry is shared across threads (SwiftUI updates from background). All adapters must be thread-safe.

### Why Optional Methods?

Not all agents support all features:
- `all_sessions()` — Some agents don't persist session lists
- `state_mtime()` — Some agents don't have a single state file
- `initialize()` — Most adapters don't need startup work

Default implementations return empty/None, so you only implement what makes sense.

## Implementation Milestones

### Milestone 1: Add Agent Type and Stub Adapter

**Objective**: Get your new agent recognized by the system, even if it always reports "not installed."

**Why this first**: Establishes the skeleton that all other work builds on. You can verify the registry sees your agent before implementing detection logic.

**Files to create/modify**:
- `core/hud-core/src/agents/types.rs` — Add to `AgentType` enum
- `core/hud-core/src/agents/stubs.rs` — Add stub using the macro (OR create new file)
- `core/hud-core/src/agents/mod.rs` — Export your adapter
- `core/hud-core/src/agents/registry.rs` — Register the adapter

**Implementation approach**:

1. **Add to AgentType enum** (`types.rs:24-33`):
   Add your variant before `Other`. Update both `id()` and `display_name()` match arms.

2. **Create stub adapter** (choose one approach):

   **Option A: Use the stub macro** (`stubs.rs`) — Good for getting started:
   ```rust
   stub_adapter!(YourAdapter, "youragent", "Your Agent Name");
   ```

   **Option B: Create dedicated file** — Better for full implementations:
   Create `core/hud-core/src/agents/youragent.rs` with a struct and basic trait impl.

3. **Export from mod.rs** (`mod.rs:6-9`):
   Add `pub use` for your adapter.

4. **Register in create_adapters()** (`registry.rs:186-195`):
   Add `Arc::new(YourAdapter::new())` to the vector.

**Verification**:
```bash
# Run unit tests
cargo test -p hud-core agents::

# Check that your agent appears in the list
cargo test -p hud-core test_registry_creates_all_adapters -- --nocapture
```

**Checkpoint**: Your agent should appear in `AgentType` and the registry should create it, though `is_installed()` returns `false`.

---

### Milestone 2: Implement Installation Detection

**Objective**: Accurately detect whether your agent's CLI is installed on the user's system.

**Why this second**: Installation detection is the gate for all other functionality. If we can't detect the CLI, we don't try to detect sessions.

**Files to modify**:
- Your adapter file (stub or dedicated)

**Implementation approach**:

Think about how to detect your agent:

1. **Config directory exists** (most common):
   ```rust
   fn is_installed(&self) -> bool {
       let dir = dirs::home_dir()
           .map(|h| h.join(".youragent"))
           .and_then(|d| std::fs::metadata(&d).ok())
           .map(|m| m.is_dir())
           .unwrap_or(false)
   }
   ```

2. **Binary is in PATH**:
   ```rust
   fn is_installed(&self) -> bool {
       std::process::Command::new("youragent")
           .arg("--version")
           .output()
           .map(|o| o.status.success())
           .unwrap_or(false)
   }
   ```

3. **Combination** — Config dir AND binary:
   Check both to be more confident.

**Important**: `is_installed()` must:
- Never panic (return `false` on any error)
- Be reasonably fast (called on every refresh)
- Be thread-safe

**Verification**:
```bash
# If you have the CLI installed:
cargo test -p hud-core test_is_installed -- --nocapture

# Manual verification in REPL-style:
cargo run -p hud-core --bin state-check 2>&1 | grep -i youragent
```

**Checkpoint**: If the CLI is installed on your machine, `is_installed()` returns `true`. Otherwise `false`.

---

### Milestone 3: Implement Session Detection

**Objective**: Parse your agent's state files and detect active sessions.

**Why this third**: This is the core functionality—actually reading state and returning `AgentSession` objects.

**Files to modify**:
- Your adapter file
- Create test fixtures in `core/hud-core/tests/fixtures/agents/youragent/`

**Implementation approach**:

Research your agent's state format:
1. Where does it store session state? (`~/.youragent/`, `~/.config/youragent/`, etc.)
2. What format? (JSON, YAML, plain text, database?)
3. How does it track working directory?
4. How does it represent states? (strings, numbers, booleans?)

Then implement:

```rust
fn detect_session(&self, project_path: &str) -> Option<AgentSession> {
    // 1. Find state file
    let state_file = self.get_state_file_path()?;

    // 2. Read and parse
    let content = std::fs::read_to_string(&state_file).ok()?;
    let state: YourStateFormat = serde_json::from_str(&content).ok()?;

    // 3. Find session matching this project path
    let session = state.sessions.iter()
        .find(|s| s.cwd == project_path || project_path.starts_with(&s.cwd))?;

    // 4. Map to universal state
    let universal_state = self.map_state(session.state);

    // 5. Build AgentSession
    Some(AgentSession {
        agent_type: AgentType::YourAgent,
        agent_name: self.display_name().to_string(),
        state: universal_state,
        session_id: Some(session.id.clone()),
        cwd: session.cwd.clone(),
        detail: self.state_detail(session.state),
        working_on: session.working_on.clone(),
        updated_at: Some(session.updated_at.clone()),
    })
}
```

**State mapping guidance**:

| Your Agent's State | Maps To |
|-------------------|---------|
| "idle", "inactive", nothing | `AgentState::Idle` |
| "ready", "waiting_input" | `AgentState::Ready` |
| "running", "thinking", "processing" | `AgentState::Working` |
| "permission", "blocked", "paused" | `AgentState::Waiting` |

**Create test fixtures** in `core/hud-core/tests/fixtures/agents/youragent/`:

```
tests/fixtures/agents/youragent/
├── working/
│   └── state.json    # A session in working state
├── multiple/
│   └── state.json    # Multiple sessions
├── corrupted/
│   └── state.json    # Invalid JSON
└── empty/
    └── state.json    # Valid but no sessions
```

Example fixture (`working/state.json`):
```json
{
  "sessions": [{
    "id": "test-session-123",
    "state": "running",
    "cwd": "/Users/test/project",
    "updated_at": "2024-01-15T10:30:00Z"
  }]
}
```

**Verification**:
```bash
# Run your adapter's tests
cargo test -p hud-core agents::youragent

# Run fixture tests
cargo test -p hud-core agent_fixtures -- --nocapture
```

**Checkpoint**: Given a valid state file, `detect_session("/path/to/project")` returns the correct `AgentSession`.

---

### Milestone 4: Implement Optional Methods & Polish

**Objective**: Add `all_sessions()`, `state_mtime()`, and comprehensive tests.

**Why last**: These are enhancements once core detection works.

**Files to modify**:
- Your adapter file
- `core/hud-core/tests/agent_fixtures.rs` — Add fixture tests

**Implementation approach**:

1. **`all_sessions()`** — Return every known session:
   ```rust
   fn all_sessions(&self) -> Vec<AgentSession> {
       let state_file = self.get_state_file_path()?;
       let content = std::fs::read_to_string(&state_file).ok()?;
       let state: YourStateFormat = serde_json::from_str(&content).ok()?;

       state.sessions.iter()
           .map(|s| self.to_agent_session(s))
           .collect()
   }
   ```

2. **`state_mtime()`** — Enable cache invalidation:
   ```rust
   fn state_mtime(&self) -> Option<SystemTime> {
       let state_file = self.get_state_file_path()?;
       std::fs::metadata(&state_file).ok()?.modified().ok()
   }
   ```

3. **Add comprehensive tests**:

   In your adapter file, test:
   - State mapping for all states
   - `is_installed()` both cases
   - `detect_session()` with various paths
   - Handling of corrupted state
   - Handling of missing files

   In `agent_fixtures.rs`, add tests like:
   ```rust
   #[test]
   fn test_youragent_parse_working_state() {
       let adapter = YourAdapter::with_config_dir(fixture_path("working"));
       let sessions = adapter.all_sessions();
       assert_eq!(sessions.len(), 1);
       assert_eq!(sessions[0].state, AgentState::Working);
   }
   ```

4. **Update integration tests** in `tests/registry_integration.rs`:
   - Verify your adapter is created
   - Verify it can be disabled via config

**Verification**:
```bash
# All agent tests
cargo test -p hud-core agents::

# All fixture tests
cargo test -p hud-core agent_fixtures

# Integration tests
cargo test -p hud-core --test registry_integration

# Full test suite
cargo test -p hud-core
```

**Checkpoint**: All tests pass. The registry shows your agent. Cache invalidation works when state files change.

## Testing Strategy

### Unit Tests (in adapter file)

Test each method in isolation:
- State mapping (all cases)
- Installation detection (both installed and not)
- Path matching logic
- Error handling (corrupted files, missing files)

### Fixture Tests (in `tests/agent_fixtures.rs`)

Test parsing real-ish state files:
- Valid state files with different states
- Multiple sessions
- Corrupted/invalid files (should not panic)
- Empty state (valid but no sessions)
- Missing directory

### Integration Tests (in `tests/registry_integration.rs`)

Test the adapter in the registry:
- Appears in installed list when installed
- Can be disabled via config
- Respects agent ordering
- Sessions are found via registry APIs

### Manual Testing

```bash
# Run the state-check binary to see all agents
cargo run -p hud-core --bin state-check

# Verify your agent appears in "Active Locks" or similar output
# Test with real projects where your CLI is running
```

## Risks & Mitigations

### File Format Changes

**Risk**: The agent updates and changes its state file format.

**Mitigation**:
- Check for version field if available
- Log warnings (don't crash) on parse errors
- Return empty/None rather than panic

### Performance

**Risk**: Reading state files on every refresh could be slow.

**Mitigation**:
- Implement `state_mtime()` for cache invalidation
- The registry caches `all_sessions()` results
- Only refresh when mtime changes

### Thread Safety

**Risk**: Concurrent access to state files.

**Mitigation**:
- The trait requires `Send + Sync`
- Read-only access to state files
- No internal mutable state (or use `RwLock` if needed)

### Missing CLI

**Risk**: User doesn't have the CLI installed.

**Mitigation**:
- `is_installed()` returns `false`
- Registry filters out uninstalled adapters
- No errors shown for missing agents

## Going Further

### Future Enhancements

1. **Lock file detection** — Like Claude, detect active processes via lock files
2. **Real-time updates** — Watch state files for changes
3. **Rich metadata** — Parse additional fields (token usage, context length)
4. **State history** — Track state transitions over time

### UniFFI Exposure

If you need to expose new agent-specific data to Swift:
1. Add to `AgentSession` struct in `types.rs`
2. Rebuild UniFFI bindings
3. Update Swift code to use new fields

### Configuration

Users can configure agents in their HUD config:
```json
{
  "disabled": ["youragent"],
  "agent_order": ["claude", "youragent", "aider"]
}
```

## References

### Key Files

| File | Purpose |
|------|---------|
| `core/hud-core/src/agents/mod.rs` | Trait definition, exports |
| `core/hud-core/src/agents/types.rs` | `AgentType`, `AgentSession`, `AgentState` |
| `core/hud-core/src/agents/claude.rs` | Reference implementation (study this!) |
| `core/hud-core/src/agents/stubs.rs` | Stub macro for quick adapters |
| `core/hud-core/src/agents/registry.rs` | Registration and caching |
| `core/hud-core/tests/agent_fixtures.rs` | Fixture test examples |
| `core/hud-core/tests/fixtures/agents/claude/` | Example fixtures |

### Patterns to Follow

Study `claude.rs` for:
- How to structure the adapter struct
- How to implement `with_config_dir()` for testing
- State mapping with detailed explanations
- Error handling that doesn't panic
- Comprehensive unit tests

### External Resources

- UniFFI documentation: https://mozilla.github.io/uniffi-rs/
- Serde JSON parsing: https://serde.rs/
- Rust file system operations: https://doc.rust-lang.org/std/fs/
