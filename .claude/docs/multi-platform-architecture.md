# Claude HUD Architecture: Multi-Platform Core Library

## Executive Summary

This document specifies the architectural changes to transform Claude HUD from a single Tauri application into a multi-platform system with a shared Rust core. The goal: **write business logic once, deploy everywhere** (terminal, desktop, mobile, web).

**Key Decisions:**
- Synchronous core library (no async runtime dependency)
- Facade pattern via `HudEngine` for simplified API surface
- Client-side synchronization (core is not thread-safe)
- File-based IPC with Claude Code (no direct process communication)

---

## Product Rationale

Claude HUD's value proposition extends beyond managing existing work—it's about **being available whenever the impulse to create strikes**. This requires presence across contexts:

| Context | Client | Moment of Intent |
|---------|--------|------------------|
| **Terminal** | TUI | Already in flow, zero context-switch to check status or resume |
| **Desktop** | Tauri | Deliberate work sessions, full UI for deep project exploration |
| **Mobile** | Server + App | Capture inspiration before it fades, queue work for later |

The key insight: **the "I'll do it later" moments are where projects die.** If Claude HUD is there in those moments—on your phone while walking, in a tmux pane while coding—projects live.

A shared core library (`hud-core`) enables this omnipresence without feature drift or maintenance burden. The architecture is not over-engineering—it's the minimum necessary foundation for the product vision: **spin up Claude Code projects the moment inspiration strikes, from anywhere.**

---

## 1. Current Architecture Analysis

### 1.1 System Inventory

```
claude-hud/
├── core/
│   └── hud-core/           # Shared Rust core library
│       └── src/
│           ├── lib.rs      # Re-exports + UniFFI scaffolding
│           ├── engine.rs   # HudEngine facade
│           ├── types.rs    # Shared types (UniFFI exported)
│           ├── error.rs    # Error types
│           ├── patterns.rs # Compiled regex patterns
│           ├── config.rs   # Config and path utilities
│           ├── stats.rs    # Statistics parsing and caching
│           ├── projects.rs # Project loading and discovery
│           ├── sessions.rs # Session state detection
│           └── artifacts.rs# Artifact discovery
├── apps/
│   ├── tauri/              # Tauri desktop app
│   │   ├── src/            # React frontend
│   │   │   ├── App.tsx
│   │   │   ├── types.ts    # Must mirror Rust types
│   │   │   └── components/
│   │   └── src-tauri/      # Rust backend
│   │       └── src/
│   │           ├── lib.rs  # IPC command handlers (thin wrappers)
│   │           └── bin/
│   │               └── hud-tui.rs  # Terminal UI
│   ├── swift/              # Native macOS app
│   │   └── Sources/ClaudeHUD/
│   └── daemon/             # HUD daemon (TypeScript)
└── package.json
```

### 1.2 Problems Identified (Historical)

> **Note:** These problems have been resolved by the migration to `hud-core`. This section is preserved for historical context.

| Problem | Impact | Resolution |
|---------|--------|------------|
| **Code Duplication** | Bugs fixed in one place remain in other | ✅ Resolved: All logic now in `hud-core` |
| **Tight Coupling** | Cannot test business logic in isolation | ✅ Resolved: `HudEngine` facade separates concerns |
| **Type Divergence** | Runtime deserialization failures | ✅ Resolved: Single type definitions in `hud-core/types.rs` |
| **Platform Lock-in** | Cannot reuse for mobile/web | ✅ Resolved: Tauri, Swift, and TUI all use `hud-core` |
| **Implicit Dependencies** | Hard to reason about data flow | ✅ Resolved: `HudEngine::with_claude_dir()` for explicit paths |

### 1.3 Current Architecture Benefits

The migration to `hud-core` achieved:

| Benefit | Evidence |
|---------|----------|
| **Single source of truth** | All types in `core/hud-core/src/types.rs` |
| **Multi-platform support** | Tauri (React), Swift (SwiftUI), TUI all share same core |
| **Testable business logic** | `HudEngine` can be tested in isolation |
| **Consistent state file handling** | `hud-session-states.json` read by single implementation |

**Current state file:** `~/.claude/hud-session-states.json` (updated via hooks)

---

## 2. Target Architecture

### 2.1 Dependency Graph

```
                                 ┌─────────────┐
                                 │   std lib   │
                                 └──────┬──────┘
                                        │
         ┌──────────────────────────────┼──────────────────────────────┐
         │                              │                              │
         ▼                              ▼                              ▼
   ┌───────────┐                 ┌─────────────┐               ┌─────────────┐
   │   serde   │                 │    regex    │               │    dirs     │
   └─────┬─────┘                 └──────┬──────┘               └──────┬──────┘
         │                              │                              │
         └──────────────────────────────┼──────────────────────────────┘
                                        │
                                        ▼
                              ┌───────────────────┐
                              │     hud-core      │
                              │  (library crate)  │
                              └─────────┬─────────┘
                                        │
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
              ▼                         ▼                         ▼
       ┌─────────────┐          ┌─────────────┐          ┌─────────────┐
       │   hud-tui   │          │  hud-tauri  │          │ hud-server  │
       │  (binary)   │          │  (binary)   │          │  (binary)   │
       └─────────────┘          └─────────────┘          └─────────────┘
              │                         │                         │
              ▼                         ▼                         ▼
       ┌─────────────┐          ┌─────────────┐          ┌─────────────┐
       │  ratatui    │          │    tauri    │          │    axum     │
       │  crossterm  │          │   plugins   │          │    tokio    │
       └─────────────┘          └─────────────┘          └─────────────┘
```

