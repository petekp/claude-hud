# Activity-Based Project Tracking

> **Status:** Design Complete, Ready for Implementation
> **Created:** 2026-01-16
> **Approach:** TDD with Rust best practices
> **⚠️ Migration Note:** This plan was written pre-Capacitor migration. Implementation should use `~/.capacitor/` paths (see `ACTIVE-capacitor-global-storage.md`). Phase 5 should update the Rust hook handler (`core/hud-hook/`) instead of bash script.

## Problem Statement

When Claude Code runs from a monorepo root but edits files in specific packages, the HUD shows all child packages as "Idle" because state tracking is based on `cwd` (where Claude started), not where Claude is actually working.

**Example:**
- User pins `/monorepo/packages/auth`
- Claude runs from `/monorepo`
- Claude edits files in `packages/auth/src/login.ts`
- HUD shows `packages/auth` as **Idle** ❌

**Expected:** HUD should show `packages/auth` as **Working** ✓

## Solution Overview

Track **file activity** in addition to session `cwd`. Attribute activity to the nearest **project boundary** (detected by CLAUDE.md, .git, package.json, etc.).

### Key Components

1. **Project Boundary Detection** — Walk up from file path to find nearest project marker
2. **File Activity Tracking** — Record which projects have recent file edits
3. **Smart Project Validation** — Guide users to pin at correct boundaries, offer CLAUDE.md creation
4. **State Resolution Changes** — Use file activity to determine project state

---

## Design Details

### 1. Project Boundary Detection

#### Project Markers (Priority Order)

| Marker | Meaning | Priority |
|--------|---------|----------|
| `CLAUDE.md` | Explicit project declaration | 1 (highest) |
| `.git` directory | Repository root | 2 |
| `package.json` | Node.js package | 3 |
| `Cargo.toml` | Rust crate | 3 |
| `pyproject.toml` | Python project | 3 |
| `go.mod` | Go module | 3 |

#### Ignored Directories (Skip During Walk)

- `node_modules`
- `vendor`
- `.git` (the directory itself, not as a marker)
- `__pycache__`
- `target`
- `dist`, `build`, `.next`, `.output`
- `venv`, `.venv`, `env`

#### Algorithm

```
find_project_boundary(file_path: &str) -> Option<String>:
    current = parent_of(file_path)
    depth = 0

    while current != "/" and depth < MAX_DEPTH:
        if is_ignored_directory(current):
            current = parent_of(current)
            continue

        if has_claude_md(current):
            return Some(current)  // Highest priority

        if has_git_directory(current):
            return Some(current)  // Second priority

        if has_package_marker(current):  // package.json, Cargo.toml, etc.
            candidate = current
            // Continue walking to find .git or CLAUDE.md

        current = parent_of(current)
        depth += 1

    return candidate or None
```

#### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Symlink path | Resolve to canonical path before walking |
| Path doesn't exist | Return None |
| Root directory | Stop at `/`, return None |
| Home directory | Stop at `~` as a boundary |
| Nested .git (submodule) | Nearest .git wins |
| Multiple package.json (monorepo) | Nearest wins, but .git/CLAUDE.md override |

### 2. File Activity Tracking

#### State File

Location: `~/.claude/hud-file-activity.json`

```json
{
  "version": 1,
  "sessions": {
    "session-uuid-1": {
      "cwd": "/Users/pete/Code/monorepo",
      "pid": 12345,
      "activity": [
        {
          "project_path": "/Users/pete/Code/monorepo/packages/auth",
          "file_path": "/Users/pete/Code/monorepo/packages/auth/src/login.ts",
          "tool": "Edit",
          "timestamp": "2026-01-16T18:30:00Z"
        }
      ]
    }
  }
}
```

#### Activity Window

- **Active threshold:** 5 minutes (configurable)
- **Cleanup:** Remove entries older than 1 hour
- **Debounce:** Batch writes, max 1 write per 500ms

#### Data Flow

```
PostToolUse hook fires
    ↓
Extract file_path from tool_input (Edit, Write, Read)
    ↓
Resolve to absolute path
    ↓
Find project boundary for file
    ↓
Write to hud-file-activity.json
    ↓
HUD reads activity file
    ↓
Match pinned projects against activity
```

