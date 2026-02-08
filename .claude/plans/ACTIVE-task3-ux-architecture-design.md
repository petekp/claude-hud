# Task #3: Information Architecture for Three User Journeys

**Status:** Completed
**Assignee:** UX architect teammate
**Created:** 2026-02-06

## Context

The Capacitor Interface Explorer is a transparent-ui debugging tool for understanding:
- How daemon state machine manages session lifecycle (reducer.rs)
- How activation policy ranks shells by 6 rules (policy.rs)
- How Swift executes activation decisions with fallbacks (activation.rs)

## Real System Data Available

From analysis of the Rust codebase:

### Session State Machine (reducer.rs)
- **States**: Working, Ready, Idle, Compacting, Waiting
- **Events**: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, PreCompact, Notification, Stop, SessionEnd
- **Reducer logic**: reduce_session(current, event) → SessionUpdate
- **Project resolution**: derive_project_identity from file_path or cwd
- **State transitions**: State changes only when state differs from current

### Activation Policy (policy.rs)
- **POLICY_TABLE** (6 rules in priority order):
  1. Live shells beat dead shells
  2. Path specificity: exact > child > parent
  3. Tmux preference (only when attached and path specificity ties)
  4. Known parent app beats unknown parent app
  5. Most recent timestamp wins (invalid timestamps lose)
  6. Higher PID breaks ties deterministically
- **Candidate structure**: pid, shell, is_live, has_tmux, has_known_parent, match_type, timestamp
- **SelectionPolicy**: prefer_tmux flag (derived from has_attached_client)
- **SelectionOutcome**: best candidate + sorted candidates array

### Activation Decision (activation.rs)
- **ActivationDecision**: primary + fallback + reason + trace
- **ActivationAction**: 13 action variants (ActivateByTty, ActivateApp, ActivateKittyWindow, ActivateIdeWindow, SwitchTmuxSession, EnsureTmuxSession, ActivateHostThenSwitchTmux, LaunchTerminalWithTmux, LaunchNewTerminal, ActivatePriorityFallback, Skip)
- **DecisionTraceFfi**: prefer_tmux, policy_order, candidates[], selected_pid
- **CandidateTraceFfi**: pid, cwd, tty, parent_app, is_live, has_tmux, match_type, match_rank, updated_at, rank_key[]

---

# Journey 1: "I'm new and want to understand the architecture" (Learn mode)

## User Mental Model Target
- **Newcomer understanding**: daemon is authoritative source, state flows in one direction
- **Complexity scaffold**: Start with "what" before "how" and "why"
- **Progressive disclosure**: Show structure first, then contracts, then trace logic

## Ordered Panels (Priority 1-7)

### 1. **Overview Panel** (Priority 1)
**Location**: Top of interface, always visible
**Content**:
- High-level architecture diagram (3 boxes: Claude/Shell → Daemon → Swift)
- One-sentence per box explaining role
- Confidence badges: deterministic/heuristic/best-effort flows
**Why**: Establish mental map before detail

### 2. **Current Flow Selector** (Priority 2)
**Location**: Below overview, sticky during scroll
**Content**:
- 3 flows as tabs: "Realtime Session Tracking", "Dashboard + Rust Core", "Project Activation Path"
- **Default for Learn mode**: Realtime Session Tracking (simplest, no activation)
- Description: 2-3 sentences on what this flow accomplishes
**Why**: Let user pick learning path based on what they want to understand

### 3. **Step-by-Step Narrative** (Priority 3)
**Location**: Left sidebar, scrollable
**Content**:
- Ordered list of edges in flow
- Each step: "1. Claude hook event enters the hook binary" (plain language)
- Current step highlighted with visual indicator
- **Learn mode enhancement**: Auto-advance with 2s delay between steps
**Why**: Guided tour through the flow

### 4. **Interface Graph** (Priority 4)
**Location**: Center canvas, zoomable/pannable
**Content**:
- Nodes (13 components) + edges (17 interfaces)
- Edge states: done (green), active (orange), future (gray)
- **Learn mode behavior**: Animated edges when auto-advancing steps
- Minimap in corner for orientation
**Why**: Visual reference for spatial relationships

### 5. **Contracts Reference** (Priority 5)
**Location**: Right sidebar, collapsible sections
**Content**:
- 3 contracts: Daemon IPC, Swift<->Rust UniFFI, Activation Adapter Layer
- Each: title, 1-line summary, 4 bullet points
- **Learn mode behavior**: Auto-expand contract when flow enters that boundary
**Why**: On-demand detail without overwhelming

### 6. **Interface Detail Focus Box** (Priority 6)
**Location**: Right sidebar, below contracts
**Content**:
- Active edge: boundary type, request/response shape, confidence level
- File paths as collapsible details
- **Learn mode enhancement**: Show "Why this matters" annotation
**Why**: Deep-dive on current step's interface