**Invariant:** `hud-core` has no dependencies on any client crate. Dependencies flow strictly downward.

**Constraint:** `hud-core` cannot depend on `tauri`, `ratatui`, `axum`, or `tokio`. This ensures it remains portable.

### 2.2 Workspace Structure (Current Implementation)

```
claude-hud/
├── Cargo.toml                    # Workspace root
├── core/
│   └── hud-core/                 # Shared library
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs            # Public API + re-exports + UniFFI scaffolding
│           ├── engine.rs         # HudEngine facade
│           ├── error.rs          # Error types (UniFFI exported)
│           ├── types.rs          # All shared types (UniFFI exported)
│           ├── config.rs         # HudConfig, path resolution
│           ├── projects.rs       # Project discovery & loading
│           ├── sessions.rs       # Session state management
│           ├── stats.rs          # Statistics parsing & caching
│           ├── artifacts.rs      # Skills/commands/agents discovery
│           └── patterns.rs       # Compiled regex patterns
│
├── apps/
│   ├── tauri/                    # Tauri desktop app (cross-platform)
│   │   ├── package.json          # Frontend dependencies
│   │   ├── src/                  # React frontend
│   │   │   ├── App.tsx
│   │   │   ├── types.ts          # TypeScript types (must mirror Rust)
│   │   │   └── components/
│   │   └── src-tauri/            # Rust backend
│   │       ├── Cargo.toml        # Depends on hud-core
│   │       └── src/
│   │           ├── lib.rs        # IPC command handlers (thin wrappers)
│   │           └── bin/
│   │               └── hud-tui.rs # Terminal UI
│   │
│   ├── swift/                    # Native macOS app
│   │   ├── Package.swift         # Swift Package Manager config
│   │   ├── Sources/
│   │   │   ├── ClaudeHUD/        # SwiftUI app
│   │   │   └── HudCoreFFI/       # FFI module wrapper
│   │   └── bindings/             # Generated UniFFI bindings
│   │       ├── hud_core.swift
│   │       └── hud_coreFFI.h
│   │
│   └── daemon/                   # HUD daemon (TypeScript)
│       ├── package.json
│       └── src/
│           ├── sdk/              # Claude Code SDK (stream-json)
│           ├── daemon/           # State tracking & relay
│           └── cli/              # hud-claude-daemon entry point
│
├── docs/                         # Documentation
│   ├── architecture-decisions/   # ADRs
│   └── cc/                       # Claude Code documentation
└── target/                       # Shared Rust build output
```

---

## 3. Core Library Design

### 3.1 Module Responsibilities

| Module | Responsibility | Public Exports |
|--------|----------------|----------------|
| `engine` | Facade coordinating all operations | `HudEngine` |
| `error` | Error type hierarchy | `HudError`, `Result` alias |
| `types/*` | Data transfer objects | All structs/enums |
| `config` | Configuration loading/saving | `HudConfig`, path functions |
| `projects` | Project discovery and loading | Internal (used by engine) |
| `sessions` | Session state reading | Internal (used by engine) |
| `stats` | Statistics parsing with caching | Internal (used by engine) |
| `artifacts` | Artifact enumeration | Internal (used by engine) |
| `plugins` | Plugin registry management | Internal (used by engine) |
| `patterns` | Pre-compiled regex | Internal (used by stats) |
| `actions` | Platform-specific operations | Internal (used by engine) |

**Design Decision:** Only `HudEngine`, error types, and data types are public. Internal modules are not re-exported. This provides a stable API surface while allowing internal refactoring.

### 3.2 HudEngine Specification

