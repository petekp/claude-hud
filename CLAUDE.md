# Claude HUD - Project Development Guide

Claude HUD is a cross-platform desktop application that serves as a dashboard for Claude Code, displaying project statistics, task tracking, plugin management, and global Claude Code configuration insights. It features multiple frontends sharing a common Rust core:

- **Tauri App** (apps/tauri) - Cross-platform desktop app with React frontend
- **Swift App** (apps/swift) - Native macOS app with SwiftUI, 120Hz animations

> **Development Workflow:** For the Tauri app, run `cd apps/tauri && pnpm tauri dev`. For the Swift app, run `cd apps/swift && swift build`. Changes auto-rebuild and hot-reload.

## Session Startup Checklist

When starting a development session on this project:

1. **Run the Swift HUD in background:** `cd apps/swift && swift run &`
2. **Rebuild after Swift changes:** If you modify Swift code or regenerate UniFFI bindings, rebuild with `cd apps/swift && swift build` then restart with `swift run &`
3. **State tracking is automatic:** Hooks in `~/.claude/settings.json` track thinking state. Just run `claude` normally.

## Product Vision

**Claude HUD lets you develop and ship more projects in parallel by eliminating the cognitive overhead of context-switching.** Instead of remembering where you left off across a dozen projects, the HUD shows you—automatically, at a glance. Wake up, open the app, pick a project, and resume instantly.

**The core problem:** When you have many Claude Code projects in flight simultaneously, context-switching is expensive. You lose track of what you were working on, what the next step was, and whether you're blocked. Without visibility, projects stall and momentum is lost. The cognitive load of "remembering where everything is at" limits how many projects you can realistically push forward.

**The insight:** Claude already knows what you were doing in each project. The HUD surfaces that context automatically via hooks—so you don't have to maintain a separate system or hold it all in your head.

**Target use case:** You wake up, open Claude HUD, see all your projects with their current status, know exactly where each one stands, pick the one that makes sense to work on, and jump in with full context—in seconds, not minutes.

## Project Overview

**Multi-Platform Architecture:**

```
┌─────────────────────────────────────────────────────────────┐
│                    Frontend Clients                         │
│  ┌─────────────────────┐  ┌─────────────────────────────┐  │
│  │ Tauri (apps/tauri)  │  │ Swift (apps/swift)          │  │
│  │ React 19 + Tailwind │  │ SwiftUI + 120Hz ProMotion   │  │
│  └──────────┬──────────┘  └──────────────┬──────────────┘  │
└─────────────┼────────────────────────────┼──────────────────┘
              │ Tauri IPC                  │ UniFFI
              ▼                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    hud-core (core/hud-core)                 │
│  Shared Rust library: projects, sessions, stats, artifacts │
└─────────────────────────────────────────────────────────────┘
```

**Tauri App** (`apps/tauri/`):
- Frontend: React 19 + TypeScript + Tailwind CSS 4 (`src/`)
- Backend: Rust + Tauri v2.9.5 (`src-tauri/`)
- Cross-platform: macOS, Windows, Linux

**Swift App** (`apps/swift/`):
- Native SwiftUI for macOS 14+
- UniFFI bindings to hud-core
- 120Hz ProMotion animations

**Shared Core** (`core/hud-core/`):
- Pure Rust library with all business logic
- Project scanning, session state, statistics, artifacts
- Exports via UniFFI for Swift, Tauri IPC for React

## Development Workflow

### Quick Start

**IMPORTANT: Keep apps running during development.** Changes auto-rebuild and hot-reload.

#### Tauri App (from `apps/tauri/`)
```bash
cd apps/tauri
pnpm install      # First time only
pnpm tauri dev    # Launch with hot reload
```

#### Swift App (from `apps/swift/`)
```bash
cargo build -p hud-core --release  # Build Rust library first
cd apps/swift
swift build       # Debug build
swift run         # Run the app
```

### Common Commands

#### Rust Core (from root)
```bash
cargo check --workspace    # Check all crates
cargo build --workspace    # Build all crates
cargo build -p hud-core --release  # Build core for Swift
cargo fmt                  # Format code (required before commits)
cargo clippy -- -D warnings  # Lint
cargo test                 # Run all tests
```

#### Tauri App (from `apps/tauri/`)
```bash
pnpm dev          # Start frontend dev server
pnpm build        # Build frontend for production
pnpm tauri dev    # Launch app in dev mode
pnpm tauri build  # Build app for distribution
pnpm lint         # Run ESLint
```

