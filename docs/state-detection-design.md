# State Detection Design

> **Note:** This document has been superseded by [Status Sync System Architecture](../.claude/docs/status-sync-architecture.md) which provides more comprehensive and current documentation of the state tracking system.

## Problem Statement

Claude HUD needs to reliably detect whether Claude is:
- **IDLE** — No active session
- **WORKING** — Claude is processing/generating (thinking=true)
- **READY** — Claude finished, waiting for user input (thinking=false)
- **COMPACTING** — Auto-compacting context
- **WAITING** — Stale "working" state (synthesized client-side)

Current approach (polling + JSONL parsing) is unreliable and laggy.

## Solution: Event-Driven State via Hooks

Use Claude Code's hook system to get authoritative state changes:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        STATE MACHINE                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────┐   SessionStart    ┌─────────────────┐                  │
│  │  IDLE   │ ─────────────────►│     READY       │◄─────────────┐   │
│  └─────────┘                   └────────┬────────┘              │   │
│                                         │                       │   │
│                                         │ UserPromptSubmit      │   │
│                                         ▼                       │   │
│                                ┌─────────────────┐              │   │
│                         ┌─────►│    WORKING      │──────────────┤   │
│                         │      └────────┬────────┘    Stop      │   │
│                         │               │                       │   │
│                         │               │ PreCompact (auto)     │   │
│      PostToolUse        │               ▼                       │   │
│  (after compacting)     │      ┌─────────────────┐              │   │
│                         └──────│   COMPACTING    │              │   │
│                                └─────────────────┘              │   │
│                                                                     │
│  WAITING is synthesized client-side when "working" has no           │
│  heartbeat for 5+ seconds (indicates user interrupt)                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Implementation

### 1. Centralized State File

Location: `~/.claude/hud-session-states.json`

```json
{
  "version": 1,
  "projects": {
    "/Users/pete/Code/claude-hud": {
      "state": "ready",
      "state_changed_at": "2026-01-08T04:46:00.000Z",
      "session_id": "2c8d1604-5b0f-47d6-a68d-7c0c0c2335b0",
      "thinking": false,
      "thinking_updated_at": "2026-01-08T04:46:00.000Z",
      "working_on": "Visual state indicators for project cards",
      "next_step": "Implement animation CSS",
      "context": {
        "updated_at": "2026-01-08T04:46:00.000Z"
      }
    }
  }
}
```

### 2. Hook Configuration

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" },
          { "type": "command", "command": "~/.claude/hooks/publish-state.sh" }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" },
          { "type": "command", "command": "~/.claude/hooks/publish-state.sh" }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "auto",
        "hooks": [
          { "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" },
          { "type": "command", "command": "~/.claude/hooks/publish-state.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" },
          { "type": "command", "command": "~/.claude/hooks/publish-state.sh" }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          { "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" },
          { "type": "command", "command": "~/.claude/hooks/publish-state.sh" }
        ]
      }
    ]
  }
}
```

**Note:** The `publish-state.sh` script handles debounced relay publishing for remote clients.

### 3. Hook Script

`~/.claude/scripts/hud-state-tracker.sh`:

> **Note:** The full implementation is at `~/.claude/scripts/hud-state-tracker.sh`. Below is a simplified version showing the key logic:

```bash
#!/bin/bash
# Claude HUD State Tracker - Full implementation handles all hook events

# Skip summary generation subprocesses to prevent recursive hooks
if [ "$HUD_SUMMARY_GEN" = "1" ]; then
  cat > /dev/null && exit 0
fi

STATE_FILE="$HOME/.claude/hud-session-states.json"
input=$(cat)

event=$(echo "$input" | jq -r '.hook_event_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
trigger=$(echo "$input" | jq -r '.trigger // empty')

# Determine state and thinking based on event
case "$event" in
  "SessionStart")
    new_state="ready"; thinking="false" ;;
  "UserPromptSubmit")
    new_state="working"; thinking="true" ;;
  "PermissionRequest")
    exit 0 ;;  # No state change during permissions
  "PostToolUse")
    # Transition from compacting→working, or update heartbeat
    current_state=$(jq -r --arg cwd "$cwd" '.projects[$cwd].state // "idle"' "$STATE_FILE")
    if [ "$current_state" = "compacting" ]; then
      new_state="working"; thinking="true"
    else
      # Just update heartbeat timestamp
      exit 0
    fi ;;
  "PreCompact")
    [ "$trigger" = "auto" ] && { new_state="compacting"; thinking="true"; } || exit 0 ;;
  "Stop")
    new_state="ready"; thinking="false" ;;
  "SessionEnd")
    exit 0 ;;  # Don't overwrite "ready" with "idle"
  "Notification")
    notification_type=$(echo "$input" | jq -r '.notification_type // empty')
    [ "$notification_type" = "idle_prompt" ] && { new_state="ready"; thinking="false"; } || exit 0 ;;
  *)
    exit 0 ;;
esac