```rust
/// The main entry point for all HUD operations.
///
/// # Thread Safety
/// `HudEngine` is NOT thread-safe. Clients must provide their own
/// synchronization (e.g., `Mutex<HudEngine>` for Tauri, direct ownership for TUI).
///
/// # Caching Behavior
/// - Stats are cached by file mtime; cache is invalidated when files change
/// - Project list is NOT cached; always reads from disk
/// - Session states are NOT cached; always reads from disk
///
/// # File System Assumptions
/// - `~/.claude/` directory exists and is readable
/// - Files may be modified externally at any time
/// - Engine tolerates missing files (returns empty/default values)
pub struct HudEngine {
    claude_dir: PathBuf,
    config: HudConfig,
    stats_cache: StatsCache,
    summary_cache: SummaryCache,
}

impl HudEngine {
    // ═══════════════════════════════════════════════════════════════════
    // Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    /// Create a new engine instance.
    ///
    /// # Errors
    /// - `HudError::ClaudeDirNotFound` if `~/.claude/` doesn't exist
    /// - `HudError::ConfigError` if `hud.json` exists but is malformed
    ///
    /// # File System Access
    /// - Reads: `~/.claude/hud.json`, `~/.claude/hud-stats-cache.json`
    /// - Creates: None (files created on first write)
    pub fn new() -> Result<Self, HudError>;

    /// Create engine with explicit claude directory (for testing).
    pub fn with_claude_dir(claude_dir: PathBuf) -> Result<Self, HudError>;

    /// Reload configuration from disk, clearing all caches.
    ///
    /// Call this after external changes to `~/.claude/` files.
    pub fn refresh(&mut self) -> Result<(), HudError>;

    /// Persist current caches to disk.
    ///
    /// # File System Access
    /// - Writes: `~/.claude/hud-stats-cache.json`
    pub fn flush_caches(&self) -> Result<(), HudError>;

    // ═══════════════════════════════════════════════════════════════════
    // Project Operations
    // ═══════════════════════════════════════════════════════════════════

    /// List all pinned projects, sorted by most recent activity.
    ///
    /// # Performance
    /// - O(n) where n = number of pinned projects
    /// - Reads disk for each project's stats (cached by mtime)
    ///
    /// # File System Access
    /// - Reads: `~/.claude/hud.json`
    /// - Reads: `~/.claude/projects/{encoded_path}/*.jsonl` (for stats)
    pub fn list_projects(&mut self) -> Vec<Project>;

    /// Get detailed information for a specific project.
    ///
    /// # Errors
    /// - `HudError::ProjectNotFound` if path is not in pinned list
    ///
    /// # File System Access
    /// - Reads: `{project_path}/.claude/CLAUDE.md`
    /// - Reads: `{project_path}/.claude/todos.json`
    /// - Executes: `git status` in project directory
    pub fn get_project_details(&mut self, path: &str) -> Result<ProjectDetails, HudError>;

    /// Add a project to the pinned list.
    ///
    /// # Errors
    /// - `HudError::IoError` if path doesn't exist
    /// - `HudError::ConfigError` if project already pinned
    ///
    /// # Side Effects
    /// - Writes `~/.claude/hud.json`
    pub fn add_project(&mut self, path: &str) -> Result<(), HudError>;

    /// Remove a project from the pinned list.
    ///
    /// # Errors
    /// - `HudError::ProjectNotFound` if not in pinned list
    ///
    /// # Side Effects
    /// - Writes `~/.claude/hud.json`
    /// - Does NOT delete project data from `~/.claude/projects/`
    pub fn remove_project(&mut self, path: &str) -> Result<(), HudError>;

    /// Discover projects with recent Claude activity that aren't pinned.
    ///
    /// Scans `~/.claude/projects/` for directories with `.jsonl` files
    /// modified in the last 30 days.
    ///
    /// # Performance
    /// - O(n) where n = number of directories in `~/.claude/projects/`
    /// - May be slow on first call; consider running in background
    pub fn suggest_projects(&self) -> Vec<SuggestedProject>;

    // ═══════════════════════════════════════════════════════════════════
    // Session State
    // ═══════════════════════════════════════════════════════════════════

    /// Get current session states for all projects.
    ///
    /// Returns a map from project path to session state info.
    /// Projects without active sessions are not included.
    ///
    /// # File System Access
    /// - Reads: `~/.claude/hud-session-states.json`
    ///
    /// # Consistency
    /// This reads a file that Claude Code writes. The file may be:
    /// - Missing (returns empty map)
    /// - Partially written (may fail to parse; returns empty map)
    /// - Stale (Claude Code updates on state changes, not continuously)
    pub fn get_session_states(&self) -> HashMap<String, SessionStateInfo>;

    // ═══════════════════════════════════════════════════════════════════
    // Statistics
    // ═══════════════════════════════════════════════════════════════════

    /// Get aggregated statistics for a project.
    ///
    /// Statistics are cached by file mtime. Cache is invalidated when:
    /// - A `.jsonl` file is added, removed, or modified
    /// - `refresh()` is called
    ///
    /// # Performance
    /// - Cache hit: O(1)
    /// - Cache miss: O(n * m) where n = files, m = lines per file
    pub fn get_project_stats(&mut self, path: &str) -> ProjectStats;

    /// Calculate estimated cost from token statistics.
    ///
    /// Uses current Claude API pricing. Cost is an estimate based on:
    /// - Input tokens (per-model rates)
    /// - Output tokens (per-model rates)
    /// - Cache read tokens (discounted rate)
    /// - Cache write tokens (premium rate)
    pub fn calculate_cost(stats: &ProjectStats) -> f64;

    // ═══════════════════════════════════════════════════════════════════
    // Artifacts
    // ═══════════════════════════════════════════════════════════════════

    /// List all artifacts (skills, commands, agents) from global and plugins.
    ///
    /// # Discovery Rules
    /// - Skills: Directories containing `SKILL.md` or `skill.md`
    /// - Commands: `.md` files in `commands/` directories
    /// - Agents: `.md` files in `agents/` directories
    ///
    /// # File System Access
    /// - Reads: `~/.claude/skills/`, `~/.claude/commands/`, `~/.claude/agents/`
    /// - Reads: `~/.claude/plugins/*/skills/`, etc.
    pub fn list_artifacts(&self) -> Vec<Artifact>;

    /// List installed plugins with metadata and artifact counts.
    ///
    /// # File System Access
    /// - Reads: `~/.claude/plugins/installed_plugins.json`
    /// - Reads: `~/.claude/settings.json` (for enabled state)
    pub fn list_plugins(&self) -> Vec<Plugin>;

    /// Toggle a plugin's enabled state.
    ///
    /// # Side Effects
    /// - Modifies `~/.claude/settings.json`
    pub fn toggle_plugin(&mut self, plugin_id: &str) -> Result<(), HudError>;

    // ═══════════════════════════════════════════════════════════════════
    // Actions
    // ═══════════════════════════════════════════════════════════════════

    /// Launch a project in a new tmux window.
    ///
    /// # Platform Support
    /// - macOS: ✓ (requires tmux installed)
    /// - Linux: ✓ (requires tmux installed)
    /// - Windows: Returns `HudError::UnsupportedPlatform`
    ///
    /// # Behavior
    /// - Creates new tmux window named after project
    /// - Changes directory to project path
    /// - Optionally runs `claude --resume`
    ///
    /// # Errors
    /// - `HudError::CommandFailed` if tmux not installed or not in tmux session
    pub fn launch_in_tmux(&self, path: &str, resume: bool) -> Result<(), HudError>;

    /// Open a file in the system's default editor.
    ///
    /// # Platform Behavior
    /// - macOS: Uses `open` command
    /// - Linux: Uses `xdg-open`
    /// - Windows: Uses `start`
    pub fn open_in_editor(&self, path: &str) -> Result<(), HudError>;

    /// Open a folder in the system's file manager.
    pub fn open_folder(&self, path: &str) -> Result<(), HudError>;

    /// Read file content as UTF-8 string.
    ///
    /// # Security
    /// - No path traversal protection (caller must validate paths)
    /// - Symlinks are followed
    pub fn read_file(&self, path: &str) -> Result<String, HudError>;
}
```