### 7. **Trace Log** (Priority 7)
**Location**: Bottom panel, fixed height, scrollable
**Content**:
- Append-only log: "[flow] action: edge name"
- Timestamp + request→response detail
- **Learn mode behavior**: Paused (trace for Debug/Trace modes)
**Why**: Provides history, but not primary for learning

## Panel Interconnections (Master-Detail)
- **Flow selector → Step list**: Changes flow resets to step 0
- **Step list → Graph**: Clicking step updates graph highlighting
- **Graph edge → Focus box**: Clicking edge shows interface detail
- **Step advancement → Contracts**: Entering new boundary auto-expands contract
- **All interactions → Trace log**: Append action to history

## Top 3 Things Current Interface Gets Wrong

1. **No clear entry point**: Interface drops you at Flow 1 Step 0 with no explanation of what you're looking at. Needs "Start Here" onboarding.

2. **Contracts compete with graph**: Right sidebar shows contracts + detail simultaneously. For learning, contracts should be hidden until relevant to current step.

3. **Auto-play has no narrative**: The timeline scrubber auto-advances but doesn't explain *why* each step matters. Needs annotations like "This is where we validate session_id is present".

## Killer Feature: **"Explain This Step" AI Copilot**

When user pauses on a step, a button appears: "Why does this matter?"
- Clicking opens a modal with:
  - Plain-language explanation of what happens at this boundary
  - Why Rust/Swift are split here (FFI safety, testability, etc.)
  - What would break if this interface was removed
  - Link to relevant source code with line numbers

**Why it's killer**: Transforms static docs into interactive learning tool. Users can ask "why" without leaving the interface.

---

# Journey 2: "Activation failed and I need to debug why" (Debug mode)

## User Mental Model Target
- **Outcome-first**: Show the decision that was made before the logic
- **Fault localization**: Distinguish between "Rust decided wrong", "OS didn't cooperate", "heuristic missed"
- **Actionable insight**: Point to what to change (policy rank, shell state, terminal config)

## Ordered Panels (Priority 1-8)

### 1. **Decision Outcome Banner** (Priority 1)
**Location**: Top of interface, full-width alert
**Content**:
- "Primary Action: LaunchTerminalWithTmux (session: capacitor)"
- "Fallback: ActivatePriorityFallback"
- "Reason: Found shell (pid=12345) in tmux session 'capacitor' but no client attached"
- Color-coded: Green (expected), Yellow (fallback used), Red (both failed)
**Why**: Immediate answer to "What did the resolver decide?"

### 2. **Decision Trace Table** (Priority 2)
**Location**: Below banner, sortable table
**Content from DecisionTraceFfi**:
- Columns: PID | CWD | Match Type | Rank | Live | Tmux | Parent App | Updated At
- Rows sorted by policy rank (best first)
- Selected PID highlighted
- **Debug enhancement**: Show why each candidate lost (e.g., "Lost on rule 2: parent match vs exact match")
**Why**: Visualize shell selection logic with data

### 3. **Policy Rules Breakdown** (Priority 3)
**Location**: Left sidebar, accordion
**Content from POLICY_TABLE**:
- 6 rules as sections
- Each rule: pass/fail indicator for selected shell
- Example: "✅ Rule 1: Live shells beat dead shells → shell 12345 is live"
- **Debug mode behavior**: Auto-expand first failing rule
**Why**: Pinpoint which rule caused unexpected selection

### 4. **Interface Graph** (Priority 4)
**Location**: Center canvas
**Content**:
- **Auto-focus on activation flow** (not realtime tracking)
- Start at step 7 (resolve_activation call)
- Edges color-coded by confidence: deterministic (green), heuristic (yellow), best-effort (red)
**Why**: Show where confidence drops in execution path

### 5. **Failure Category Diagnosis** (Priority 5)
**Location**: Right sidebar, top section
**Content**:
- Three failure categories with indicators:
  - **(a) Rust decided wrong**: If selected shell doesn't match project path or wrong policy rank
  - **(b) Swift executed correctly but OS didn't cooperate**: If fallback was triggered (check logs)
  - **(c) Heuristic targeting missed**: If action was ActivateApp (Ghostty) or ActivateByTty with Unknown terminal
- For each: "Most likely cause" + "Check this"
**Why**: Triage debugging direction immediately

### 6. **Shell State Inspector** (Priority 6)
**Location**: Right sidebar, middle section
**Content**:
- Selected shell details: cwd, tty, parent_app, tmux_session, tmux_client_tty, is_live, updated_at
- Derived fields: project_path, project_id (from daemon reducer logic)
- **Debug enhancement**: Show resolution trace (how project_path was derived from file_path/cwd)
**Why**: Verify daemon state matches reality