### 3. Smart Project Validation

#### Validation Result

```rust
pub enum ValidationResult {
    Valid {
        path: String,
        has_claude_md: bool,
    },
    SuggestParent {
        requested_path: String,
        suggested_path: String,
        reason: String,  // "Inside project at {suggested_path}"
    },
    MissingClaudeMd {
        path: String,
        has_other_markers: bool,  // .git, package.json, etc.
    },
    NotAProject {
        path: String,
        reason: String,  // "No project markers found"
    },
    PathNotFound {
        path: String,
    },
    DangerousPath {
        path: String,
        reason: String,  // "Would encompass many projects"
    },
}
```

#### Validation Flow

```
User selects path
    ↓
Canonicalize path (resolve symlinks, normalize case)
    ↓
Check if path exists → PathNotFound if not
    ↓
Check for dangerous paths (/, ~, /Users) → DangerousPath if so
    ↓
Find project boundary for path
    ↓
If boundary == path:
    If has CLAUDE.md → Valid
    Else → MissingClaudeMd
    ↓
If boundary != path (path is inside boundary):
    → SuggestParent
    ↓
If no boundary found:
    → NotAProject
```

### 4. State Resolution Changes

#### New Resolution Logic

```rust
fn resolve_project_state(project_path: &str) -> SessionState {
    // 1. Check for direct session (cwd matches or is child of project)
    if let Some(session) = find_direct_session(project_path) {
        return session.state;  // Working, Ready, Blocked, etc.
    }

    // 2. Check for file activity in this project
    if has_recent_file_activity(project_path, ACTIVITY_THRESHOLD) {
        return SessionState::Working;  // Active file edits
    }

    // 3. Check for parent session (session cwd is parent of project)
    if has_parent_session(project_path) {
        return SessionState::Ready;  // Session nearby, could work here
    }

    // 4. No relevant sessions
    SessionState::Idle
}
```

#### State Meanings (Updated)

| State | Meaning | Visual |
|-------|---------|--------|
| **Working** | Session cwd here OR recent file activity here | 🟢 Solid green, pulsing |
| **Ready** | Session finished, waiting for input | 🟢 Solid green, static |
| **Blocked** | Waiting for permission | 🟡 Yellow |
| **Session Nearby** | Parent has session, no local activity | 🔵 Blue outline (new) |
| **Idle** | No relevant sessions | ⚫ Gray |

---

## Implementation Plan

### Phase 1: Project Boundary Detection (Rust Core)

**Module:** `core/hud-core/src/boundaries.rs`

#### Test Cases (TDD)

```rust
#[cfg(test)]
mod tests {
    // Basic detection
    #[test]
    fn finds_claude_md_as_boundary() { }

    #[test]
    fn finds_git_directory_as_boundary() { }

    #[test]
    fn finds_package_json_as_boundary() { }

    #[test]
    fn claude_md_takes_priority_over_git() { }

    #[test]
    fn git_takes_priority_over_package_json() { }

    // Walking behavior
    #[test]
    fn walks_up_from_deeply_nested_file() { }

    #[test]
    fn stops_at_max_depth() { }

    #[test]
    fn stops_at_root() { }

    #[test]
    fn stops_at_home_directory() { }

    // Ignored directories
    #[test]
    fn skips_node_modules() { }

    #[test]
    fn skips_vendor() { }

    #[test]
    fn skips_target() { }

    // Edge cases
    #[test]
    fn handles_nonexistent_path() { }

    #[test]
    fn handles_symlink_resolution() { }

    #[test]
    fn handles_path_normalization() { }

    #[test]
    fn handles_git_submodule() { }

    #[test]
    fn handles_monorepo_nested_packages() { }

    // Dangerous paths
    #[test]
    fn detects_root_as_dangerous() { }

    #[test]
    fn detects_home_as_dangerous() { }

    #[test]
    fn detects_users_as_dangerous() { }
}
```

### Phase 2: File Activity Tracking (Rust Core)

**Module:** `core/hud-core/src/activity.rs`

#### Test Cases (TDD)