#### Swift App (from `apps/swift/`)
```bash
swift build             # Debug build
swift build -c release  # Release build
swift run               # Run the app
```

### Building for Distribution

#### Tauri App
```bash
cd apps/tauri
pnpm tauri build --target aarch64-apple-darwin  # macOS Apple Silicon
pnpm tauri build --target x86_64-apple-darwin   # macOS Intel
pnpm tauri build --target x86_64-pc-windows-msvc # Windows
```
Built apps appear in `apps/tauri/src-tauri/target/release/bundle/`.

#### Swift App
```bash
cargo build -p hud-core --release
cd apps/swift
swift build -c release
# Create .app bundle manually or use xcodebuild
```

## Project Structure

This is a **Cargo workspace** with a shared core and multiple app frontends:

```
claude-hud/
├── CLAUDE.md                    # This file
├── Cargo.toml                   # Workspace manifest
├── core/
│   └── hud-core/                # Shared Rust core library
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs           # Re-exports + UniFFI scaffolding
│           ├── engine.rs        # HudEngine facade
│           ├── types.rs         # Shared types (UniFFI exported)
│           ├── error.rs         # Error types (UniFFI exported)
│           ├── patterns.rs      # Compiled regex patterns
│           ├── config.rs        # Config and path utilities
│           ├── stats.rs         # Statistics parsing and caching
│           ├── projects.rs      # Project loading and discovery
│           ├── sessions.rs      # Session state detection
│           └── artifacts.rs     # Artifact discovery
├── apps/
│   ├── tauri/                   # Tauri desktop app (cross-platform)
│   │   ├── package.json         # Frontend dependencies
│   │   ├── vite.config.ts       # Vite bundler config
│   │   ├── tsconfig.json        # TypeScript configuration
│   │   ├── index.html           # HTML entry point
│   │   ├── src/                 # React frontend
│   │   │   ├── main.tsx
│   │   │   ├── App.tsx
│   │   │   ├── types.ts
│   │   │   ├── index.css
│   │   │   ├── components/
│   │   │   ├── hooks/
│   │   │   └── utils/
│   │   └── src-tauri/           # Rust backend
│   │       ├── Cargo.toml
│   │       ├── src/lib.rs       # IPC command handlers
│   │       ├── tauri.conf.json
│   │       └── icons/
│   ├── swift/                   # Native macOS app
│   │   ├── Package.swift        # Swift Package Manager config
│   │   ├── Sources/
│   │   │   ├── ClaudeHUD/       # SwiftUI app
│   │   │   │   ├── App.swift
│   │   │   │   ├── ContentView.swift
│   │   │   │   ├── Models/
│   │   │   │   ├── Views/
│   │   │   │   └── Theme/
│   │   │   └── HudCoreFFI/      # FFI module wrapper
│   │   └── bindings/            # Generated UniFFI bindings
│   │       ├── hud_core.swift
│   │       └── hud_coreFFI.h
│   └── daemon/                  # HUD daemon (TypeScript)
│       ├── package.json
│       ├── tsconfig.json
│       └── src/
│           ├── sdk/             # Claude Code SDK (stream-json)
│           ├── daemon/          # State tracking & relay
│           └── cli/             # hud-claude entry point
├── target/                      # Shared Rust build output
├── .claude/
│   └── docs/                    # Project architecture documentation
├── docs/
│   ├── claude-code-artifacts.md # Claude Code disk artifacts reference
│   ├── claude-code/             # Claude Code CLI documentation
│   ├── agent-sdk/               # Claude Agent SDK documentation
│   └── architecture-decisions/  # ADRs
└── scripts/
    ├── fetch-cc-docs.ts         # Fetch Claude Code docs from GitHub
    └── fetch-agent-sdk-docs.ts  # Fetch Agent SDK docs (requires Playwright)
```

## Frontend Architecture (React 19)

The Tauri frontend is a **modular React application** in `apps/tauri/src/`. It communicates with the Rust backend exclusively through Tauri IPC.

### Key Files