### 3.3 Type Definitions

```rust
// ═══════════════════════════════════════════════════════════════════════════
// Session State (matches Claude Code's hud-session-states.json format)
// ═══════════════════════════════════════════════════════════════════════════

/// The current state of a Claude Code session.
///
/// These states match the values written by Claude Code to `hud-session-states.json`.
/// The serde rename ensures compatibility with the lowercase JSON format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionState {
    /// Claude is actively processing (generating response)
    Working,
    /// Claude has finished and is waiting for user input
    Ready,
    /// Session exists but has no recent activity
    Idle,
    /// Context is being compacted (summarization in progress)
    Compacting,
    /// Waiting for external input (tool result, user confirmation)
    Waiting,
}

impl SessionState {
    /// Whether this state indicates Claude needs attention.
    pub fn needs_attention(&self) -> bool {
        matches!(self, Self::Ready | Self::Waiting)
    }

    /// Whether this state indicates Claude is busy.
    pub fn is_busy(&self) -> bool {
        matches!(self, Self::Working | Self::Compacting)
    }
}

impl Default for SessionState {
    fn default() -> Self {
        Self::Idle
    }
}

/// Extended session state with metadata from Claude Code.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SessionStateInfo {
    pub state: SessionState,
    /// Percentage of context window used (0-100)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_percent: Option<u32>,
    /// Brief description of current task
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_on: Option<String>,
    /// Suggested next action
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_step: Option<String>,
    /// ISO 8601 timestamp of last state update
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
}

// ═══════════════════════════════════════════════════════════════════════════
// Project Types
// ═══════════════════════════════════════════════════════════════════════════

/// A pinned project in the HUD.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    /// Absolute filesystem path
    pub path: String,
    /// Display name (typically last path component)
    pub name: String,
    /// URL-safe encoded name for `~/.claude/projects/` lookup
    pub encoded_name: String,
    /// ISO 8601 date of most recent session activity
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_activity: Option<String>,
    /// Aggregated token usage statistics
    pub stats: ProjectStats,
}

/// Detailed project information including tasks and git status.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectDetails {
    pub project: Project,
    /// Tasks from `.claude/todos.json`
    pub tasks: Vec<Task>,
    /// Output of `git status --porcelain` if git repo
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git_status: Option<String>,
    /// Contents of `.claude/CLAUDE.md` if present
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claude_md_content: Option<String>,
    /// Recent session summaries
    pub sessions: Vec<SessionInfo>,
}

/// A project discovered in `~/.claude/projects/` but not yet pinned.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SuggestedProject {
    pub path: String,
    pub name: String,
    pub last_activity: String,
    pub session_count: u32,
}

// ═══════════════════════════════════════════════════════════════════════════
// Statistics Types
// ═══════════════════════════════════════════════════════════════════════════

/// Aggregated token usage statistics for a project.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ProjectStats {
    pub session_count: u32,
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_read_tokens: u64,
    pub total_cache_creation_tokens: u64,
    /// Messages sent using Claude Opus
    pub opus_messages: u32,
    /// Messages sent using Claude Sonnet
    pub sonnet_messages: u32,
    /// Messages sent using Claude Haiku
    pub haiku_messages: u32,
    /// ISO 8601 date of first recorded activity
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_activity: Option<String>,
    /// ISO 8601 date of most recent activity
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_activity: Option<String>,
    /// Most recent session summary
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latest_summary: Option<String>,
}
```