### 7. **Tmux Context Panel** (Priority 7)
**Location**: Right sidebar, bottom section
**Content**:
- session_at_path (from list-windows query)
- has_attached_client (from list-clients query)
- home_dir exclusion rule
- **Debug enhancement**: Show raw tmux commands that were run
**Why**: Verify Swift's tmux queries are correct

### 8. **Execution Trace Log** (Priority 8)
**Location**: Bottom panel, scrollable
**Content**:
- Activation flow edges with timestamps
- Fallback trigger events
- OS API results (NSWorkspace, AppleScript exit codes)
**Why**: Full audit trail for "Swift executed but OS failed" cases

## Panel Interconnections (Master-Detail)
- **Decision banner → Trace table**: Highlights selected_pid row
- **Trace table row click → Shell inspector**: Loads shell details
- **Policy rules → Trace table**: Clicking failing rule highlights candidates that passed vs failed
- **Failure category → Graph**: Clicking category highlights relevant edges (e.g., "heuristic" shows Ghostty activation edge)
- **Graph edge → Focus box**: Clicking edge shows confidence level + why (from DecisionTraceFfi.confidence_note)

## Top 3 Things Current Interface Gets Wrong

1. **Trace is not filterable**: The live trace log shows ALL events. For debugging, user wants to filter by edgeId or search for "Ghostty" to find activation attempt.

2. **No "Compare Expected vs Actual"**: User knows what SHOULD have happened (switch to tmux session X). Interface doesn't let them specify expected outcome and diff against actual.

3. **Confidence levels are passive**: Edges show confidence badges but don't explain *why* they're heuristic. E.g., Ghostty should explain "No accessibility API for window targeting, we activate app and hope".

## Killer Feature: **"What Should Have Happened?" Counterfactual Mode**

User specifies desired outcome: "I wanted to switch to tmux session 'capacitor' in iTerm"
- Interface re-runs resolver with *hypothetical* shell state:
  - "If you had a live shell with parent_app=iTerm + tmux_session=capacitor + tmux_client_tty=/dev/ttys000, policy would select pid=X and action would be ActivateHostThenSwitchTmux"
- Shows diff: Current state vs Required state
- Actionable fix: "Your shell has parent_app=Unknown. Run `echo $TERM_PROGRAM` to verify iTerm is detected."

**Why it's killer**: Turns post-mortem debugging into forward-looking guidance. User learns what conditions would produce correct behavior.

---

# Journey 3: "I'm watching a live session and want to trace events" (Trace mode)

## User Mental Model Target
- **Real-time monitoring**: See events as they arrive, not just static snapshots
- **Temporal reasoning**: Understand causal chains (event A triggers state B triggers action C)
- **Burst handling**: Don't miss events when 10 arrive in 1 second

## Ordered Panels (Priority 1-7)

### 1. **Live Status Banner** (Priority 1)
**Location**: Top of interface, full-width
**Content**:
- Connection status: "Connected via SSE to localhost:9133/activation-trace"
- Event counter: "127 events received (3 activation attempts)"
- Playback controls: Pause | Resume | Speed (1x, 2x, 5x, 10x)
**Why**: User needs to know if they're receiving live data

### 2. **Event Stream Timeline** (Priority 2)
**Location**: Below banner, horizontal timeline
**Content**:
- Time axis (last 60 seconds)
- Events as dots on timeline, color-coded by flow
- Burst compression: 5+ events in <1s rendered as cluster
- Scrubber: Drag to replay from specific time
**Why**: Temporal overview before detail

### 3. **Interface Graph with Live Overlay** (Priority 3)
**Location**: Center canvas
**Content**:
- Static graph (13 nodes, 17 edges)
- **Live overlay**: Animated pulse on edge when event flows through
- Pulse color matches flow (realtime=blue, dashboard=green, activation=orange)
- **Trace mode behavior**: Graph doesn't auto-focus; user can pan/zoom during live trace
**Why**: Spatial reference for where events are occurring

### 4. **Event Feed** (Priority 4)
**Location**: Right sidebar, scrollable
**Content**:
- Reverse-chronological list of events
- Each event: timestamp, edge name, request→response summary
- Click to expand: Full DecisionTraceFfi or EventEnvelope payload
- **Trace mode enhancement**: Auto-scroll to latest (with pause-on-hover)
**Why**: Primary data source for live events

### 5. **Filter Panel** (Priority 5)
**Location**: Left sidebar, top section
**Content**:
- Filter by flow: [x] Realtime [ ] Dashboard [x] Activation
- Filter by edge: Dropdown with all 17 edges
- Filter by node: Dropdown with all 13 nodes
- Search: Text input for keyword search in event payload
**Why**: Handle burst events by showing only relevant data