| File | Purpose |
|------|---------|
| `apps/tauri/src/App.tsx` | State, event handlers, top-level layout |
| `apps/tauri/src/types.ts` | TypeScript interfaces (must match Rust structs) |
| `apps/tauri/src/index.css` | Tailwind CSS theme with oklch colors |
| `apps/tauri/src/hooks/*.ts` | Custom hooks for window, theme, focus, audio |
| `apps/tauri/src/utils/*.ts` | Formatting and pricing utilities |
| `apps/tauri/src/components/panels/*.tsx` | Panel components (Projects, Details, Add, Artifacts) |

### Architecture

- **State Management:** React `useState` hooks (no external state library)
- **IPC:** `invoke()` from `@tauri-apps/api/core` for commands
- **Events:** `listen()` from `@tauri-apps/api/event` for backend events
- **UI Components:** shadcn/ui (Radix primitives + Tailwind CSS)
- **Styling:** Tailwind CSS 4 with oklch color scheme, dark mode via system preference
- **Custom Hooks:** Window persistence, theme detection, focus-on-hover, notification sounds

### Navigation

Tab-based navigation with internal view states:
- `Tab = "projects" | "artifacts"`
- `ProjectView = "list" | "detail" | "add"`

### Panel Components (in `src/components/panels/`)

| Component | Purpose |
|-----------|---------|
| `ProjectsPanel` | List of pinned projects with stats |
| `ProjectDetailPanel` | Project details, sessions, CLAUDE.md content |
| `AddProjectPanel` | Add projects via drag-drop, browse, or suggestions |
| `ArtifactsPanel` | Browse skills, commands, agents, and manage plugins |

### Type Safety

TypeScript interfaces in `src/types.ts` **must match** Rust struct definitions in `lib.rs`:

```typescript
// Frontend (src/types.ts)
export interface ProjectStats {
  total_input_tokens: number;
  total_output_tokens: number;
  // ... must match Rust exactly
}
```

```rust
// Backend (src-tauri/src/lib.rs)
pub struct ProjectStats {
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    // ... serialized to JSON
}
```

## Backend Architecture (Rust/Tauri)

The backend uses a **two-layer architecture**:

1. **`hud-core`** - Shared core library with all business logic (in `core/hud-core/`)
2. **Tauri app** - Thin IPC wrappers that delegate to hud-core (in `apps/tauri/src-tauri/`)
3. **Swift app** - UniFFI bindings to hud-core (in `apps/swift/`)

This design enables multiple clients (Tauri desktop, Swift native, TUI) to share the same business logic.

### hud-core Modules (in `core/hud-core/src/`)

| Module | Purpose |
|--------|---------|
| `engine.rs` | `HudEngine` facade - unified API for all clients |
| `types.rs` | Shared types: Project, Task, Artifact, Plugin, etc. |
| `patterns.rs` | Pre-compiled regex patterns for JSONL parsing |
| `config.rs` | Path resolution and config file operations |
| `stats.rs` | Token usage parsing and mtime-based caching |
| `projects.rs` | Project loading, discovery, and indicators |
| `sessions.rs` | Session state detection and status reading |
| `artifacts.rs` | Artifact discovery and frontmatter parsing |
| `error.rs` | Error types and Result alias |

### Tauri App (in `apps/tauri/src-tauri/src/`)

| File | Purpose |
|------|---------|
| `lib.rs` | IPC command handlers (~1,620 lines) - thin wrappers over `HudEngine` |
| `bin/hud-tui.rs` | Terminal UI (~500 lines) - uses `hud-core` directly |

### Swift App (in `apps/swift/`)

| File | Purpose |
|------|---------|
| `Sources/ClaudeHUD/App.swift` | SwiftUI app entry point |
| `Sources/ClaudeHUD/Models/AppState.swift` | State management with HudEngine bridge |
| `Sources/ClaudeHUD/Views/` | SwiftUI views (Projects, Artifacts, etc.) |
| `bindings/hud_core.swift` | Generated UniFFI Swift bindings |

### Data Structures (in `hud-core/types.rs`)
- **GlobalConfig:** Claude Code global settings (skills, commands, agents directories)
- **Project/ProjectDetails/Task:** Project tracking and session management
- **ProjectStats:** Token usage analytics and caching
- **Plugin:** Plugin registry with artifact counts
- **HudConfig:** Pinned projects persistent state

### Key Functions (in hud-core)

**Configuration & Paths (`config.rs`):**
- `get_claude_dir()` - Resolves `~/.claude` directory
- `load_hud_config()` / `save_hud_config()` - Pinned projects persistence
- `load_stats_cache()` / `save_stats_cache()` - Token stats caching

