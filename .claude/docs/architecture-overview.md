# Architecture Overview

Detailed architecture documentation for Capacitor.

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│               Swift App (apps/swift)                        │
│               SwiftUI + 120Hz ProMotion                     │
│               Native macOS 14+                              │
└──────────────────────────┬──────────────────────────────────┘
                           │ UniFFI
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    hud-core (core/hud-core)                 │
│  Shared Rust library: projects, sessions, stats, artifacts │
└─────────────────────────────────────────────────────────────┘
```

## Swift App Architecture

The Swift app is a **native SwiftUI application** in `apps/swift/`. It communicates with the Rust core via UniFFI bindings.

### Key Files

| File | Purpose |
|------|---------|
| `Sources/Capacitor/App.swift` | SwiftUI app entry point |
| `Sources/Capacitor/ContentView.swift` | Main view with navigation |
| `Sources/Capacitor/Models/AppState.swift` | State management with HudEngine bridge |
| `Sources/Capacitor/Views/` | SwiftUI views (Projects, Artifacts, etc.) |
| `Sources/Capacitor/Theme/` | Design system and styling |
| `bindings/hud_core.swift` | Generated UniFFI Swift bindings |

### Patterns

- **State Management:** `@Observable` AppState class bridging to HudEngine
- **FFI:** UniFFI-generated Swift bindings to hud-core
- **UI Framework:** SwiftUI with 120Hz ProMotion support
- **Styling:** Native macOS design language
- **Navigation:** Tab-based with sidebar

## Rust Core Architecture

The `hud-core` library contains all business logic, exported via UniFFI for Swift consumption.

### Module Overview

The crate is organized into three layers:

```
┌─────────────────────────────────────────────────────────────┐
│                      engine.rs (Facade)                     │
│              Unified API for Swift via UniFFI               │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────┼──────────────────────────────────┐
│  Domain Modules          │                                  │
│  ┌──────────┐ ┌──────────┴───┐ ┌──────────┐ ┌──────────┐   │
│  │projects.rs│ │ sessions.rs │ │artifacts │ │ ideas.rs │   │
│  └──────────┘ └──────────────┘ └──────────┘ └──────────┘   │
│  ┌──────────┐                                              │
│  │ agents/  │ (multi-agent support)                        │
│  └──────────┘                                              │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────┼──────────────────────────────────┐
│  Infrastructure          │                                  │
│  ┌──────────┐ ┌──────────┴───┐ ┌──────────┐ ┌──────────┐   │
│  │ state/   │ │ storage.rs   │ │boundaries│ │ config   │   │
│  │ (module) │ │              │ │          │ │          │   │
│  └──────────┘ └──────────────┘ └──────────┘ └──────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Modules (in `core/hud-core/src/`)

| Module | Purpose |
|--------|---------|
| `engine.rs` | `HudEngine` facade - unified API for Swift via UniFFI |
| `types.rs` | Shared FFI types: Project, SessionState, Artifact, Plugin, Idea |
| `error.rs` | Error types (`HudError`, `HudFfiError`) and Result alias |

**Domain Modules:**

| Module | Purpose |
|--------|---------|
| `projects.rs` | Project loading, discovery, path encoding, indicators |
| `sessions.rs` | Session state detection from daemon snapshots |
| `artifacts.rs` | Skill/command/agent discovery and frontmatter parsing |
| `ideas.rs` | Idea capture, status tracking, effort estimation |
| `stats.rs` | Token usage parsing from JSONL, mtime-based caching |
| `agents/` | **Multi-agent subsystem** - AgentAdapter trait, registry, CLI adapters |

**Infrastructure Modules:**

| Module | Purpose |
|--------|---------|
| `state/` | **Session state subsystem** - daemon snapshot mapping, path normalization, cleanup |
| `storage.rs` | Path encoding + project data directory resolution |
| `boundaries.rs` | Project boundary detection (CLAUDE.md, .git, package.json, etc.) |
| `validation.rs` | Path validation, dangerous path detection |
| `config.rs` | Path resolution (`~/.claude`), config file I/O |
| `patterns.rs` | Pre-compiled regex patterns for JSONL parsing |

### The `state/` Subsystem (Daemon-First)

Session state detection follows the **sidecar philosophy**: the daemon is authoritative for state transitions, and Rust is a passive reader that maps snapshots for Swift.

```
state/
├── mod.rs        # Module overview + re-exports
├── daemon.rs     # IPC helpers (`get_sessions`, `get_health`)
├── types.rs      # SessionRecord + hook event types
├── path_utils.rs # Path normalization for matching
└── cleanup.rs    # Startup cleanup (daemon-aware)
```

**Key facts:**
- No file-based session state or lock parsing in daemon-only mode.
- Liveness is sourced from daemon snapshot fields (`is_alive`, timestamps).
- `sessions.rs` uses `state::daemon::sessions_snapshot()` to build `ProjectSessionState`.

For complete documentation, see the inline doc comments in each module file, or run `cargo doc -p hud-core --open`.

### The `agents/` Subsystem

Multi-agent support enables the app to track sessions from different coding assistant CLIs (Claude Code, Codex, Aider, etc.).

```
agents/
├── mod.rs        # AgentAdapter trait, AgentRegistry, test utilities
├── types.rs      # AgentSession, AgentState, AgentConfig, AgentType
├── claude.rs     # ClaudeAdapter - fully implemented for Claude Code
├── registry.rs   # AgentRegistry with mtime-based caching
└── stubs.rs      # Stub adapters for other CLIs (Codex, Aider, Amp, etc.)
```

**Key Types:**