### 6. **Scrubber Timeline** (Priority 6)
**Location**: Bottom of interface, fixed position
**Content**:
- Horizontal scrubber (same as current interface)
- Markers for each event on timeline
- Markers color-coded by confidence: deterministic (green), heuristic (yellow), best-effort (red)
- **Trace mode behavior**: Clicking marker pauses live mode and jumps to that event
**Why**: Navigate history while live data continues to accumulate

### 7. **Trace Log** (Priority 7)
**Location**: Bottom panel, above scrubber
**Content**:
- Append-only log (same as Learn/Debug modes)
- **Trace mode enhancement**: Live data appends automatically
- Max 1000 events (auto-prune oldest)
**Why**: Persistent audit trail

## Panel Interconnections (Master-Detail)
- **Live status → Event feed**: Pause button freezes event feed scroll
- **Timeline scrubber → Graph**: Clicking timeline marker highlights corresponding edge on graph
- **Event feed click → Focus box**: Clicking event shows full payload in detail panel
- **Filter panel → Event feed + Graph**: Applying filter dims non-matching edges on graph and hides non-matching events in feed
- **Graph edge click → Filter panel**: Clicking edge auto-filters event feed to that edge only

## Top 3 Things Current Interface Gets Wrong

1. **No burst compression**: If 20 PreToolUse events arrive in 2 seconds, the interface shows 20 separate lines. Should cluster as "20x PreToolUse in 2.1s".

2. **Scrubber and live data conflict**: When live mode is active, the scrubber shows current state, but user can't easily "rewind 10 seconds" without disconnecting live.

3. **No causal chains**: Events are logged flat. User can't see "SessionStart triggered Working state which triggered first activation attempt". Need parent-child relationships.

## Killer Feature: **"Replay Last 30 Seconds" with Causal Graph**

User clicks "Replay" button:
- Interface switches to playback mode (live data paused)
- Events from last 30s replay at 2x speed
- As events replay, a **causal graph** builds in the Focus box:
  - Nodes: Events (SessionStart, UserPromptSubmit, etc.)
  - Edges: Causal links ("SessionStart caused state=Ready")
  - Color-coded by flow
- User can click any node to see full event payload
- User can export causal graph as PNG or JSON

**Why it's killer**: Turns event stream into *story*. User understands not just "what happened" but "what caused what". Especially powerful for debugging race conditions or unexpected state transitions.

---

# Summary: Cross-Journey Insights

## Shared Needs Across All Journeys
1. **Interface Detail Focus Box**: All three journeys need to inspect edge contracts (boundary, request/response, confidence)
2. **Trace Log**: All three journeys need append-only event history
3. **Graph as Spatial Reference**: All three journeys use graph for orientation (even if not primary)

## Journey-Specific Priorities

| Need | Learn | Debug | Trace |
|------|-------|-------|-------|
| Auto-advance steps | ✅ Yes | ❌ No | ❌ No |
| Decision trace table | ❌ No | ✅ Yes | 🟡 Optional |
| Live data feed | ❌ No | ❌ No | ✅ Yes |
| Contracts reference | ✅ Yes | 🟡 Optional | ❌ No |
| Failure diagnosis | ❌ No | ✅ Yes | ❌ No |
| Temporal timeline | ❌ No | ❌ No | ✅ Yes |

## Recommended Default Views

- **Learn mode**: Overview → Flow selector (Realtime) → Auto-advance steps with contract expansion
- **Debug mode**: Decision outcome banner → Trace table → Policy rules breakdown
- **Trace mode**: Live status banner → Event stream timeline → Event feed with filters

---

# Implementation Priority

If building from scratch:

**Phase 1** (Core infrastructure):
- Interface graph with node/edge positioning
- Step-by-step navigation with state updates
- Decision trace table (from DecisionTraceFfi)
- Focus box with edge detail

**Phase 2** (Learn mode):
- Auto-advance with 2s delay
- Contract auto-expansion on boundary entry
- "Explain This Step" AI copilot

**Phase 3** (Debug mode):
- Decision outcome banner
- Policy rules breakdown
- Failure category diagnosis
- "What Should Have Happened?" counterfactual

**Phase 4** (Trace mode):
- SSE/WebSocket connection
- Event stream timeline with burst compression
- Scrubber with live data
- "Replay Last 30 Seconds" causal graph

**Phase 5** (Polish):
- Keyboard shortcuts (1/2/3 for flows, Left/Right for steps, Space for play/pause)
- Export trace as JSON
- Permalink to specific step
- Dark mode toggle