### 3.4 Error Handling

```rust
/// All errors that can occur in hud-core operations.
#[derive(Debug, thiserror::Error)]
pub enum HudError {
    // ─────────────────────────────────────────────────────────────────
    // Configuration Errors
    // ─────────────────────────────────────────────────────────────────

    #[error("Claude directory not found at {0}")]
    ClaudeDirNotFound(PathBuf),

    #[error("Configuration file malformed: {path}: {details}")]
    ConfigMalformed { path: PathBuf, details: String },

    #[error("Configuration write failed: {path}: {source}")]
    ConfigWriteFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    // ─────────────────────────────────────────────────────────────────
    // Project Errors
    // ─────────────────────────────────────────────────────────────────

    #[error("Project not found: {0}")]
    ProjectNotFound(String),

    #[error("Project already pinned: {0}")]
    ProjectAlreadyPinned(String),

    #[error("Invalid project path: {path}: {reason}")]
    InvalidProjectPath { path: String, reason: String },

    // ─────────────────────────────────────────────────────────────────
    // I/O Errors
    // ─────────────────────────────────────────────────────────────────

    #[error("File not found: {0}")]
    FileNotFound(PathBuf),

    #[error("I/O error: {context}: {source}")]
    Io {
        context: String,
        #[source]
        source: std::io::Error,
    },

    #[error("JSON parsing error: {context}: {source}")]
    Json {
        context: String,
        #[source]
        source: serde_json::Error,
    },

    // ─────────────────────────────────────────────────────────────────
    // Action Errors
    // ─────────────────────────────────────────────────────────────────

    #[error("Command execution failed: {command}: {details}")]
    CommandFailed { command: String, details: String },

    #[error("Platform not supported for this operation: {0}")]
    UnsupportedPlatform(String),

    #[error("Not running inside tmux session")]
    NotInTmux,
}

/// Convenience type alias for Results using HudError.
pub type Result<T> = std::result::Result<T, HudError>;

// Conversion for Tauri compatibility (commands return Result<T, String>)
impl From<HudError> for String {
    fn from(err: HudError) -> String {
        err.to_string()
    }
}
```

---

## 4. Concurrency Model

### 4.1 Thread Safety Analysis

| Component | Thread-Safe? | Synchronization Strategy |
|-----------|--------------|--------------------------|
| `HudEngine` | No | Clients wrap in `Mutex` or own exclusively |
| `StatsCache` | No | Part of `HudEngine`, same strategy |
| `HudConfig` | No | Part of `HudEngine`, same strategy |
| File reads | Yes | `std::fs` is thread-safe |
| File writes | No* | Use file locks or single-writer pattern |

*File writes are atomic at the OS level, but concurrent writes from multiple processes can cause data loss. Since Claude Code may also write to these files, we use a read-mostly pattern.

### 4.2 Client Synchronization Patterns

**TUI (Single-threaded):**
```rust
struct App {
    engine: HudEngine,  // Direct ownership, no synchronization needed
}
```

**Tauri (Multi-threaded IPC):**
```rust
type EngineState = Mutex<HudEngine>;

#[tauri::command]
fn load_projects(engine: State<EngineState>) -> Result<Vec<Project>, String> {
    let mut engine = engine.lock().map_err(|e| e.to_string())?;
    Ok(engine.list_projects())
}
```

**Server (Async multi-request):**
```rust
type SharedEngine = Arc<RwLock<HudEngine>>;

async fn list_projects(State(engine): State<SharedEngine>) -> Json<Vec<Project>> {
    // Use read lock for read-only operations
    let engine = engine.read().await;
    Json(engine.list_projects())
}

async fn add_project(State(engine): State<SharedEngine>, path: String) -> Result<(), String> {
    // Use write lock for mutations
    let mut engine = engine.write().await;
    engine.add_project(&path).map_err(|e| e.to_string())
}
```

### 4.3 File System Concurrency

**Problem:** Claude Code and HUD both read/write to `~/.claude/` files.

**Solution:** Read-mostly pattern with graceful degradation.

| File | Claude Code | HUD | Strategy |
|------|-------------|-----|----------|
| `hud-session-states.json` | Writes | Reads | HUD only reads; tolerates stale data |
| `hud.json` | Never | Read/Write | HUD owns this file exclusively |
| `settings.json` | Read/Write | Read/Write | Read-modify-write with atomic rename |
| `projects/*.jsonl` | Writes | Reads | HUD only reads; tolerates partial files |
| `hud-stats-cache.json` | Never | Read/Write | HUD owns this file exclusively |

**Atomic write pattern for shared files:**
```rust
fn write_settings_atomically(path: &Path, settings: &Settings) -> Result<()> {
    let temp_path = path.with_extension("json.tmp");
    let file = File::create(&temp_path)?;
    serde_json::to_writer_pretty(file, settings)?;
    std::fs::rename(&temp_path, path)?;  // Atomic on POSIX
    Ok(())
}
```