```rust
#[cfg(test)]
mod tests {
    // Basic tracking
    #[test]
    fn records_file_activity() { }

    #[test]
    fn attributes_activity_to_correct_project() { }

    #[test]
    fn tracks_multiple_projects_per_session() { }

    // Activity window
    #[test]
    fn activity_within_threshold_is_active() { }

    #[test]
    fn activity_beyond_threshold_is_inactive() { }

    #[test]
    fn cleans_up_old_entries() { }

    // Queries
    #[test]
    fn finds_active_projects_for_session() { }

    #[test]
    fn checks_if_project_has_recent_activity() { }

    // State file
    #[test]
    fn loads_existing_state_file() { }

    #[test]
    fn creates_state_file_if_missing() { }

    #[test]
    fn handles_corrupted_state_file() { }

    #[test]
    fn atomic_write_prevents_corruption() { }

    // Performance
    #[test]
    fn debounces_rapid_writes() { }

    #[test]
    fn caches_boundary_lookups() { }
}
```

### Phase 3: Smart Project Validation (Rust Core)

**Module:** `core/hud-core/src/validation.rs`

#### Test Cases (TDD)

```rust
#[cfg(test)]
mod tests {
    // Valid projects
    #[test]
    fn valid_with_claude_md() { }

    #[test]
    fn valid_with_git_only() { }

    // Suggestions
    #[test]
    fn suggests_parent_when_inside_project() { }

    #[test]
    fn suggests_package_root_not_src_directory() { }

    // Missing CLAUDE.md
    #[test]
    fn detects_missing_claude_md_with_git() { }

    #[test]
    fn detects_missing_claude_md_with_package_json() { }

    // Not a project
    #[test]
    fn detects_random_directory() { }

    #[test]
    fn detects_tmp_directory() { }

    // Dangerous paths
    #[test]
    fn warns_on_root() { }

    #[test]
    fn warns_on_home() { }

    #[test]
    fn warns_on_volumes() { }

    // Path handling
    #[test]
    fn resolves_symlinks() { }

    #[test]
    fn normalizes_trailing_slashes() { }

    #[test]
    fn handles_tilde_expansion() { }

    #[test]
    fn handles_case_insensitivity_on_macos() { }
}
```

### Phase 4: CLAUDE.md Generation (Rust Core)

**Module:** `core/hud-core/src/claude_md.rs`

#### Test Cases (TDD)

```rust
#[cfg(test)]
mod tests {
    // Template generation
    #[test]
    fn generates_basic_template() { }

    #[test]
    fn extracts_name_from_package_json() { }

    #[test]
    fn extracts_description_from_package_json() { }

    #[test]
    fn extracts_name_from_cargo_toml() { }

    #[test]
    fn extracts_from_readme() { }

    // File creation
    #[test]
    fn creates_claude_md_file() { }

    #[test]
    fn does_not_overwrite_existing() { }

    #[test]
    fn handles_permission_denied() { }

    #[test]
    fn handles_read_only_filesystem() { }
}
```

### Phase 5: Hook Script Updates

**File:** `~/.claude/scripts/hud-state-tracker.sh`

#### Changes

1. Extract `file_path` from tool_input for Edit, Write, Read tools
2. Write to `hud-file-activity.json` in addition to `hud-session-states-v2.json`
3. Handle relative paths (resolve against cwd)

#### Test Cases

```bash
# Test file path extraction
test_extracts_file_path_from_edit_tool()
test_extracts_file_path_from_write_tool()
test_extracts_file_path_from_read_tool()
test_handles_relative_paths()
test_handles_missing_file_path()

# Test activity file writing
test_writes_activity_to_file()
test_appends_to_existing_activity()
test_handles_concurrent_writes()
```

### Phase 6: State Resolution Integration

**Module:** `core/hud-core/src/sessions.rs` (existing, modify)

#### Changes

1. Add `ActivityStore` integration
2. Update `detect_session_state()` to check file activity
3. Add new `SessionNearby` state variant

### Phase 7: Swift UI Updates

**Files:**
- `AppState.swift` — New validation flow
- `AddProjectView.swift` — Smart validation UI
- `ProjectCard.swift` — New state visuals

---

