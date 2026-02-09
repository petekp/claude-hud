# Gap Matrix: Interface Explorer vs. Real Capacitor System

**Analysis Date**: 2026-02-06
**Purpose**: Identify what the real system knows that the interface explorer does not reveal.

---

## Executive Summary

The Interface Explorer is excellent at showing **topology** (what talks to what), but weak at revealing **behavior** (how decisions are made). The largest gaps are in activation policy logic, session state transitions, and failure mode reasoning.

**Top 5 Priority Gaps** (transformative additions):
1. **Session State Machine Visualization** — Show the 5-state FSM and event → transition rules
2. **Activation Policy Table** — Display the 6 ranked rules and how they apply to candidates
3. **Candidate Ranking Trace** — Show rank keys (`live=1, path_rank=2, tmux=1, ...`) for each candidate
4. **Boundary Failure Modes** — Annotate each boundary with failure scenarios and fallback logic
5. **Stale Event Detection Logic** — Show timestamp comparison rules that cause events to be skipped

---

## Full Gap Matrix

| Information | In Explorer? | In Real System? | Location in Source | Priority to Add | Why |
|------------|--------------|-----------------|-------------------|-----------------|-----|
| **Session States (5 states)** | ❌ No | ✅ Yes | `daemon/src/reducer.rs:6-14` | **P0 - Critical** | Explorer shows "session tracking" but never shows what states exist (Working, Ready, Idle, Compacting, Waiting) or how to recognize them |
| **State Transition Rules** | ❌ No | ✅ Yes | `daemon/src/reducer.rs:66-120` | **P0 - Critical** | Users see "events flow in" but don't understand which events cause which state changes |
| **Event Types (14 types)** | ⚠️ Partial | ✅ Yes | `daemon/src/reducer.rs:80-119` | **P0 - Critical** | Explorer mentions "SessionStart, PreToolUse, Stop" but doesn't show all 14 event types or their effects |
| **Activation Policy Rules (6 ranked)** | ❌ No | ✅ Yes | `activation/policy.rs:35-42` | **P0 - Critical** | The most important selection logic is invisible: "live shells beat dead shells", "path specificity: exact > child > parent", etc. |
| **Candidate Ranking Algorithm** | ❌ No | ✅ Yes | `activation/policy.rs:72-87` | **P0 - Critical** | Users don't see how shells are compared: `is_live.cmp().then(path_rank.cmp()).then(tmux.cmp())...` |
| **Decision Trace Structure** | ⚠️ Partial | ✅ Yes | `activation/trace.rs:6-26` | **P1 - High** | Explorer mentions "Live Message Trace" but doesn't show structured candidate traces with rank keys |
| **Rank Keys Format** | ❌ No | ✅ Yes | `activation/trace.rs:106-112` | **P1 - High** | The actual comparison keys (`live=1, path_rank=2, tmux=1, updated_at=..., pid=...`) are never shown |
| **Path Match Types (3 types)** | ❌ No | ✅ Yes | `activation/policy.rs:10-33` | **P1 - High** | Explorer doesn't explain "exact", "child", "parent" path matching or their rank values (2, 1, 0) |
| **SelectionPolicy Struct** | ❌ No | ✅ Yes | `activation/policy.rs:55-88` | **P1 - High** | The `prefer_tmux` boolean and its effect on comparison logic is hidden |
| **Boundary Failure Modes** | ❌ No | ✅ Yes | Implicit in code | **P1 - High** | Each boundary can fail (socket closed, FFI panic, AppleScript timeout) but explorer doesn't document these |
| **Stale Event Detection** | ❌ No | ✅ Yes | `daemon/src/reducer.rs:122-132` | **P1 - High** | Events with `recorded_at < current.updated_at` are skipped, but this logic is invisible |
| **ActivationAction Enum (11 variants)** | ⚠️ Partial | ✅ Yes | `activation.rs:93-145` | **P1 - High** | Explorer shows "ActivationAction" abstractly but doesn't list all 11 concrete action types |
| **Fallback Decision Criteria** | ❌ No | ✅ Yes | `activation.rs:374-602` | **P1 - High** | The logic for when primary fails and fallback triggers is entirely missing |
| **ShellEntryFfi Fields** | ⚠️ Partial | ✅ Yes | `activation.rs:53-66` | **P2 - Medium** | Explorer shows "shell state" but doesn't document all fields: `cwd, tty, parent_app, tmux_session, tmux_client_tty, updated_at, is_live` |
| **TmuxContextFfi Fields** | ⚠️ Partial | ✅ Yes | `activation.rs:69-77` | **P2 - Medium** | Explorer mentions "tmux context" but doesn't show `session_at_path, has_attached_client, home_dir` |
| **SessionRecord Fields** | ❌ No | ✅ Yes | `daemon/src/reducer.rs:46-57` | **P2 - Medium** | The full session record shape is never shown: `session_id, pid, state, cwd, project_id, project_path, updated_at, state_changed_at, last_event` |
| **HOME Exclusion Logic** | ❌ No | ✅ Yes | `activation/policy.rs:168-205` | **P2 - Medium** | The special case preventing HOME directory from matching all child paths is undocumented |
| **Managed Worktree Isolation** | ❌ No | ✅ Yes | `activation/policy.rs:207-228` | **P2 - Medium** | Parent repo shells are prevented from matching into `/.capacitor/worktrees/<name>` but this rule is invisible |
| **IPC Message Format** | ⚠️ Partial | ✅ Yes | `docs/daemon-ipc.md` | **P2 - Medium** | Explorer shows "Request { method, params }" abstractly but doesn't show JSON schema |
| **IPC Methods (6 methods)** | ⚠️ Partial | ✅ Yes | `docs/daemon-ipc.md` | **P2 - Medium** | Explorer mentions "event, get_health, get_shell_state, get_sessions, get_project_states, get_process_liveness" but doesn't document params/responses |
| **Confidence Levels (3 levels)** | ⚠️ Partial | ✅ Yes | Explorer HTML | **P2 - Medium** | Explorer shows "deterministic, heuristic, best-effort" badges but doesn't explain what triggers each level |
| **System Callbacks** | ⚠️ Partial | ✅ Yes | Implicit in Swift | **P2 - Medium** | Explorer mentions "system callback boundary" but doesn't list specific failures: blocked focus, accessibility denied, etc. |
| **Adapter Protocols** | ⚠️ Partial | ✅ Yes | `TerminalLauncher.swift, ActivationActionExecutor.swift` | **P3 - Low** | Explorer mentions "adapter-driven routing" but doesn't show protocol interfaces |
| **TerminalType Enum** | ❌ No | ✅ Yes | `activation.rs:148-171` | **P3 - Low** | The 7 terminal types (ITerm, TerminalApp, Ghostty, Alacritty, Kitty, Warp, Unknown) are never listed |
| **IdeType Enum** | ❌ No | ✅ Yes | `activation.rs:174-194` | **P3 - Low** | The 4 IDE types (Cursor, VsCode, VsCodeInsiders, Zed) are never shown |
| **ParentApp Variants** | ❌ No | ✅ Yes | `types.rs` (not shown) | **P3 - Low** | The full enum of parent apps is referenced but not documented |
| **Project Identity Resolution** | ❌ No | ✅ Yes | `daemon/src/reducer.rs:223-240` | **P3 - Low** | How `file_path` overrides `cwd` for boundary detection is undocumented |
| **Canonical Path Worktree Logic** | ❌ No | ✅ Yes | `daemon/src/reducer.rs:378-432` (tests) | **P3 - Low** | The worktree → repo root canonicalization is tested but not explained |
| **Timestamp Parsing Rules** | ❌ No | ✅ Yes | `daemon/src/reducer.rs:263-267` | **P3 - Low** | RFC3339 format requirement and fallback behavior for invalid timestamps |