---

## 5. Caching Strategy

### 5.1 Stats Cache Design

**Cache Key:** Project path (string)

**Cache Value:**
```rust
struct CachedProjectStats {
    /// Map of filename -> (size, mtime) for cache invalidation
    files: HashMap<String, CachedFileInfo>,
    /// Computed statistics
    stats: ProjectStats,
}

struct CachedFileInfo {
    size: u64,
    mtime: u64,  // Seconds since UNIX epoch
}
```

**Invalidation Rules:**
1. File added to project directory → Invalidate
2. File removed from project directory → Invalidate
3. File size changed → Invalidate
4. File mtime changed → Invalidate
5. `refresh()` called → Invalidate all

**Cache Hit Criteria:**
- Same set of `.jsonl` files in directory
- All files have same (size, mtime) as cached

### 5.2 Cache Persistence

**File:** `~/.claude/hud-stats-cache.json`

**Format:**
```json
{
  "version": 1,
  "projects": {
    "/Users/pete/Code/my-project": {
      "files": {
        "abc123.jsonl": { "size": 45678, "mtime": 1704067200 }
      },
      "stats": {
        "session_count": 5,
        "total_input_tokens": 150000,
        ...
      }
    }
  }
}
```

**Migration:** If `version` doesn't match current, discard entire cache.

### 5.3 Cache Performance Characteristics

| Operation | Cache Hit | Cache Miss |
|-----------|-----------|------------|
| `list_projects()` (10 projects) | ~5ms | ~500ms |
| `get_project_stats()` | O(1) | O(files × lines) |
| Memory usage | ~1KB per project | Same |

---

## 6. File System Assumptions

### 6.1 Required Directory Structure

```
~/.claude/                          # MUST exist
├── hud.json                        # Created by HUD if missing
├── hud-session-states.json         # Created by hooks (tracks thinking state)
├── hud-stats-cache.json            # Created by HUD if missing
├── hud-summaries.json              # Session summaries cache
├── hud-project-summaries.json      # Project overview bullets
├── settings.json                   # Claude Code config (includes hooks)
├── scripts/
│   ├── hud-state-tracker.sh        # Hook script for state tracking
│   ├── hud-claude                  # Wrapper for normal Claude TUI
│   └── hud-claude-daemon           # Wrapper for daemon mode
├── hooks/
│   └── publish-state.sh            # Debounced relay publishing
├── projects/                       # Created by Claude Code (may not exist)
│   └── {encoded-path}/
│       └── {session-id}.jsonl
└── plugins/                        # Created by Claude Code (may not exist)
    ├── installed_plugins.json
    └── {plugin-id}/
        └── plugin.json
```

### 6.2 Graceful Degradation

| Missing File/Directory | Behavior |
|------------------------|----------|
| `~/.claude/` | Return `HudError::ClaudeDirNotFound` |
| `hud.json` | Return empty project list |
| `hud-session-states.json` | Return empty session states |
| `settings.json` | Use default settings |
| `projects/` | Return empty stats |
| `plugins/` | Return empty plugin list |
| Any `.jsonl` file | Skip file, continue processing |

### 6.3 Path Encoding

Claude Code encodes project paths for use as directory names:

| Original Path | Encoded |
|---------------|---------|
| `/Users/pete/Code/my-project` | `-Users-pete-Code-my-project` |
| `/home/user/projects/test` | `-home-user-projects-test` |

**Encoding rule:** Replace `/` with `-`, prepend `-`

**Decoding ambiguity:** Paths containing `-` cannot be unambiguously decoded. We handle this by:
1. Trying exact decode first
2. If path doesn't exist, trying common variations
3. Storing original path in `hud.json` as source of truth

---

## 7. Testing Strategy

### 7.1 Unit Tests (hud-core)

| Module | Test Focus |
|--------|------------|
| `stats` | Regex parsing with various JSONL formats |
| `config` | Path encoding/decoding edge cases |
| `types` | Serde round-trip for all types |
| `engine` | Mock file system operations |