**Statistics & Parsing (`stats.rs`):**
- `parse_stats_from_content()` - Regex extraction from JSONL session files
- `compute_project_stats()` - Intelligent caching with file mtime tracking
- Tracks input/output tokens, cache tokens, model usage (Opus/Sonnet/Haiku)

**Project Discovery (`projects.rs`):**
- `has_project_indicators()` - Detects project types (.git, package.json, Cargo.toml, etc.)
- `build_project_from_path()` - Constructs Project objects
- `load_projects()` - Loads pinned projects sorted by activity

**Session State (`sessions.rs`):**
- `detect_session_state()` - Determines current state (working, ready, idle, etc.)
- `read_project_status()` - Reads status from `~/.claude/hud-session-states.json`

**HudEngine Facade (`engine.rs`):**
- `HudEngine::new()` - Creates engine instance
- `list_projects()`, `add_project()`, `remove_project()` - Project management
- `list_artifacts()`, `list_plugins()` - Artifact discovery
- `load_dashboard()` - All dashboard data in one call

**Session Summarization (in Tauri `lib.rs`):**
- `generate_session_summary_sync()` - Summary generation via Claude CLI
- `start_background_summaries()` - Background thread-based generation
- Caches in `~/.claude/hud-summaries.json`

### IPC Commands (Tauri `lib.rs` - thin wrappers)

| Command | Purpose | Returns |
|---------|---------|---------|
| `load_dashboard` | All dashboard data | `DashboardData` |
| `load_projects` | Pinned projects only | `Vec<Project>` |
| `load_project_details` | Project with tasks and git status | `ProjectDetails` |
| `load_artifacts` | All skills/commands/agents | `Vec<Artifact>` |
| `toggle_plugin` | Enable/disable plugins | `()` |
| `read_file_content` | Read arbitrary files | `String` |
| `open_in_editor` / `open_folder` / `launch_in_terminal` | Platform-specific operations | `()` |
| `add_project` / `remove_project` | Manage pinned projects | `()` |
| `load_suggested_projects` | Discover projects with activity | `Vec<SuggestedProject>` |
| `generate_session_summary` | On-demand summary generation | `String` |
| `start_background_summaries` / `start_background_project_summaries` | Background tasks | `()` |

### Key Patterns

**Error Handling:**
- Functions return `Result<T, String>` for Tauri IPC compatibility
- File operations gracefully degrade (return empty defaults on missing files)

**Caching:**
- Stats cache uses mtime-based invalidation
- Summary cache persists generated summaries to avoid re-computation

**Threading:**
- `std::thread::spawn()` for background tasks
- `app_handle.emit()` sends events back to frontend

## State Tracking Architecture

**Current approach:** Hooks for local TUI sessions, daemon reserved for future remote/mobile use.

See [ADR-001: State Tracking Approach](docs/architecture-decisions/001-state-tracking-approach.md) for the full decision rationale.

### Local Sessions (Current)

For interactive TUI sessions, we use Claude Code hooks:

```
User runs claude → Hooks fire → State file updated → Swift HUD reads
```

**Hooks configured:**
- `UserPromptSubmit` → thinking: true, state: working
- `PostToolUse` → heartbeat (maintains thinking: true)
- `Stop` → thinking: false, state: ready
- `Notification` (idle_prompt) → thinking: false, state: ready

**State file:** `~/.claude/hud-session-states.json`

**Hook script:** `~/.claude/scripts/hud-state-tracker.sh`

### HUD Daemon (Future Remote Use)

The daemon in `apps/daemon/` provides **precise state tracking** via `--output-format stream-json`. It's reserved for future mobile/remote client integration.

**Why not use daemon for local?** Claude's `--output-format stream-json` replaces the TUI with JSON output. You can't have both Claude's interactive TUI and structured JSON from the same process.

**When to use daemon:**
- Building mobile client relay integration
- Programmatic/scripted Claude interactions
- Testing state tracking precision

```bash
# Build daemon (if needed)
cd apps/daemon && npm install && npm run build

# Run daemon (JSON output, no TUI)
hud-claude-daemon -p "explain this code"
```

For detailed daemon design, see `docs/hud-daemon-design.md`.

## Runtime Configuration

The app reads from `~/.claude/` directory:

