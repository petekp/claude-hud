# Capacitor Architecture Deep Dive

**For TypeScript/JavaScript Engineers**

*Last updated: February 4, 2026*

---

## Table of Contents

1. [What is Capacitor?](#what-is-capacitor)
2. [High-Level Architecture](#high-level-architecture)
3. [The Three Layers](#the-three-layers)
4. [Key Systems Deep Dive](#key-systems-deep-dive)
5. [Code Organization](#code-organization)
6. [Data Flow](#data-flow)
7. [Development Workflows](#development-workflows)
8. [Common Patterns](#common-patterns)
9. [Navigation Guide](#navigation-guide)

---

## What is Capacitor?

Capacitor is a **native macOS dashboard** that provides real-time visibility into Claude Code sessions across all your projects. Think of it as a mission control center for AI pair programming.

### The Core Problem

When working with Claude Code across multiple projects, you have no easy way to:
- See which projects Claude is currently active in
- Monitor session states without switching terminal windows
- Track token usage and model distribution
- Capture ideas without breaking flow
- Quickly switch between active projects

### The Solution

Capacitor is a **sidecar app** that:
- Reads from your existing `~/.claude/` installation (no separate API key needed)
- Tracks session state via Claude Code hooks
- Provides a unified dashboard for all projects
- Offers ambient awareness of Claude's activity

**Key Design Principle**: Capacitor is a sidecar, not a replacement. It leverages Claude Code's existing infrastructure rather than duplicating it.

---

## High-Level Architecture

Capacitor uses a **three-layer architecture**:

```
┌─────────────────────────────────────────────┐
│          Swift UI Layer (SwiftUI)           │  ← User Interface
│  • Views, State Management, Animations      │
└─────────────────────────────────────────────┘
                      ↕
          UniFFI Bridge (Generated)
                      ↕
┌─────────────────────────────────────────────┐
│      Rust Core Layer (hud-core crate)       │  ← Business Logic
│  • Session Detection, Project Management    │
│  • Stats Parsing, Idea Capture              │
└─────────────────────────────────────────────┘
                      ↕
┌─────────────────────────────────────────────┐
│    Daemon + Hook System (Unix Sockets)      │  ← Real-time State
│  • Hook Binary, Daemon Process, IPC         │
└─────────────────────────────────────────────┘
```

### Why This Design?

1. **Rust for Core Logic**
   - Type safety for complex state management
   - Zero-cost abstractions for performance
   - Easy FFI integration via UniFFI

2. **UniFFI for the Bridge**
   - Automatic Swift binding generation
   - Type-safe across language boundaries
   - Minimal boilerplate

3. **Swift for UI**
   - Native macOS experience
   - Declarative SwiftUI for reactive UIs
   - Access to platform APIs (Accessibility, AppleScript, etc.)

---

## The Three Layers

### Layer 1: Swift UI (apps/swift/)

**What it does**: Renders UI, manages user interactions, orchestrates app lifecycle.

**Key Components**:

```swift
// Entry point - sets up the app
CapacitorApp (App.swift)
  ↓
// Global app state
AppState (Models/AppState.swift)
  - Projects list
  - Session states
  - Configuration
  - Timers for polling
  ↓
// Views
Views/
  ├── Projects/        // Project cards, details, dock layout
  ├── Settings/        // Configuration UI
  ├── Footer/          // Status bar, actions
  └── Setup/           // Onboarding flow
```

**State Management Pattern**:
- `AppState` is the `ObservableObject` that coordinates the app.
- State is split into focused managers:
  - `SessionStateManager` (daemon session state + flash detection)
  - `ShellStateStore` (`@Observable`, polls daemon for shell CWD state)
  - `ProjectDetailsManager` (ideas + sensemaking + idea order)
- Views observe `@Published` values and read manager-provided accessors.

**Polling Strategy**:
- **Every ~2s**: `refreshSessionStates()` + `checkIdeasFileChanges()` via the staleness timer.
- **Every ~10s**: hook diagnostic refresh.
- **Every ~16s**: daemon health check.
- **Every ~30s**: dashboard/stats refresh (`loadDashboard()`).
- **Every ~2s**: shell CWD polling in `ShellStateStore`.

**Example Flow** (conceptual):
```swift
final class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var dashboard: DashboardData?

    let sessionStateManager = SessionStateManager()
    let projectDetailsManager = ProjectDetailsManager()
    private var engine: HudEngine?

    func loadDashboard() {
        dashboard = try? engine?.loadDashboard()
        projects = dashboard?.projects ?? []
        sessionStateManager.refreshSessionStates(for: projects)
        projectDetailsManager.loadAllIdeas(for: projects)
    }
}
```

### Layer 2: UniFFI Bridge (core/hud-core/uniffi-bindgen.rs)

**What it does**: Automatically generates Swift bindings from Rust code.

**Magic Annotations**:
```rust
// Rust side - expose to Swift
#[derive(uniffi::Record)]
pub struct Project {
    pub path: String,
    pub name: String,
    pub last_active: Option<String>,
}

#[uniffi::export]
impl HudEngine {
    pub fn list_projects(&self) -> Result<Vec<Project>, HudFfiError> {
        load_projects_with_storage(&self.storage)
    }
}
```

This generates Swift code like:
```swift
// Auto-generated Swift
public struct Project {
    public var path: String
    public var name: String
    public var lastActive: String?
}

public class HudEngine {
    public func listProjects() throws -> [Project]
}
```

**Error Handling**:
- Rust `Result<T, HudFfiError>` becomes Swift `throws`
- Custom error types map across the boundary
- No need to write manual marshalling

**Build Process**:
1. `cargo build -p hud-core --release` compiles Rust
2. UniFFI generates Swift bindings at build time
3. Swift compiler links against the Rust dylib
4. Result: Type-safe, zero-overhead FFI

### Layer 3: Rust Core (core/hud-core/)

**What it does**: Persistent data + computation (projects, stats, ideas, config, activation logic).
Real-time session state and shell CWD data come from the daemon and are merged in Swift.

**Design Principles**:
- **Synchronous**: No async runtime (clients can wrap if needed)
- **Not thread-safe**: Clients provide their own locks (`Mutex`, `Arc`)
- **Graceful degradation**: Missing files return defaults, not errors
- **Single source of truth**: All clients (Swift, TUI, future mobile) share this

**Main Entry Point**:
```rust
// The facade for all operations
pub struct HudEngine {
    storage: StorageConfig,           // Where to find ~/.capacitor and ~/.claude
    agent_registry: Arc<AgentRegistry>, // Agent adapters (Claude + stubs)
}

impl HudEngine {
    pub fn new() -> Result<Self, HudFfiError> { /* ... */ }
    
    // Projects
    pub fn list_projects(&self) -> Result<Vec<Project>, HudFfiError> { /* ... */ }
    pub fn add_project(&self, path: String) -> Result<(), HudFfiError> { /* ... */ }
    
    // Sessions
    pub fn get_all_session_states(&self) -> Result<HashMap<String, ProjectSessionState>, HudFfiError> { /* ... */ }
    
    // Ideas
    pub fn capture_idea(&self, project_path: String, idea_text: String) -> Result<String, HudFfiError> { /* ... */ }
    pub fn load_ideas(&self, project_path: String) -> Result<Vec<Idea>, HudFfiError> { /* ... */ }
    
    // Stats
    pub fn get_project_stats(&self, project_path: &str) -> Result<ProjectStats, HudFfiError> { /* ... */ }
}
```

---

## Key Systems Deep Dive

### 1. Hook-Based Session Tracking

**The Problem**: How do we know what Claude is doing in real-time without polling files constantly?

**The Solution**: Claude Code has a hooks system that fires events at key lifecycle points. Capacitor installs a hook binary that forwards these events to a daemon.

**Flow**:
```
Claude Code Session
  ↓
Hook Event Fired (SessionStart, Stop, PreToolUse, etc.)
  ↓
~/.local/bin/hud-hook binary invoked
  ↓
Event forwarded to daemon via Unix socket (~/.capacitor/daemon.sock)
  ↓
Daemon updates state in SQLite (~/.capacitor/daemon/state.db)
  ↓
Swift app polls daemon for latest state
```

**Hook Configuration** (in `~/.claude/settings.json`):
```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "CAPACITOR_DAEMON_ENABLED=1 $HOME/.local/bin/hud-hook handle",
        "async": true,
        "timeout": 30
      }]
    }],
    "Stop": [{ /* ... */ }],
    "PreToolUse": [{ /* ... */ }],
    // ... more hooks
  }
}
```

**Hook Binary** (`core/hud-hook/`):
- Rust CLI that receives JSON events via stdin
- Forwards to daemon via Unix socket
- Handles errors gracefully (Claude Code shouldn't crash if hook fails)
- Fast startup (< 50ms cold start)

**Why Not File Watching?**
- File watching is fragile (race conditions, timing issues)
- Hooks are deterministic (event happens → hook fires)
- Lower CPU usage (events only when activity happens)
- More accurate state (know exactly when events occur)

### 2. Daemon-Based State Management

**Architecture**:
```
┌────────────────────────────────────────┐
│   Daemon Process (capacitor-daemon)    │
│  • Listens on Unix socket              │
│  • Maintains SQLite state database     │
│  • Handles concurrent hook events      │
│  • Performs liveness checks            │
└────────────────────────────────────────┘
         ↕ (Unix Socket IPC)
┌────────────────────────────────────────┐
│   Clients (hud-hook, Swift app, CLI)   │
└────────────────────────────────────────┘
```

**Daemon Responsibilities**:

1. **Event Ingestion**
   - Receives hook events via socket
   - Parses JSON payloads
   - Updates SQLite state atomically

2. **State Resolution**
   - Determines session state (Working, Ready, Idle, etc.)
   - Handles edge cases (crashed sessions, stale PIDs)
   - Resolves project paths (symlinks, monorepos)

3. **Liveness Checks**
   - Periodically checks if session PIDs are alive
   - Marks dead sessions as `Idle`
   - Cleans up stale data

4. **Shell CWD Tracking**
   - Receives `hud-hook cwd` events
   - Stores recent shells + parent app/TTY metadata
   - Serves shell state over IPC (`get_shell_state`)

5. **IPC Protocol**
   ```rust
   pub struct Request {
       protocol_version: u32,
       method: Method,  // GetSessions, GetHealth, etc.
       id: Option<String>,
       params: Option<serde_json::Value>,
   }
   
   pub struct Response {
       ok: bool,
       data: Option<serde_json::Value>,
       error: Option<String>,
   }
   ```

**Example: Getting Session State**
```rust
// In Rust core (daemon.rs)
pub fn sessions_snapshot() -> Option<DaemonSessionsSnapshot> {
    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::GetSessions,
        id: Some("sessions-snapshot".to_string()),
        params: None,
    };
    
    let response = send_request(request).ok()?;
    let sessions: Vec<DaemonSessionRecord> = serde_json::from_value(response.data?).ok()?;
    Some(DaemonSessionsSnapshot { sessions })
}
```

**Session State Machine** (simplified):
```
Idle ──SessionStart──> Ready
Ready ──UserPromptSubmit──> Working
Working ──PermissionRequest──> Waiting
Waiting ──UserResponse──> Working
Working ──Stop──> Ready
Working ──PreCompact──> Compacting
Compacting ──PostCompact──> Ready
Ready ──SessionEnd──> Idle
```

### 3. Project Management

**Discovery**:
```rust
pub fn get_suggested_projects(&self) -> Result<Vec<SuggestedProject>, HudFfiError> {
    // 1. Scan ~/.claude/projects/ for encoded project paths
    let projects_dir = self.storage.claude_root().join("projects");
    
    // 2. Decode path (e.g., "-Users-pete-Code-myproject" → "/Users/pete/Code/myproject")
    let real_path = try_resolve_encoded_path(&encoded_name)?;
    
    // 3. Check for project indicators
    let has_indicators = has_project_indicators(&project_path);
    // Looks for: CLAUDE.md, .claude/, .git/, package.json, Cargo.toml, etc.
    
    // 4. Count recent activity (transcripts)
    let task_count = count_recent_transcripts(&project_path);
    
    // 5. Sort by activity, filter out pinned projects
    suggestions.sort_by(|a, b| b.task_count.cmp(&a.task_count));
}
```

**Path Encoding** (how Claude Code stores project dirs):
```
/Users/pete/Code/my-project
  ↓ (encode)
-Users-pete-Code-my-project
  ↓ (stored in)
~/.claude/projects/-Users-pete-Code-my-project/
```

**Project Metadata** (simplified):
```rust
pub struct Project {
    pub name: String,
    pub path: String,
    pub display_path: String,
    pub last_active: Option<String>,
    pub claude_md_path: Option<String>,
    pub claude_md_preview: Option<String>,
    pub has_local_settings: bool,
    pub task_count: u32,
    pub stats: Option<ProjectStats>,
    pub is_missing: bool,
}
```

### 4. Session State Resolution

**The Challenge**: Multiple sessions can exist for the same project. How do we determine the "canonical" state?

**Resolution Strategy**:
Swift performs the merge in `SessionStateManager.mergeDaemonProjectStates()` using path normalization,
depth sorting, and recency checks. Rust clients use similar logic in `core/hud-core/src/state/daemon.rs`.

```rust
pub fn latest_for_project(&self, project_path: &str) -> Option<&DaemonSessionRecord> {
    let mut best: Option<&DaemonSessionRecord> = None;
    
    for session in &self.sessions {
        // 1. Check if session belongs to this project
        let matches = path_is_parent_or_self(project_path, &session.project_path);
        
        // 2. Pick the most recent session
        let is_newer = match best {
            None => true,
            Some(existing) => is_more_recent(session, existing),
        };
        
        if is_newer {
            best = Some(session);
        }
    }
    
    best
}
```

**Recency Logic**:
```rust
fn is_more_recent(a: &DaemonSessionRecord, b: &DaemonSessionRecord) -> bool {
    // 1. Active sessions always beat idle
    if a.is_active() && !b.is_active() { return true; }
    if !a.is_active() && b.is_active() { return false; }
    
    // 2. Compare timestamps
    a.updated_at > b.updated_at
}
```

**Edge Cases Handled**:
- Crashed sessions (PID liveness checks)
- Stale data (timestamp-based expiry)
- Monorepos (nested project paths)
- Symlinks (resolved before comparison)

### 5. Stats Parsing

**Input**: Claude Code transcript files (JSON Lines)
```json
{"type":"message","role":"user","content":"..."}
{"type":"message","role":"assistant","content":"...","usage":{"input_tokens":1234,"output_tokens":567,"cache_read_tokens":890}}
```

**Output**: Aggregated statistics
```rust
pub struct ProjectStats {
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_read_tokens: u64,
    pub total_cache_creation_tokens: u64,
    pub opus_messages: u32,
    pub sonnet_messages: u32,
    pub haiku_messages: u32,
    pub session_count: u32,
    pub latest_summary: Option<String>,
    pub first_activity: Option<String>,
    pub last_activity: Option<String>,
}
```

**Parsing Strategy**:
```rust
pub fn collect_stats(&self, project_path: &str) -> Result<ProjectStats, HudFfiError> {
    let transcripts_dir = self.encoded_project_dir(project_path);
    let mut stats = ProjectStats::default();
    
    // 1. Find all transcript files
    for transcript_path in find_transcripts(&transcripts_dir) {
        // 2. Parse JSONL
        let file = BufReader::new(File::open(transcript_path)?);
        for line in file.lines() {
            let message: Message = serde_json::from_str(&line?)?;
            
            // 3. Extract usage data
            if let Some(usage) = message.usage {
                stats.total_input_tokens += usage.input_tokens;
                stats.total_output_tokens += usage.output_tokens;
                // ...
            }
            
            // 4. Track model counts (opus/sonnet/haiku)
            stats.increment_model_counts(message.model.as_deref());
        }
    }
    
    Ok(stats)
}
```

**Caching Strategy**:
- Stats are expensive to compute (can be 100s of MB of JSON)
- Cache results in `~/.capacitor/stats-cache.json`
- Invalidate on file mtime change
- Background refresh (don't block UI)

### 6. Idea Capture System

**Goal**: Capture project ideas without breaking flow.

**Data Model**:
```rust
pub struct Idea {
    pub id: String,          // ULID (stable, sortable)
    pub title: String,       // Short title
    pub description: String, // Full text
    pub added: String,       // ISO timestamp
    pub effort: String,      // unknown | small | medium | large | xl
    pub status: String,      // open | in-progress | done
    pub triage: String,      // pending | validated
    pub related: Option<String>,
}
```

**Storage**:
```
~/.capacitor/projects/{encoded-path}/ideas.md
~/.capacitor/projects/{encoded-path}/ideas-order.json
```

**Sensemaking Flow** (Swift-side):
```
User types idea
  ↓
Swift calls engine.captureIdea(project, ideaText)
  ↓
Rust saves raw idea to disk
  ↓
Swift runs Claude CLI (Haiku) to generate title/description
  ↓
Swift writes updates via engine.updateIdeaTitle/Description
  ↓
Swift displays enhanced idea
```

**Reordering**:
- Order is stored in `ideas-order.json` as an array of idea IDs.
- Drag-to-reorder updates this file asynchronously (optimistic UI).

### 7. Terminal/Shell Integration

**Problem**: How do we know which terminal tab a session is in? How do we switch to it?

**Solution**: Rust resolver + Swift executor.

- **Rust** (`core/hud-core/src/activation.rs`) computes a pure `ActivationDecision`.
- **Swift** (`ActivationActionExecutor`) executes the decision (AppleScript / CLI).

```swift
let decision = try engine.resolveActivationWithTrace(
    projectPath: project.path,
    shellState: shellStateFfi,
    tmuxContext: tmuxContext,
    includeTrace: true
)

activationExecutor.execute(decision.primary)
```

**Shell Hook** (injected into .zshrc/.bashrc):
```bash
# Zsh
precmd_functions+=(capacitor_track_cwd)
capacitor_track_cwd() {
  CAPACITOR_DAEMON_ENABLED=1 \
    ~/.local/bin/hud-hook cwd "$PWD" "$$" "$TTY" >/dev/null 2>&1 &
}

# Bash
PROMPT_COMMAND='CAPACITOR_DAEMON_ENABLED=1 ~/.local/bin/hud-hook cwd "$PWD" "$$" "$TTY" >/dev/null 2>&1; '"$PROMPT_COMMAND"
```

**CWD Resolution**:
- `hud-hook cwd` sends shell CWD events to the daemon.
- The daemon exposes shell state over IPC.
- Swift polls `DaemonClient.fetchShellState()`, and `TerminalLauncher` passes that to the Rust resolver.

### 8. Agent System (Extensibility)

**Goal**: Support multiple AI providers (Claude, GPT, Gemini, etc.).

**Architecture**:
```rust
pub trait AgentAdapter {
    fn parse_session_state(&self, transcript: &Path) -> Option<AgentSession>;
    fn extract_stats(&self, transcript: &Path) -> Option<AgentStats>;
}

pub struct AgentRegistry {
    adapters: Vec<Arc<dyn AgentAdapter>>,
}

impl AgentRegistry {
    pub fn installed_agents(&self) -> Vec<&dyn AgentAdapter> { /* ... */ }
    pub fn detect_primary_session(&self, project_path: &str) -> Option<AgentSession> { /* ... */ }
    pub fn all_sessions_cached(&self) -> Vec<AgentSession> { /* ... */ }
}
```

**Why This Design?**
- Future-proof for other AI coding assistants
- Centralized detection logic
- Easy to add new adapters without changing core code
 - Current adapters include Claude + stub adapters (Codex, OpenCode, Aider, Amp, Droid)

---

## Code Organization

### Directory Structure
```
capacitor/
├── core/
│   ├── daemon/                # capacitor-daemon (IPC + SQLite state)
│   │   ├── src/
│   │   │   ├── main.rs        # Daemon entrypoint
│   │   │   ├── state.rs       # In-memory state + reducers
│   │   │   └── db.rs          # SQLite persistence
│   │
│   ├── daemon-protocol/       # Shared IPC types/protocol
│   ├── hud-core/              # Main Rust library
│   │   ├── src/
│   │   │   ├── lib.rs         # Crate root, re-exports
│   │   │   ├── engine.rs      # HudEngine (FFI facade)
│   │   │   ├── sessions.rs    # Session state detection
│   │   │   ├── projects.rs    # Project management
│   │   │   ├── ideas.rs       # Idea capture
│   │   │   ├── stats.rs       # Token usage parsing
│   │   │   ├── config.rs      # Config file I/O
│   │   │   ├── storage.rs     # Path resolution
│   │   │   ├── validation.rs  # Project validation
│   │   │   ├── artifacts.rs   # Transcript enumeration
│   │   │   ├── activation/    # Terminal activation
│   │   │   ├── agents/        # Agent adapters
│   │   │   └── state/         # Daemon client
│   │   └── uniffi-bindgen.rs  # UniFFI setup
│   │
│   └── hud-hook/              # Hook binary
│       └── src/
│           ├── main.rs        # CLI entry point
│           ├── handle.rs      # Event handling
│           └── cwd.rs         # Shell CWD tracking
│
├── apps/swift/
│   └── Sources/Capacitor/
│       ├── App.swift          # SwiftUI app entry
│       ├── Models/
│       │   ├── AppState.swift           # Global state
│       │   ├── ProjectDetailsManager.swift
│       │   ├── SessionStateManager.swift
│       │   ├── ActivationActionExecutor.swift
│       │   └── DaemonClient.swift
│       ├── Views/
│       │   ├── Projects/      # Project cards, layouts
│       │   ├── Settings/      # Settings UI
│       │   ├── Footer/        # Status bar
│       │   └── Setup/         # Onboarding
│       ├── Bridge/
│       │   ├── hud_core.swift       # Generated UniFFI bindings
│       │   └── UniFFIExtensions.swift
│       ├── Utilities/         # Helpers, logging
│       └── Theme/             # Colors, typography
│
├── scripts/
│   ├── dev/
│   │   ├── setup.sh           # Dev environment setup
│   │   ├── restart-app.sh     # Rebuild + relaunch
│   │   └── run-tests.sh       # Test runner
│   └── release/
│       ├── build-distribution.sh
│       └── create-dmg.sh
│
└── tests/                     # Integration tests
```

### Key Files to Know

| File | Purpose | When to Touch |
|------|---------|---------------|
| `core/hud-core/src/engine.rs` | Main FFI facade | Adding new features exposed to Swift |
| `core/hud-core/src/sessions.rs` | Session state logic | Changing state detection algorithm |
| `core/daemon/src/main.rs` | Daemon entrypoint + IPC | Debugging daemon startup/socket issues |
| `apps/swift/Sources/Capacitor/Models/AppState.swift` | Global Swift state | Adding new UI state |
| `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift` | Main project card UI | Tweaking project card appearance |
| `core/hud-hook/src/handle.rs` | Hook event handling | Changing how hooks process events |
| `scripts/dev/restart-app.sh` | Dev workflow script | Debugging build issues |

---

## Data Flow

### Example: Refreshing Projects List

```
User opens app
  ↓
AppState.init() triggers loadDashboard()
  ↓
[Swift] let dashboard = try engine.loadDashboard()
  ↓
[UniFFI Bridge] Marshals call to Rust
  ↓
[Rust] HudEngine::load_dashboard()
  ↓
[Rust] Loads pinned projects + stats (cached or fresh parse)
  ↓
[UniFFI Bridge] Marshals DashboardData to Swift
  ↓
[Swift] appState.projects = dashboard.projects
  ↓
[Swift] sessionStateManager.refreshSessionStates(for: projects)
  ↓
[Swift] projectDetailsManager.loadAllIdeas(for: projects)
  ↓
UI re-renders project cards
```

### Example: Session State Update

```
Claude Code fires SessionStart hook
  ↓
~/.local/bin/hud-hook invoked with JSON event
  ↓
[hud-hook] Connects to ~/.capacitor/daemon.sock
  ↓
[hud-hook] Sends event via Unix socket
  ↓
[Daemon] Receives event, parses JSON
  ↓
[Daemon] Updates SQLite state.db
  ↓
[Daemon] Returns success response
  ↓
[hud-hook] Exits (success)
  ↓
(Meanwhile, ~2 seconds later...)
  ↓
[Swift] SessionStateManager.refreshSessionStates()
  ↓
[Swift] DaemonClient.fetchProjectStates()
  ↓
[Daemon] Returns current project state snapshot
  ↓
[Swift] Merges daemon states → pinned projects (path normalization + recency)
  ↓
[Swift] Updates UI (Working → Ready)
```

---

## Development Workflows

### First-Time Setup

```bash
# 1. Clone repo
git clone https://github.com/petekp/capacitor.git
cd capacitor

# 2. Run setup script (installs Rust, Swift tools, dependencies)
./scripts/dev/setup.sh

# 3. Build everything (optional; restart-app.sh will build too)
cargo build -p hud-core --release
cargo build -p capacitor-daemon --release
cargo build -p hud-hook --release
cd apps/swift && swift build

# 4. Run app (bundles debug app + writes Info.plist)
./scripts/dev/restart-app.sh
./scripts/dev/restart-app.sh --channel alpha
```

### Daily Development

```bash
# Edit Rust code
# → Edit files in core/hud-core/src/

# Edit Swift code
# → Edit files in apps/swift/Sources/Capacitor/

# Rebuild and restart app
./scripts/dev/restart-app.sh

# Run tests
./scripts/dev/run-tests.sh
```

### Adding a New Feature (End-to-End)

**Example**: Add a "mark project as favorite" feature.

1. **Add to Rust core**:
   ```rust
   // core/hud-core/src/projects.rs
   pub fn toggle_favorite(&self, project_path: &str) -> Result<(), HudFfiError> {
       let mut config = load_hud_config_with_storage(&self.storage);
       if config.favorites.contains(&project_path.to_string()) {
           config.favorites.retain(|p| p != project_path);
       } else {
           config.favorites.push(project_path.to_string());
       }
       save_hud_config_with_storage(&self.storage, &config)?;
       Ok(())
   }
   ```

2. **Expose via FFI**:
   ```rust
   // core/hud-core/src/engine.rs
   #[uniffi::export]
   impl HudEngine {
       pub fn toggle_favorite(&self, project_path: String) -> Result<(), HudFfiError> {
           projects::toggle_favorite(&self, &project_path)
       }
   }
   ```

3. **Add to Swift state**:
   ```swift
   // AppState.swift
   func toggleFavorite(for project: Project) {
       do {
           try engine.toggleFavorite(projectPath: project.path)
           refreshProjects() // Reload to reflect change
       } catch {
           print("Failed to toggle favorite: \(error)")
       }
   }
   ```

4. **Add UI**:
   ```swift
   // ProjectCardView.swift
   Button(action: {
       appState.toggleFavorite(for: project)
   }) {
       Image(systemName: project.isFavorite ? "star.fill" : "star")
   }
   ```

5. **Test**:
   ```bash
   ./scripts/dev/restart-app.sh
   # Click star icon, verify it persists across app restarts
   ```

### Debugging

**Rust Side**:
```bash
# Enable debug logging
export RUST_LOG=hud_core=debug

# Run tests with output
cargo test -- --nocapture

# Check specific module
cargo test sessions::tests --nocapture
```

**Swift Side**:
```swift
// Use DebugLog utility
DebugLog.log("Project added: \(project.name)", category: "Projects")

// Check Xcode console for logs
// Look in Console.app for "Capacitor" process
```

**Daemon**:
```bash
# Check daemon logs
tail -f ~/.capacitor/daemon/daemon.stdout.log
tail -f ~/.capacitor/daemon/daemon.stderr.log

# Query daemon directly
echo '{"protocol_version":1,"method":"GetSessions","id":"test"}' | nc -U ~/.capacitor/daemon.sock
```

### Common Gotchas

1. **UniFFI Changes Require Full Rebuild**
   - If you change a `#[uniffi::export]` signature, run `cargo clean`
   - UniFFI generates Swift at build time

2. **Daemon Must Be Running**
   - Session tracking won't work if daemon is down
   - Check with: `launchctl list | grep capacitor-daemon`

3. **File Permissions**
   - `~/.capacitor/` must be readable by app
   - Hooks must be executable (`chmod +x ~/.local/bin/hud-hook`)

4. **Cache Invalidation**
   - Stats cache can go stale
   - Delete `~/.capacitor/stats-cache.json` to force refresh

---

## Common Patterns

### Pattern: Graceful Degradation

```rust
// Don't error on missing files - return defaults
pub fn load_projects() -> Vec<Project> {
    match fs::read_to_string(config_path()) {
        Ok(contents) => serde_json::from_str(&contents).unwrap_or_default(),
        Err(_) => Vec::new(),  // File doesn't exist yet → empty list
    }
}
```

### Pattern: Path Encoding/Decoding

Capacitor now uses a **lossless, versioned** encoding (`p2_` prefix + percent encoding),
and still supports a **legacy lossy** scheme (leading `-` with `-` as separator).

```rust
// v2 encode: /Users/pete/Code/project → p2_%2FUsers%2Fpete%2FCode%2Fproject
pub fn encode_path(path: &str) -> String {
    StorageConfig::encode_path(path)
}

// decode handles v2 + legacy encodings
pub fn decode_path(encoded: &str) -> String {
    StorageConfig::decode_path(encoded)
}

// best-effort resolution (checks filesystem for ambiguous legacy paths)
pub fn try_resolve(encoded: &str) -> Option<String> {
    StorageConfig::try_resolve_encoded_path(encoded)
}
```

### Pattern: Result Mapping for FFI

```rust
// Internal Result type
type Result<T> = std::result::Result<T, HudError>;

// FFI-safe error type
#[derive(uniffi::Error)]
pub enum HudFfiError {
    IoError { message: String },
    ParseError { message: String },
    NotFound { message: String },
}

// Convert internal errors to FFI errors
impl From<HudError> for HudFfiError {
    fn from(err: HudError) -> Self {
        match err {
            HudError::Io(e) => HudFfiError::IoError { message: e.to_string() },
            HudError::Parse(e) => HudFfiError::ParseError { message: e.to_string() },
            // ...
        }
    }
}
```

### Pattern: Polling with Debounce (Swift)

```swift
class AppState {
    private var pollTimer: Timer?
    private var lastPollTime: Date?
    private let pollInterval: TimeInterval = 2.0
    
    func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refreshIfNeeded()
        }
    }
    
    private func refreshIfNeeded() {
        // Debounce: skip if last poll was too recent
        if let last = lastPollTime, Date().timeIntervalSince(last) < pollInterval {
            return
        }
        lastPollTime = Date()
        
        // Actual refresh
        refreshSessionStates()
    }
}
```

### Pattern: Cached Expensive Operations

```rust
pub struct StatsCache {
    cache: HashMap<String, (ProjectStats, SystemTime)>,  // path → (stats, mtime)
}

impl StatsCache {
    pub fn get_or_compute(&mut self, project_path: &str) -> Result<ProjectStats> {
        let transcript_mtime = get_latest_transcript_mtime(project_path)?;
        
        // Check cache
        if let Some((stats, cached_mtime)) = self.cache.get(project_path) {
            if *cached_mtime >= transcript_mtime {
                return Ok(stats.clone());  // Cache hit
            }
        }
        
        // Cache miss or stale - recompute
        let stats = compute_stats(project_path)?;
        self.cache.insert(project_path.to_string(), (stats.clone(), transcript_mtime));
        Ok(stats)
    }
}
```

---

## Navigation Guide

### "I want to..."

**...add a new UI view**
- → `apps/swift/Sources/Capacitor/Views/`
- Create new SwiftUI View struct
- Add to navigation in `ContentView.swift`

**...change how session state is detected**
- → Live daemon events: `core/hud-hook/src/handle.rs` + `core/daemon/src/reducer.rs`
- → Rust clients/offline snapshot logic: `core/hud-core/src/sessions.rs`

**...add a new hook event type**
- → `core/hud-hook/src/handle.rs`
- Add new event variant to `HookEvent` enum
- Handle in `handle_event()` function

**...modify project stats calculation**
- → `core/hud-core/src/stats.rs`
- Look for `collect_stats()` function
- Update parsing logic

**...change the UI theme/colors**
- → `apps/swift/Sources/Capacitor/Theme/Colors.swift`
- Update color definitions

**...add a new terminal adapter**
- → `core/hud-core/src/activation/`
- Create new adapter file (e.g., `kitty.rs`)
- Implement `TerminalAdapter` trait
- Register in `policy.rs`

**...debug why hooks aren't firing**
- Check: `~/.claude/settings.json` (hooks configured?)
- Check: `~/.local/bin/hud-hook` (binary exists and executable?)
- Check: `~/.capacitor/daemon/daemon.stderr.log` (daemon errors?)
- Run: `echo '{"type":"test"}' | CAPACITOR_DAEMON_ENABLED=1 ~/.local/bin/hud-hook handle`

**...understand data flow for a feature**
- Start at: `apps/swift/Sources/Capacitor/Models/AppState.swift`
- Trace function calls into `engine.*` methods
- Follow into `core/hud-core/src/engine.rs`
- Follow into specific module (sessions, projects, etc.)

---

## Glossary for TypeScript Devs

| Rust Concept | TypeScript Equivalent | Notes |
|--------------|----------------------|-------|
| `Result<T, E>` | `Promise<T>` / `try-catch` | Explicit error handling |
| `Option<T>` | `T \| undefined` | Explicit nullability |
| `impl Trait` | Interface implementation | Trait = interface |
| `&str` | `string` (immutable) | String slice (borrowed) |
| `String` | `string` (mutable) | Owned string |
| `Vec<T>` | `Array<T>` | Growable array |
| `HashMap<K, V>` | `Map<K, V>` | Hash map |
| `#[derive(Debug)]` | `toString()` override | Auto-implement debug printing |
| `pub` | `export` | Public visibility |
| `mod` | Module/file | Code organization |
| `use` | `import` | Import items |
| `cargo` | `npm`/`yarn` | Package manager |
| `Cargo.toml` | `package.json` | Dependency manifest |

---

## Further Reading

- **UniFFI**: https://mozilla.github.io/uniffi-rs/
- **Rust Book**: https://doc.rust-lang.org/book/
- **SwiftUI**: https://developer.apple.com/xcode/swiftui/
- **Claude Code Hooks**: (in Claude Code docs)

---

## Questions?

If you're stuck or confused:
1. Check `CLAUDE.md` in the repo root (project context)
2. Look in `.claude/docs/` for detailed guides
3. Search the codebase for similar examples
4. Ask Pete (he built this!)

---

**Last Updated**: February 3, 2026  
**Maintained By**: OpenClaw Agent (Claude)