---

## Category Breakdown

### 1. Session State Machine (Critical Gap)

**What Explorer Shows:**
- "daemon reducer updates materialized state"
- Generic flow: events → reducer → SQLite

**What Real System Has:**
```rust
pub enum SessionState {
    Working,    // Claude is actively processing
    Ready,      // Waiting for user input
    Idle,       // Session is idle
    Compacting, // Transcript is being compressed
    Waiting,    // Blocked on permission/user decision
}

pub fn reduce_session(current: Option<&SessionRecord>, event: &EventEnvelope) -> SessionUpdate {
    // 14 event types mapped to state transitions
    match event.event_type {
        EventType::SessionStart => Ready (if not active),
        EventType::UserPromptSubmit => Working,
        EventType::PreToolUse | PostToolUse | PostToolUseFailure => Working,
        EventType::PermissionRequest => Waiting,
        EventType::PreCompact => Compacting,
        EventType::Notification(idle_prompt) => Ready,
        EventType::Notification(permission_prompt) => Waiting,
        EventType::TaskCompleted => Ready,
        EventType::Stop => Ready (if hook inactive, event not stale),
        EventType::SubagentStart | SubagentStop | TeammateIdle => Skip,
        EventType::SessionEnd => Delete,
        EventType::ShellCwd => Skip,
    }
}
```