```rust
pub trait AgentAdapter: Send + Sync {
    fn id(&self) -> &'static str;
    fn display_name(&self) -> &'static str;
    fn is_installed(&self) -> bool;
    fn detect_session(&self, project_path: &str) -> Option<AgentSession>;
    fn all_sessions(&self) -> Vec<AgentSession>;
    fn state_mtime(&self) -> Option<SystemTime>;
}

pub enum AgentState { Ready, Working, Waiting, Error }

pub struct AgentSession {
    pub agent_type: AgentType,
    pub state: AgentState,
    pub session_id: Option<String>,
    pub cwd: String,
    pub working_on: Option<String>,
    // ...
}
```

**Adapter pattern:** Each CLI gets an adapter. Currently only the Claude adapter is implemented and reads daemon snapshots; other CLIs are stubs (not installed).

See [Adding a New CLI Agent Guide](adding-new-cli-agent-guide.md) for implementation details.

### Key Functions

**Session Detection (`sessions.rs`):**
- `detect_session_state()` - Main entry point for Swift; returns `ProjectSessionState`

**Daemon Snapshot (`state/daemon.rs`):**
- `sessions_snapshot()` - Reads daemon `get_sessions` snapshot
- `daemon_health()` - Checks daemon health via IPC

**Path Normalization (`state/path_utils.rs`):**
- `normalize_path_for_matching()` - Canonicalize project paths for matching

**Project Boundary (`boundaries.rs`):**
- `find_project_boundary()` - Walks up to find nearest CLAUDE.md, .git, etc.
- `is_dangerous_path()` - Rejects `/`, `/Users`, `/home`, etc.

**Configuration (`config.rs`):**
- `get_claude_dir()` - Resolves `~/.claude` directory
- `load_hud_config()` / `save_hud_config()` - Pinned projects persistence

**HudEngine Facade (`engine.rs`):**
- `HudEngine::new()` - Creates engine instance
- `list_projects()`, `add_project()`, `remove_project()` - Project management
- `get_session_state()`, `get_all_session_states()` - Session queries
- `list_artifacts()`, `list_plugins()` - Artifact discovery
- `load_dashboard()` - All dashboard data in one call

**Terminal Activation (`activation.rs`):**
- `resolve_activation()` - Pure Rust function that returns an `ActivationDecision`
- Decision logic only: what action to take based on shell state + tmux context
- Execution stays in Swift (`TerminalLauncher.executeActivationAction()`)
- Principle: **Rust decides, Swift executes** (macOS APIs require Swift)

### Key Patterns

**Error Handling:**
- Functions return `Result<T, HudError>` with UniFFI error support
- File operations gracefully degrade (return empty defaults on missing files)

**Caching:**
- Stats cache uses mtime-based invalidation
- Summary cache persists generated summaries to avoid re-computation

**Atomic Writes:**
- All state files use temp file + rename for crash safety

## State Tracking Architecture

**Current approach:** Hooks track local Claude Code sessions and send events to the local daemon; Swift reads daemon snapshots.

See [ADR-001: State Tracking Approach](../../docs/architecture-decisions/001-state-tracking-approach.md) for the full decision rationale.

### Local Sessions

For interactive CLI sessions, we use Claude Code hooks:

```
User runs claude → Hooks fire → Daemon updates state.db → Swift app reads daemon snapshot
```

**Hooks configured (daemon-only):**
- `SessionStart` → state: ready
- `UserPromptSubmit` → state: working
- `PermissionRequest` → state: waiting
- `PostToolUse` → state transitions + heartbeat updates
- `Notification` (idle_prompt) → state: ready
- `Stop` → state: ready
- `PreCompact` → state: compacting
- `SessionEnd` → removes session from daemon state

**State store:** `~/.capacitor/daemon/state.db` (daemon-owned SQLite WAL)

**Hook binary:** `~/.local/bin/hud-hook`

**Architecture:** See `core/hud-hook/src/main.rs` for the hook implementation and `core/daemon/src/reducer.rs` for canonical state mapping.

## Runtime Configuration

The app uses two namespaces:

**Capacitor namespace** (`~/.capacitor/`) — owned by Capacitor:
```
~/.capacitor/
├── config.json                    # Pinned projects, settings
├── daemon.sock                    # Daemon IPC socket
├── daemon/                        # Daemon storage + logs
│   ├── state.db                   # Authoritative state store (WAL)
│   ├── daemon.stdout.log          # LaunchAgent stdout
│   └── daemon.stderr.log          # LaunchAgent stderr
├── stats-cache.json               # Cached token usage
├── summaries.json                 # Session summaries cache
├── project-summaries.json         # Project overview bullets
├── creations.json                 # Project creation progress
└── projects/{encoded-path}/       # Per-project data
    ├── ideas.md                   # Ideas for this project
    └── ideas-order.json           # Display order
```

**Claude namespace** (`~/.claude/`) — owned by Claude Code CLI, read-only for Capacitor:
```
~/.claude/
├── settings.json                  # Global Claude Code config
├── projects/                      # Session files ({encoded-path}/{sessionid}.jsonl)
└── plugins/installed_plugins.json # Plugin registry
```

For a comprehensive reference of all Claude Code disk artifacts (file formats, data structures, retention policies), see **[docs/claude-code-artifacts.md](../../docs/claude-code-artifacts.md)**.

## Key Dependencies

**Swift App:**
- SwiftUI - Native UI framework
- Foundation - Core utilities
- AppKit - macOS integration

**Rust Core:**
- UniFFI - Swift/Kotlin/Python bindings
- Serde - JSON serialization
- Regex - Pattern matching in session files
- Walkdir - Directory traversal
- Dirs - Platform-specific paths
- Chrono - Date/time handling
- Sysinfo - Process verification (PID alive checks)