## Data Types (Rust)

### boundaries.rs

```rust
use std::path::Path;

pub const MAX_BOUNDARY_DEPTH: usize = 20;

pub const IGNORED_DIRECTORIES: &[&str] = &[
    "node_modules",
    "vendor",
    ".git",
    "__pycache__",
    "target",
    "dist",
    "build",
    ".next",
    ".output",
    "venv",
    ".venv",
    "env",
];

pub const PROJECT_MARKERS: &[(&str, u8)] = &[
    ("CLAUDE.md", 1),      // Priority 1 (highest)
    (".git", 2),           // Priority 2
    ("package.json", 3),   // Priority 3
    ("Cargo.toml", 3),
    ("pyproject.toml", 3),
    ("go.mod", 3),
    ("Makefile", 4),       // Priority 4 (lowest)
];

#[derive(Debug, Clone, PartialEq)]
pub struct ProjectBoundary {
    pub path: String,
    pub marker: String,
    pub priority: u8,
}

pub fn find_project_boundary(file_path: &str) -> Option<ProjectBoundary>;
pub fn is_ignored_directory(name: &str) -> bool;
pub fn is_dangerous_path(path: &str) -> Option<String>;
```

### activity.rs

```rust
use std::time::Duration;

pub const ACTIVITY_THRESHOLD: Duration = Duration::from_secs(5 * 60);  // 5 minutes
pub const CLEANUP_THRESHOLD: Duration = Duration::from_secs(60 * 60);  // 1 hour
pub const DEBOUNCE_INTERVAL: Duration = Duration::from_millis(500);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileActivity {
    pub project_path: String,
    pub file_path: String,
    pub tool: String,
    pub timestamp: String,  // ISO 8601
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionActivity {
    pub cwd: String,
    pub pid: Option<u32>,
    pub activity: Vec<FileActivity>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivityStore {
    pub version: u32,
    pub sessions: HashMap<String, SessionActivity>,
}

impl ActivityStore {
    pub fn load(path: &Path) -> Result<Self, HudError>;
    pub fn save(&self, path: &Path) -> Result<(), HudError>;
    pub fn record_activity(&mut self, session_id: &str, activity: FileActivity);
    pub fn has_recent_activity(&self, project_path: &str, threshold: Duration) -> bool;
    pub fn cleanup_old_entries(&mut self, threshold: Duration);
}
```

### validation.rs

```rust
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ValidationResult {
    Valid {
        path: String,
        has_claude_md: bool,
    },
    SuggestParent {
        requested_path: String,
        suggested_path: String,
        reason: String,
    },
    MissingClaudeMd {
        path: String,
        has_other_markers: bool,
    },
    NotAProject {
        path: String,
        reason: String,
    },
    PathNotFound {
        path: String,
    },
    DangerousPath {
        path: String,
        reason: String,
    },
}

pub fn validate_project_path(path: &str) -> ValidationResult;
pub fn canonicalize_path(path: &str) -> Result<String, HudError>;
```

---

## Migration Notes

### Backward Compatibility

- Existing `hud-session-states-v2.json` continues to work
- New `hud-file-activity.json` is additive
- Projects pinned without CLAUDE.md continue to function (validation is advisory)

### Hook Script Compatibility

- New hook behavior is additive (writes to additional file)
- Old hook scripts still work (just won't have file activity)
- Graceful degradation if activity file doesn't exist

---

## Success Criteria

1. **Monorepo packages show correct state** — When Claude edits files in a package, that package shows "Working"
2. **Smart validation guides users** — Adding a project suggests correct boundaries
3. **CLAUDE.md creation works** — Users can create CLAUDE.md with one click
4. **No performance regression** — State updates remain fast even with file tracking
5. **All edge cases handled** — Symlinks, permissions, nested repos all work correctly
6. **Full test coverage** — All components have comprehensive tests written first

---

## Open Questions

1. **Should `Read` operations count as activity?** Currently planning yes, but could make it configurable.
2. **What's the ideal activity threshold?** 5 minutes seems reasonable, but could be user-configurable.
3. **Should we show "Session Nearby" as a distinct state?** Or just Ready? Currently planning distinct visual.