**Example test structure:**
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup_test_claude_dir() -> TempDir {
        let dir = TempDir::new().unwrap();
        // Create minimal directory structure
        std::fs::create_dir_all(dir.path().join("projects")).unwrap();
        dir
    }

    #[test]
    fn test_engine_new_missing_claude_dir() {
        let result = HudEngine::with_claude_dir("/nonexistent".into());
        assert!(matches!(result, Err(HudError::ClaudeDirNotFound(_))));
    }

    #[test]
    fn test_stats_parsing_empty_file() {
        let mut stats = ProjectStats::default();
        parse_stats_from_content("", &mut stats);
        assert_eq!(stats.total_input_tokens, 0);
    }

    #[test]
    fn test_stats_parsing_valid_jsonl() {
        let content = r#"{"input_tokens":100,"output_tokens":50}
{"input_tokens":200,"output_tokens":100,"model":"claude-3-opus"}"#;
        let mut stats = ProjectStats::default();
        parse_stats_from_content(content, &mut stats);
        assert_eq!(stats.total_input_tokens, 300);
        assert_eq!(stats.opus_messages, 1);
    }
}
```

### 7.2 Integration Tests

| Test | Validates |
|------|-----------|
| `test_full_workflow` | Create engine → add project → get stats → remove project |
| `test_cache_invalidation` | Modify file → stats recomputed |
| `test_concurrent_access` | Multiple readers don't block |

### 7.3 Property-Based Tests

```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn test_path_encoding_roundtrip(path in "/[a-z/]+") {
        let encoded = encode_path(&path);
        let decoded = decode_path(&encoded);
        prop_assert_eq!(decoded, Some(path));
    }

    #[test]
    fn test_stats_never_negative(
        input in 0u64..1_000_000,
        output in 0u64..1_000_000
    ) {
        let content = format!(r#"{{"input_tokens":{},"output_tokens":{}}}"#, input, output);
        let mut stats = ProjectStats::default();
        parse_stats_from_content(&content, &mut stats);
        prop_assert!(stats.total_input_tokens >= 0);
        prop_assert!(stats.total_output_tokens >= 0);
    }
}
```

---

## 8. Migration Status

> **Status: COMPLETE** — The migration to `hud-core` has been successfully completed.

### Completed Phases

| Phase | Goal | Status |
|-------|------|--------|
| 1. Workspace Setup | Establish workspace structure | ✅ Complete |
| 2. Extract Types | Single source of truth for data types | ✅ Complete |
| 3. Extract Utilities | Move pure functions | ✅ Complete |
| 4. Extract Business Logic | Move to core library | ✅ Complete |
| 5. Create HudEngine Facade | Unified API surface | ✅ Complete |
| 6. Refactor Tauri Client | Thin IPC wrappers | ✅ Complete |
| 7. Add Swift Client | UniFFI bindings for SwiftUI | ✅ Complete |
| 8. Add Daemon | TypeScript daemon for remote use | ✅ Complete |

### Current Architecture

All clients now use the shared `hud-core` library:

```
┌─────────────────────────────────────────────────────────────┐
│                    Frontend Clients                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ Tauri App   │  │ Swift App   │  │ TUI (hud-tui.rs)    │ │
│  │ (React IPC) │  │ (UniFFI)    │  │ (direct Rust calls) │ │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘ │
└─────────┼────────────────┼────────────────────┼─────────────┘
          │                │                    │
          └────────────────┼────────────────────┘
                           ▼
                 ┌───────────────────┐
                 │     hud-core      │
                 │  (HudEngine API)  │
                 └───────────────────┘
```

### Future Work

If additional clients are needed:

1. **Web Client:** Use `hud-core` via WebAssembly (wasm-bindgen)
2. **Mobile Remote:** Connect via WebSocket relay to daemon
3. **Additional TUIs:** Import `hud-core` as dependency

---

## 9. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation | Detection |
|------|------------|--------|------------|-----------|
| Frontend API breaks | Medium | High | Keep IPC signatures identical | TypeScript compilation fails |
| Cache corruption | Low | Low | Version field enables safe migration | Logs show parse errors |
| Type serialization mismatch | Medium | Medium | Property-based serde tests | Integration tests fail |
| Performance regression | Low | Medium | Benchmark critical paths | Manual testing feels slow |
| Deadlock in Tauri | Low | High | Use `try_lock` with timeout | App hangs |
| Claude Code format change | Medium | Medium | Graceful degradation on parse errors | Stats show zeros |

---

## 10. Alternatives Considered

### 10.1 Async Core vs Sync Core

**Considered:** Making `HudEngine` async with `tokio`.

**Rejected because:**
- File I/O is fast enough synchronously
- TUI clients don't want async runtime overhead
- `spawn_blocking` bridges sync to async trivially
- Simpler mental model for contributors

### 10.2 Shared Engine via IPC

**Considered:** Single engine process that all clients talk to.

**Rejected because:**
- Adds deployment complexity (must run engine separately)
- IPC overhead for TUI (currently instant function calls)
- Single point of failure
- Harder to debug

### 10.3 Trait-Based Abstraction

**Considered:** `trait HudEngine` with multiple implementations.

**Rejected because:**
- Only one implementation needed currently
- YAGNI (You Aren't Gonna Need It)
- Concrete types are simpler and faster
- Can add traits later if needed

### 10.4 ECS Architecture

**Considered:** Entity-Component-System for projects/sessions.

**Rejected because:**
- Overkill for ~100 entities
- Learning curve for contributors
- Simple structs suffice for our data model

---

## 11. Glossary

| Term | Definition |
|------|------------|
| **Claude Code** | The CLI tool (`claude`) that users interact with |
| **HUD** | Heads-Up Display - this dashboard application |
| **Session** | A single conversation with Claude Code |
| **Project** | A directory where Claude Code has been used |
| **Pinned Project** | A project explicitly added to the HUD |
| **Artifact** | A skill, command, or agent definition |
| **Engine** | The `HudEngine` struct that provides all HUD operations |

---

## 12. Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-01-09 | Use sync core, not async | Simplicity; file I/O is fast; bridges trivially |
| 2026-01-09 | Facade pattern via HudEngine | Single entry point; easy to test; stable API |
| 2026-01-09 | Client-side synchronization | Each client knows its threading model best |
| 2026-01-09 | Read-mostly file pattern | Claude Code owns most files; we read and tolerate staleness |
| 2026-01-09 | Mtime-based cache invalidation | Simple; good enough for file-per-session granularity |
| 2026-01-09 | Workspace with core/ directory | Clean separation; `core/hud-core/` for shared library |
| 2026-01-10 | Add Swift client via UniFFI | Native macOS performance; 120Hz ProMotion animations |
| 2026-01-11 | Hooks for local, daemon for remote | Hooks preserve TUI; daemon for future mobile relay |

---

## Appendix A: Configuration Schemas

### hud.json
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "pinned_projects": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Absolute paths to pinned projects"
    }
  },
  "required": ["pinned_projects"]
}
```

