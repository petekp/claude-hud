# State Detection Design

## Problem Statement

Claude HUD needs to reliably detect whether Claude is:
- **IDLE** — No active session
- **WORKING** — Claude is processing/generating
- **READY** — Claude finished, waiting for user input
- **STALE** — No activity in N days

Current approach (polling + JSONL parsing) is unreliable and laggy.

## Solution: Event-Driven State via Hooks

Use Claude Code's hook system to get authoritative state changes:

```
┌─────────────────────────────────────────────────────────────────┐
│                     STATE MACHINE                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────┐   SessionStart    ┌─────────────────┐              │
│  │  IDLE   │ ─────────────────►│     READY       │              │
│  └────┬────┘                   └────────┬────────┘              │
│       │                                 │                       │
│       │                                 │ UserPromptSubmit      │
│       │                                 ▼                       │
│       │                        ┌─────────────────┐              │
│       │                        │    WORKING      │              │
│       │                        └────────┬────────┘              │
│       │                                 │                       │
│       │        SessionEnd               │ Stop                  │
│       │◄────────────────────────────────┤                       │
│       │                                 ▼                       │
│       │                           back to READY                 │
│       │                                                         │
│  ┌────▼────┐                                                    │
│  │  STALE  │ (no activity for N days)                           │
│  └─────────┘                                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation

### 1. Centralized State File

Location: `~/.claude/hud-session-states.json`

```json
{
  "version": 1,
  "projects": {
    "/Users/pete/Code/claude-hud": {
      "session_id": "2c8d1604-5b0f-47d6-a68d-7c0c0c2335b0",
      "state": "ready",
      "state_changed_at": "2026-01-08T04:46:00.000Z",
      "session_started_at": "2026-01-08T04:23:05.000Z",
      "working_on": "Visual state indicators for project cards",
      "next_step": "Implement animation CSS"
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
          {
            "type": "command",
            "command": "~/.claude/scripts/hud-state-tracker.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/scripts/hud-state-tracker.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/scripts/hud-state-tracker.sh"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/scripts/hud-state-tracker.sh"
          }
        ]
      }
    ]
  }
}
```

### 3. Hook Script

`~/.claude/scripts/hud-state-tracker.sh`:

```bash
#!/bin/bash
# HUD State Tracker - Updates centralized session state

STATE_FILE="$HOME/.claude/hud-session-states.json"
input=$(cat)

# Extract fields from hook input
event=$(echo "$input" | jq -r '.hook_event_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // false')

# Skip if stop hook is re-running (prevents loops)
if [ "$event" = "Stop" ] && [ "$stop_hook_active" = "true" ]; then
  exit 0
fi

# Skip if missing required fields
if [ -z "$cwd" ] || [ -z "$event" ]; then
  exit 0
fi

# Initialize state file if needed
if [ ! -f "$STATE_FILE" ]; then
  echo '{"version":1,"projects":{}}' > "$STATE_FILE"
fi

# Determine new state based on event
case "$event" in
  "SessionStart")
    new_state="ready"
    ;;
  "UserPromptSubmit")
    new_state="working"
    ;;
  "Stop")
    new_state="ready"
    ;;
  "SessionEnd")
    new_state="idle"
    ;;
  *)
    exit 0
    ;;
esac

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

# Update state file atomically
tmp_file=$(mktemp)
jq --arg cwd "$cwd" \
   --arg state "$new_state" \
   --arg session "$session_id" \
   --arg ts "$timestamp" \
   '.projects[$cwd] = (.projects[$cwd] // {}) + {
     state: $state,
     state_changed_at: $ts,
     session_id: $session
   }' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"

# For Stop events, also generate status summary (async)
if [ "$event" = "Stop" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  (
    context=$(tail -100 "$transcript_path" | grep -E '"type":"(user|assistant)"' | tail -20)
    if [ -z "$context" ]; then
      exit 0
    fi

    claude_cmd=$(command -v claude || echo "/opt/homebrew/bin/claude")
    response=$("$claude_cmd" -p \
      --no-session-persistence \
      --output-format json \
      --model haiku \
      "Summarize what's being worked on. Return JSON: {working_on: string, next_step: string}. Context: $context" 2>/dev/null)

    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
      exit 0
    fi

    result=$(echo "$response" | jq -r '.result // empty')
    working_on=$(echo "$result" | jq -r '.working_on // empty' 2>/dev/null)
    next_step=$(echo "$result" | jq -r '.next_step // empty' 2>/dev/null)

    if [ -n "$working_on" ]; then
      jq --arg cwd "$cwd" \
         --arg working_on "$working_on" \
         --arg next_step "$next_step" \
         '.projects[$cwd].working_on = $working_on | .projects[$cwd].next_step = $next_step' \
         "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    fi
  ) &>/dev/null &
  disown 2>/dev/null
fi

exit 0
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
| WORKING → READY | Stop hook | ✅ Very High | <100ms |
| READY → IDLE | SessionEnd hook | ✅ Very High | <100ms |
| * → STALE | Computed from timestamps | ✅ High | On load |

**Why this is reliable:**
1. All state changes come from Claude Code's native hooks
2. Hooks are synchronous — they fire before Claude continues
3. State is written to a single file — no distributed scanning
4. File watching enables real-time UI updates

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