# Update state file atomically
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
tmp_file=$(mktemp)
jq --arg cwd "$cwd" --arg state "$new_state" --arg session "$session_id" \
   --arg ts "$timestamp" --argjson thinking "$thinking" \
   '.projects[$cwd] = ((.projects[$cwd] // {}) + {
     state: $state, thinking: $thinking, session_id: $session,
     state_changed_at: $ts, thinking_updated_at: $ts
   })' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"

# Generate summary on Stop events (async, with HUD_SUMMARY_GEN=1 to prevent recursion)
if [ "$event" = "Stop" ]; then
  ( HUD_SUMMARY_GEN=1 /opt/homebrew/bin/claude -p --no-session-persistence --output-format json --model haiku \
    "Extract: {working_on, next_step}" 2>/dev/null | ... ) &
fi
```

### 4. HUD Backend Changes

In `src-tauri/src/lib.rs`, add:

```rust
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ProjectSessionState {
    pub state: String,           // "idle", "working", "ready"
    pub state_changed_at: Option<String>,
    pub session_id: Option<String>,
    pub working_on: Option<String>,
    pub next_step: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct SessionStates {
    pub version: u32,
    pub projects: HashMap<String, ProjectSessionState>,
}

fn load_session_states() -> SessionStates {
    let path = get_claude_dir()
        .map(|d| d.join("hud-session-states.json"));

    match path {
        Some(p) if p.exists() => {
            fs::read_to_string(&p)
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default()
        }
        _ => SessionStates::default()
    }
}

// In Project struct, add:
pub session_state: Option<String>,  // "idle", "working", "ready", "stale"
pub working_on: Option<String>,
pub next_step: Option<String>,

// In load_projects_internal(), add session state:
let states = load_session_states();
for project in &mut projects {
    if let Some(state) = states.projects.get(&project.path) {
        project.session_state = Some(state.state.clone());
        project.working_on = state.working_on.clone();
        project.next_step = state.next_step.clone();
    } else {
        project.session_state = Some("idle".to_string());
    }
}
```

### 5. File Watching (Optional Enhancement)

For real-time updates, watch the state file:

```rust
use notify::{Watcher, RecursiveMode, watcher};

fn watch_session_states(app_handle: tauri::AppHandle) {
    std::thread::spawn(move || {
        let state_file = get_claude_dir()
            .map(|d| d.join("hud-session-states.json"));

        if let Some(path) = state_file {
            let (tx, rx) = std::sync::mpsc::channel();
            let mut watcher = watcher(tx, Duration::from_millis(500)).unwrap();
            watcher.watch(&path, RecursiveMode::NonRecursive).unwrap();

            loop {
                match rx.recv() {
                    Ok(_) => {
                        let states = load_session_states();
                        let _ = app_handle.emit("session-states-changed", states);
                    }
                    Err(_) => break,
                }
            }
        }
    });
}
```

## Reliability Analysis

| State Transition | Signal | Reliability | Latency |
|------------------|--------|-------------|---------|
| IDLE → READY | SessionStart hook | ✅ Very High | <100ms |
| READY → WORKING | UserPromptSubmit hook | ✅ Very High | <100ms |
| WORKING → COMPACTING | PreCompact hook (auto) | ✅ Very High | <100ms |
| COMPACTING → WORKING | PostToolUse hook | ✅ Very High | <100ms |
| WORKING → READY | Stop hook | ✅ Very High | <100ms |
| WORKING → WAITING | Client-side synthesis | ✅ High | ~5 seconds |
| * → STALE | Computed from timestamps | ✅ High | On load |

**Why this is reliable:**
1. All state changes come from Claude Code's native hooks
2. Hooks are synchronous — they fire before Claude continues
3. State is written to a single file — no distributed scanning
4. File watching enables real-time UI updates
5. "Waiting" state is synthesized client-side when heartbeats stop (handles Ctrl+C interrupts)

## Fallback: Process Detection

If hooks aren't configured, fall back to process detection:

```rust
fn detect_state_from_process(project_path: &str) -> String {
    // Check if claude process is running with cwd = project_path
    let system = System::new_all();
    for process in system.processes().values() {
        if process.name().contains("claude") {
            if let Some(cwd) = process.cwd() {
                if cwd.starts_with(project_path) {
                    // Process running — but we don't know if working or ready
                    return "active".to_string();  // Generic "active" state
                }
            }
        }
    }
    "idle".to_string()
}
```

This gives us:
- `active` — Claude process is running (can't distinguish working/ready)
- `idle` — No Claude process

## Migration Path

1. **Phase 1:** Implement hook script + state file
2. **Phase 2:** Update HUD backend to read state file
3. **Phase 3:** Add file watching for real-time updates
4. **Phase 4:** Update frontend with state-based animations

## Open Questions

1. **Multiple sessions per project?** — Current design assumes one active session per project. Need to handle case where user opens multiple terminals.

2. **Race conditions?** — Multiple hooks could fire close together. Use atomic file writes (write to temp, then move).

3. **State file corruption?** — Add validation + fallback to defaults.

4. **Cross-platform?** — Shell script is bash. Need to test on Windows (Git Bash?) or rewrite in cross-platform language.