### hud-session-states.json (written by hooks)
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "version": { "type": "integer", "const": 1 },
    "projects": {
      "type": "object",
      "additionalProperties": {
        "type": "object",
        "properties": {
          "state": { "enum": ["working", "ready", "idle", "compacting"] },
          "state_changed_at": { "type": "string", "format": "date-time" },
          "session_id": { "type": ["string", "null"] },
          "thinking": { "type": "boolean" },
          "thinking_updated_at": { "type": "string", "format": "date-time" },
          "working_on": { "type": ["string", "null"] },
          "next_step": { "type": ["string", "null"] },
          "context": {
            "type": "object",
            "properties": {
              "updated_at": { "type": "string", "format": "date-time" }
            }
          }
        },
        "required": ["state", "thinking"]
      }
    }
  },
  "required": ["version", "projects"]
}
```

### hud-stats-cache.json
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "version": { "type": "integer", "const": 1 },
    "projects": {
      "type": "object",
      "additionalProperties": {
        "type": "object",
        "properties": {
          "files": {
            "type": "object",
            "additionalProperties": {
              "type": "object",
              "properties": {
                "size": { "type": "integer" },
                "mtime": { "type": "integer" }
              },
              "required": ["size", "mtime"]
            }
          },
          "stats": { "$ref": "#/definitions/ProjectStats" }
        },
        "required": ["files", "stats"]
      }
    }
  },
  "required": ["version", "projects"],
  "definitions": {
    "ProjectStats": {
      "type": "object",
      "properties": {
        "session_count": { "type": "integer" },
        "total_input_tokens": { "type": "integer" },
        "total_output_tokens": { "type": "integer" },
        "total_cache_read_tokens": { "type": "integer" },
        "total_cache_creation_tokens": { "type": "integer" },
        "opus_messages": { "type": "integer" },
        "sonnet_messages": { "type": "integer" },
        "haiku_messages": { "type": "integer" },
        "first_activity": { "type": "string" },
        "last_activity": { "type": "string" },
        "latest_summary": { "type": "string" }
      }
    }
  }
}
```

---

## Appendix B: Sequence Diagrams

### Project List Loading

```
┌─────────┐          ┌───────────┐          ┌──────────┐          ┌─────────┐
│  Client │          │ HudEngine │          │ projects │          │  stats  │
└────┬────┘          └─────┬─────┘          └────┬─────┘          └────┬────┘
     │                     │                     │                     │
     │  list_projects()    │                     │                     │
     │────────────────────>│                     │                     │
     │                     │                     │                     │
     │                     │  load_config()      │                     │
     │                     │────────────────────>│                     │
     │                     │                     │                     │
     │                     │  Vec<path>          │                     │
     │                     │<────────────────────│                     │
     │                     │                     │                     │
     │                     │  for each path:     │                     │
     │                     │  get_stats(path)    │                     │
     │                     │─────────────────────────────────────────>│
     │                     │                     │                     │
     │                     │                     │   check cache       │
     │                     │                     │   (mtime compare)   │
     │                     │                     │                     │
     │                     │  ProjectStats       │                     │
     │                     │<─────────────────────────────────────────│
     │                     │                     │                     │
     │  Vec<Project>       │                     │                     │
     │<────────────────────│                     │                     │
     │                     │                     │                     │
```

### State Change Detection (TUI Polling)

```
┌─────────┐          ┌───────────┐          ┌─────────────────┐
│   TUI   │          │ HudEngine │          │ hud-session-states.json │
└────┬────┘          └─────┬─────┘          └────────┬────────┘
     │                     │                         │
     │  [every 2 seconds]  │                         │
     │                     │                         │
     │  get_session_states()                         │
     │────────────────────>│                         │
     │                     │                         │
     │                     │  read file              │
     │                     │────────────────────────>│
     │                     │                         │
     │                     │  JSON content           │
     │                     │<────────────────────────│
     │                     │                         │
     │                     │  parse & return         │
     │                     │                         │
     │  HashMap<path, state>                         │
     │<────────────────────│                         │
     │                     │                         │
     │  compare with       │                         │
     │  previous states    │                         │
     │                     │                         │
     │  if changed:        │                         │
     │  trigger flash      │                         │
     │  animation          │                         │
     │                     │                         │
```