```
~/.claude/
├── settings.json                  # Global Claude Code config
├── hud.json                       # Pinned projects
├── hud-stats-cache.json           # Cached token usage
├── hud-summaries.json             # Session summaries cache
├── hud-project-summaries.json     # Project overview bullets
├── projects/                      # Session files ({encoded-path}/{sessionid}.jsonl)
└── plugins/installed_plugins.json # Plugin registry
```

For a comprehensive reference of all Claude Code disk artifacts (file formats, data structures, retention policies), see **[docs/claude-code-artifacts.md](docs/claude-code-artifacts.md)**.

## Documentation

This project has comprehensive documentation organized by purpose. Use this guide to find the right docs for your task.

### Quick Reference: Where to Look

| If you need to... | Look in |
|-------------------|---------|
| Implement hooks, plugins, MCP, or settings | `docs/claude-code/` |
| Build programmatic SDK integrations | `docs/agent-sdk/` |
| Understand HUD architecture decisions | `.claude/docs/` |
| Review ADRs (Architecture Decision Records) | `docs/architecture-decisions/` |
| Understand Claude Code disk artifacts | `docs/claude-code-artifacts.md` |

### Claude Code CLI Documentation (`docs/claude-code/`)

Official Claude Code documentation for integrating with hooks, plugins, settings, MCP, and sessions.

| Topic | File | Use When |
|-------|------|----------|
| Hooks | `hooks.md` | Implementing hook-based features |
| Plugins | `plugins.md` | Plugin management, discovery |
| Settings | `settings.md` | Reading/displaying Claude Code config |
| MCP | `mcp.md` | Model Context Protocol integration |
| Sessions | `interactive-mode.md` | Session file parsing, history |
| CLI | `cli-reference.md` | Invoking Claude Code programmatically |
| Memory | `memory.md` | CLAUDE.md files, project context |
| Sub-agents | `sub-agents.md` | Task tool, agent spawning |

**Update:** `npx tsx scripts/fetch-cc-docs.ts` (sources: anthropics/claude-code, ericbuess/claude-code-docs)

### Agent SDK Documentation (`docs/agent-sdk/`)

TypeScript/Python SDK for programmatic Claude Code integration. Use this for building automated tools, custom clients, or SDK-based features.

| Topic | File | Use When |
|-------|------|----------|
| Overview | `overview.md` | Understanding SDK capabilities |
| Sessions | `sessions.md` | Session management, resumption, forking |
| Hooks | `hooks.md` | SDK hooks (PreToolUse, PostToolUse, etc.) |
| Subagents | `subagents.md` | Creating and invoking subagents |
| Permissions | `permissions.md` | Permission modes, tool access control |
| Custom Tools | `custom-tools.md` | Creating custom MCP tools |
| TypeScript | `typescript.md` | Full TypeScript API reference |
| Python | `python.md` | Full Python API reference |
| Migration | `migration-guide.md` | Migrating from CLI to SDK |

**Update:** `npx tsx scripts/fetch-agent-sdk-docs.ts` (requires Playwright)

### Project Architecture (`.claude/docs/`)

HUD-specific architecture documents, design decisions, and feature specs.

| Document | Purpose |
|----------|---------|
| `status-sync-architecture.md` | Real-time status sync between Claude sessions and HUD clients |
| `multi-platform-architecture.md` | Tauri/Swift/TUI sharing hud-core |
| `agent-sdk-migration-guide.md` | Migration strategy from CLI to Agent SDK |
| `feature-idea-to-v1-launcher.md` | TDD feature spec for "Idea → V1 Launcher" |

### ADRs (`docs/architecture-decisions/`)

Architecture Decision Records documenting key technical decisions.

| ADR | Decision |
|-----|----------|
| `001-state-tracking-approach.md` | Hooks for local sessions, daemon for remote/mobile |

### Maintaining Documentation

When working on this project, follow this organizational scheme:

| Content Type | Location | When to Use |
|--------------|----------|-------------|
| Task list (what to do) | `TODO.md` | Adding/completing tasks |
| Completed work | `DONE.md` | Archiving finished work |
| Feature specs | `.claude/docs/feature-*.md` | Planning complex features |
| Architecture docs | `.claude/docs/*-architecture.md` | Documenting system design |
| Sprint plans | `.claude/plans/` | Planning milestones |
| Decision records | `docs/architecture-decisions/` | Recording key decisions |