**Why Missing This Matters:**
- Users debugging "why did Claude session not activate?" can't see if the session is in `Waiting` vs `Working` vs `Idle`
- State transition logic is **the core of session tracking** but is completely invisible

---

### 2. Activation Policy (Critical Gap)

**What Explorer Shows:**
- "pure decision logic"
- "shell selection + action resolution"

**What Real System Has:**
```rust
pub(crate) const POLICY_TABLE: [&str; 6] = [
    "live shells beat dead shells",                                      // Rule 1
    "path specificity: exact > child > parent",                          // Rule 2
    "tmux preference (only when attached and path specificity ties)",    // Rule 3
    "known parent app beats unknown parent app",                         // Rule 4
    "most recent timestamp wins (invalid timestamps lose)",              // Rule 5
    "higher PID breaks ties deterministically",                          // Rule 6
];

pub(crate) fn compare(&self, candidate: &Candidate<'_>, best: &Candidate<'_>) -> Ordering {
    candidate.is_live.cmp(&best.is_live)                                // Rule 1
        .then_with(|| candidate.match_type.rank().cmp(&best.match_type.rank())) // Rule 2
        .then_with(|| {
            if self.prefer_tmux && candidate.match_type.rank() == best.match_type.rank() {
                candidate.has_tmux.cmp(&best.has_tmux)                  // Rule 3
            } else {
                Ordering::Equal
            }
        })
        .then_with(|| candidate.has_known_parent.cmp(&best.has_known_parent)) // Rule 4
        .then_with(|| compare_timestamp(candidate.timestamp, best.timestamp)) // Rule 5
        .then_with(|| candidate.pid.cmp(&best.pid))                          // Rule 6
}
```

**Why Missing This Matters:**
- Users debugging "why did Capacitor pick shell B instead of shell A?" have no way to see the ranked comparison
- The **entire selection algorithm** is opaque

---

### 3. Decision Trace (High Priority Gap)

**What Explorer Shows:**
- "Live Message Trace" panel with generic "action: edge.name" entries

**What Real System Has:**
```rust
pub struct DecisionTraceFfi {
    pub prefer_tmux: bool,
    pub policy_order: Vec<String>,              // The 6 rules as strings
    pub candidates: Vec<CandidateTraceFfi>,     // All candidates with rank keys
    pub selected_pid: Option<u32>,
}

pub struct CandidateTraceFfi {
    pub pid: u32,
    pub cwd: String,
    pub tty: String,
    pub parent_app: ParentApp,
    pub is_live: bool,
    pub has_tmux: bool,
    pub match_type: String,          // "exact", "child", "parent"
    pub match_rank: u8,              // 2, 1, 0
    pub updated_at: String,
    pub rank_key: Vec<String>,       // ["live=1", "path_rank=2", "tmux=1", "updated_at=...", "pid=12345"]
}
```

**Why Missing This Matters:**
- Users can't see **why a specific candidate won** — the rank keys are the entire proof
- The trace exists but is never displayed in structured form

---

### 4. Boundary Failure Modes (High Priority Gap)

**What Explorer Shows:**
- Edge annotations like "boundary: Unix socket JSON IPC"
- Generic "request/response" format

**What Real System Has (Implicit):**

| Boundary | Failure Modes | Fallback Behavior |
|----------|---------------|------------------|
| `hudhook → daemon IPC` | Socket closed, daemon dead, timeout | Hook exits with failure code; Claude session continues |
| `Swift → daemon IPC` | Socket closed, JSON parse error | `loadDashboard()` returns empty state; Swift shows "daemon unavailable" |
| `Swift → HudEngine (FFI)` | Rust panic, invalid UTF-8, null pointer | Swift catches and falls back to `ActivatePriorityFallback` |
| `HudEngine → daemon IPC` | Same as Swift → daemon | Rust returns `Ok(empty_state)` |
| `ActivationActionExecutor → tmux` | Command failure, no client attached | Falls back to `LaunchTerminalWithTmux` or `LaunchNewTerminal` |
| `ActivationActionExecutor → AppleScript` | User focus blocked, app not installed | Returns `false`; launcher tries fallback action |
| `ActivationActionExecutor → kitty@` | Remote control disabled, window closed | Falls back to `ActivateApp { app_name: "kitty" }` |

**Why Missing This Matters:**
- Users debugging "activation failed" can't see **which boundary failed and what fallback triggered**
- Failure modes are the **most important behavior** for a system that routes through 7+ boundaries

---

### 5. Stale Event Detection (High Priority Gap)

**What Explorer Shows:**
- Nothing (event flow assumes all events are valid)

**What Real System Has:**
```rust
fn is_event_stale(current: Option<&SessionRecord>, event: &EventEnvelope) -> bool {
    let Some(current) = current else { return false };
    let Some(event_time) = parse_rfc3339(&event.recorded_at) else {
        return false; // Malformed timestamp = not stale (processed with caution)
    };
    let Some(current_time) = parse_rfc3339(&current.updated_at) else {
        return false;
    };

    event_time < current_time  // Event is older than current state → skip
}
```

**Why Missing This Matters:**
- Users see "event sent but nothing happened" and can't understand that out-of-order events are **silently dropped**
- Stale event detection is **critical for correctness** (prevents race conditions) but is completely invisible

---

## Priority Ranking Explanation

### P0 - Critical (Must Add)
These gaps make the explorer **misleading** rather than just incomplete. Users think they understand the system but are missing the core logic.

- **Session State Machine** — Without this, "session tracking" is a black box
- **Activation Policy Rules** — Without this, "shell selection" is magic
- **Candidate Ranking Trace** — Without this, debugging selection failures is impossible
- **Boundary Failure Modes** — Without this, "activation failed" is unexplained
- **Stale Event Detection** — Without this, "why was my event ignored?" is unanswerable

### P1 - High (Should Add)
These gaps prevent the explorer from being a **complete debugging tool**. Users can understand the basic flow but can't diagnose edge cases.

- **Decision Trace Structure** — Makes the trace panel actually useful
- **Rank Keys Format** — Shows the comparison keys that prove selection logic
- **Path Match Types** — Explains "exact", "child", "parent" semantics
- **SelectionPolicy Struct** — Shows the `prefer_tmux` toggle and its effect
- **ActivationAction Enum** — Lists all 11 possible actions and their triggers
- **Fallback Decision Criteria** — Explains when primary → fallback transition happens

### P2 - Medium (Nice to Have)
These gaps reduce **completeness** but don't block debugging common issues.

- **ShellEntryFfi Fields** — Shows what metadata is available per shell
- **TmuxContextFfi Fields** — Shows what tmux state influences decisions
- **SessionRecord Fields** — Shows what's stored in the materialized state
- **HOME Exclusion Logic** — Explains the special-case path matching rule
- **Managed Worktree Isolation** — Explains the `.capacitor/worktrees/` isolation

### P3 - Low (Optional)
These gaps are **documentation details** that can be looked up in source code if needed.

- **TerminalType Enum** — List of supported terminals (static info)
- **IdeType Enum** — List of supported IDEs (static info)
- **ParentApp Variants** — Full enum of recognized parent apps
- **Project Identity Resolution** — File path override logic for boundary detection

---

## Actionable Next Steps

### Immediate (P0 fixes):
1. **Add Session State Machine Panel**
   - Show the 5 states as a visual FSM diagram
   - Highlight current state for each session
   - Show event → state transition rules as a table

2. **Add Activation Policy Panel**
   - Display the 6 ranked rules as a numbered list
   - For each step in the "activation" flow, show which rule is being applied
   - Color-code rule violations (e.g., "dead shell eliminated by Rule 1")

3. **Enhance Decision Trace**
   - Replace flat "action: edge.name" logs with structured candidate tables
   - Show `rank_key` for each candidate: `["live=1", "path_rank=2", "tmux=1", ...]`
   - Highlight the selected candidate in green, runner-ups in yellow

4. **Annotate Boundaries with Failure Modes**
   - Add a "failure scenarios" dropdown for each edge
   - List possible failures: socket closed, command timeout, app not found
   - Show fallback logic: "If tmux fails → LaunchTerminalWithTmux"

5. **Add Stale Event Indicator**
   - In the trace log, mark skipped events with a ⏭️ icon
   - Add tooltip: "Event skipped: recorded_at (T1) < current.updated_at (T2)"

### Follow-up (P1/P2 fixes):
- Add interactive mode: "What if?" — change policy flags (prefer_tmux=false) and re-run selection
- Add live HTTP endpoint to inject real DecisionTraceFfi from running app
- Add search: "Find all edges where confidence=heuristic"

---

## Conclusion

The Interface Explorer is **architecturally correct** but **behaviorally thin**. It shows the "what" (topology) beautifully but hides the "how" (decision logic) and "why" (fallback reasoning).

**Transform from "topology viewer" to "system behavior explainer"** by adding:
1. Session state machine visualization
2. Activation policy rule display
3. Structured candidate ranking traces
4. Boundary failure modes + fallbacks
5. Stale event detection indicators

**Impact**: Users will go from "I see the boxes and arrows" to "I understand exactly why Capacitor made this decision."