**Rules for TODO.md:**
- Keep it scannable (< 100 lines of active work)
- Only unchecked `[ ]` items belong here
- Move completed items to `DONE.md` promptly
- Link to detailed specs rather than embedding them
- Use sections: 🎯 Active → 📋 Next → 💡 Backlog

**Rules for .claude/docs/:**
- Feature specs: `feature-{name}.md`
- Architecture: `{system}-architecture.md`
- Guides: `{topic}-guide.md`
- Keep updated when implementation diverges from spec

## Common Development Scenarios

### Adding a New Dashboard Tab (Tauri)

1. **Backend:** Add `#[tauri::command]` function in `apps/tauri/src-tauri/src/lib.rs`
2. **Backend:** Register in `invoke_handler`
3. **Frontend:** Add to `Tab` type union in `apps/tauri/src/App.tsx`
4. **Frontend:** Create panel component in `apps/tauri/src/components/panels/`
5. **Types:** Ensure TypeScript types in `apps/tauri/src/types.ts` match Rust structs

### Adding a New View (Swift)

1. **Create view:** Add SwiftUI view in `apps/swift/Sources/ClaudeHUD/Views/`
2. **Update state:** Add published properties to `AppState.swift` if needed
3. **Wire up:** Add navigation in `ContentView.swift`

### Modifying Statistics Parsing
- Update regex patterns in `parse_stats_from_content()` (`core/hud-core/src/stats.rs`)
- Update `ProjectStats` struct in `core/hud-core/src/types.rs` and `apps/tauri/src/types.ts`
- Delete `~/.claude/hud-stats-cache.json` to force recomputation

### Adding Project Type Detection
- Modify `has_project_indicators()` (`core/hud-core/src/projects.rs`)
- Add file/directory checks for new project type

### Regenerating Swift Bindings
```bash
cd core/hud-core
cargo run --bin uniffi-bindgen generate src/lib.rs --language swift --out-dir ../../apps/swift/bindings/
```

### Running the TUI
```bash
cargo run --bin hud-tui
```
The TUI provides a terminal-based interface using the same `hud-core` library.

## Code Style & Conventions

**Backend (Rust):**
- Use `cargo fmt` for formatting (required)
- Run `cargo clippy -- -D warnings` for linting
- Prefer easy-to-read code over clever code
- No extraneous comments; code should be self-documenting

**Frontend (TypeScript/React):**
- No IIFEs in React components
- ESLint configured in project
- TypeScript strict mode enabled
- Prefer easy-to-read code over clever code

## Debugging

**Backend:**
```bash
# Inspect cache files
cat ~/.claude/hud-stats-cache.json | jq .

# Enable debug logging
RUST_LOG=debug pnpm tauri dev

# Test regex patterns
echo '{"input_tokens":1234}' | rg 'input_tokens":(\d+)'
```

**Frontend:**
- Chrome DevTools via right-click "Inspect" in app window
- Check browser console for IPC errors

## Key Dependencies

**Frontend:**
- React 19 - UI framework
- TypeScript - Type safety
- Vite - Build tool
- Tailwind CSS 4 - Styling
- Radix UI - Accessible primitives
- Tauri API - IPC bridge

**Backend:**
- Tauri 2.9.5 - Desktop app framework
- Serde - JSON serialization
- Regex - Pattern matching in session files
- Walkdir - Directory traversal
- Dirs - Platform-specific paths

## Important Notes

- **Workspace Structure:** This is a Cargo workspace with `core/hud-core` (shared library), `apps/tauri/src-tauri` (Tauri app). Use `cargo build --workspace` to build all crates.
- **Multi-Client Architecture:** Tauri desktop, Swift native, and TUI all use `hud-core` for shared business logic
- **UniFFI Bindings:** Swift app uses UniFFI-generated bindings in `apps/swift/bindings/`
- **Path Encoding:** Project paths use `/` → `-` replacement (e.g., `/Users/peter/Code` → `-Users-peter-Code`)
- **IPC Communication:** Tauri frontend must go through Tauri commands; Swift uses UniFFI directly
- **Caching Strategy:** Mtime-based invalidation; old cache entries are harmless
- **Platform Support:** Tauri handles Windows, macOS (Intel/ARM), and Linux; Swift is macOS-only
- **Claude CLI Path:** Summary generation uses `/opt/homebrew/bin/claude` (macOS Homebrew)

For detailed Tauri backend documentation, refer to `apps/tauri/src-tauri/CLAUDE.md`.
