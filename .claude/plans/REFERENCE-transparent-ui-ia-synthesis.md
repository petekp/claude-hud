# Transparent UI: Unified Information Architecture Synthesis

**Status:** ACTIVE
**Date:** 2026-02-06
**Inputs:** 4 parallel research tracks from `ia-exploration` team

---

## Executive Summary

Four independent researchers converged on a remarkably consistent vision: **the Interface Explorer should evolve from a topology viewer ("what connects to what") into a behavior explainer ("how decisions are made and why")**. The 5 highest-impact changes, drawn from cross-track agreement, are:

1. **Session State Machine Panel** — Make the 5-state FSM visible, not just "session tracking"
2. **Policy Decision Table** — Show the 6 ranked activation rules as a first-class panel
3. **Structured Candidate Trace** — Replace flat logs with a ranked comparison table
4. **Boundary Failure Annotations** — Every edge documents what can break and what happens next
5. **Mode-Specific Panel Layouts** — Learn, Debug, Trace get different default panel arrangements

---

## Convergence Map: Where All 4 Tracks Agree

| Principle | Competitive Research | Gap Analysis | Journey Design | Data Model |
|-----------|---------------------|-------------|----------------|------------|
| **3-layer progressive disclosure** | DevTools, XState, Wireshark all use Overview → Selection → Detail | Gap matrix confirms topology-only limits debugging | All 3 journeys define 7-8 panels in priority order | Model defines `EnrichedNode` with expandable sub-structures |
| **Keep the graph visible always** | "Persistent overview" pattern in every successful tool | — | "Graph as spatial reference" shared across all journeys | — |
| **State machine must be visible** | XState Inspector's killer feature: live state highlighting | P0 gap: "session tracking is a black box" | Debug mode opens with Decision Outcome Banner | `StateMachine` interface with states, transitions, currentState |
| **Policy logic must be readable** | Structurizr C4 uses hierarchical abstraction for decision layers | P0 gap: "selection algorithm is opaque" | Debug Journey Panel #3: Policy Rules Breakdown | `PolicyTable` interface with ranked rules and context |
| **Dim, don't hide, unrelated content** | Mental models research: breadth-first scanning requires spatial context | — | Trace mode filters dim non-matching edges, never remove | — |

---

## The 5 Highest-Impact IA Changes

### Change 1: Session State Machine Panel

**Research backing:** Gap Analysis P0 #1 + Competitive Research (XState Inspector pattern) + Data Model (`StateMachine` interface)

**What to build:**
- A visual state diagram embedded in the daemon node's detail panel
- 5 states rendered as circles: Working (blue), Ready (green), Idle (gray), Compacting (yellow), Waiting (orange)
- Transitions rendered as labeled arrows between states
- In Trace mode: current state highlighted with a pulse animation
- In Debug mode: show which state the session was in when activation fired
- In Learn mode: auto-advance through a sample event sequence, highlighting state changes

**Data structure** (from enriched model):
```typescript
stateMachine: {
  name: "SessionState FSM",
  states: ["Working", "Ready", "Idle", "Compacting", "Waiting"],
  transitions: [
    { from: "Ready", to: "Working", trigger: "UserPromptSubmit" },
    { from: "*", to: "Working", trigger: "PreToolUse / PostToolUse / PostToolUseFailure" },
    { from: "Working", to: "Waiting", trigger: "PermissionRequest" },
    { from: "Working", to: "Compacting", trigger: "PreCompact" },
    { from: "Working", to: "Ready", trigger: "Stop (hook_active=false, event not stale)" },
    { from: "*", to: "Ready", trigger: "TaskCompleted" },
    { from: "*", to: "Ready", trigger: "Notification (idle_prompt)" },
    { from: "*", to: "Waiting", trigger: "Notification (permission_prompt)" },
    { from: "Working", to: "Ready", trigger: "Auto-ready (>=60s tool inactivity, tools_in_flight=0)" },
    { from: "Compacting", to: "Working", trigger: "UserPromptSubmit" },
    { from: "*", to: "Ready", trigger: "SessionStart (not active)" },
    { from: "*", to: "—", trigger: "SubagentStart / SubagentStop / TeammateIdle (ignored)" },
    { from: "*", to: "—", trigger: "SessionEnd (delete)" },
  ],
  currentState: "Working" // live from daemon
}
```

**Panel location:** Expandable sub-panel inside the daemon node detail view. In Debug mode, promoted to top-level visible panel.

---

### Change 2: Policy Decision Table

**Research backing:** Gap Analysis P0 #2 + Journey Design (Debug Panel #3) + Data Model (`PolicyTable` interface) + Competitive Research (Structurizr's hierarchical abstraction)

**What to build:**
- A numbered list of the 6 POLICY_TABLE rules, displayed when clicking the `resolve_activation()` node
- Each rule shows: rank number, human-readable description, pass/fail status for last decision
- Conditional rules (tmux preference) show their enable/disable state with explanation
- In Debug mode: auto-expand to show which rule was decisive
- In Learn mode: step through rules one-by-one as part of the activation flow walkthrough

**Visual design:**
```
Selection Policy (ranked):
  1. ✅ Live shells beat dead shells        [both live]
  2. ⭐ Path specificity: exact > child     [exact vs child → decisive]
  3. ⚪ Tmux preference                     [disabled: no client]
  4. — Known parent app beats unknown       [skipped: decided at #2]
  5. — Most recent timestamp wins           [skipped]
  6. — Higher PID breaks ties               [skipped]
```

**Panel location:** Primary content of the resolver node detail panel. In Debug mode, promoted alongside the Decision Outcome Banner.

---

### Change 3: Structured Candidate Trace

**Research backing:** Gap Analysis P0 #3 + Journey Design (Debug Panel #2: "Decision Trace Table") + Data Model (`CandidateTraceFfi` + rank_key) + Competitive Research (Wireshark's 3-pane forensic layout)

**What to build:**
- Replace the flat "action: edge.name" trace log with a structured table when in Debug mode
- Columns: PID | CWD | Match Type | Rank | Live | Tmux | Parent App | Updated At
- Each row shows the candidate's `rank_key` array: `["live=1", "path_rank=2", "tmux=0", ...]`
- Selected candidate highlighted in green, runner-ups in neutral, eliminated in dim
- Clicking a row shows full `CandidateTraceFfi` with shell details
- "Why did this candidate lose?" tooltip on eliminated rows showing first failing rule

**Wireshark-inspired enhancement for Trace mode:**
- Left column: Event list (packet list equivalent)
- Center column: Selected event's candidate table (protocol breakdown equivalent)
- Right column: Shell state snapshot at that moment (raw bytes equivalent)

**Panel location:** Replaces or augments the current Trace Log panel. In Debug mode, this is Panel #2 (immediately below the Decision Outcome Banner).

---

### Change 4: Boundary Failure Annotations

**Research backing:** Gap Analysis P1 #4 + Data Model (`EdgeFailureMode` interface) + Journey Design (Debug Panel #5: "Failure Category Diagnosis")

**What to build:**
- Every edge in the graph gains an optional ⚠️ icon when it has known failure modes
- Hovering the icon shows a tooltip with: scenario, symptom, recovery/fallback
- In Debug mode: edges involved in a failure are highlighted in red, with the failure tooltip auto-expanded
- New edge metadata:

```typescript
failureModes: [
  {
    scenario: "Daemon socket closed",
    symptom: "Connection refused",
    recovery: "Daemon restarts and recreates socket"
  },
  {
    scenario: "FFI panic in Rust",
    symptom: "Swift receives nil from UniFFI",
    recovery: "Falls back to ActivatePriorityFallback"
  }
]
```

**Three failure categories** (from Journey Design):
- **(a) Rust decided wrong** — Policy selection doesn't match user expectation
- **(b) Swift executed correctly, OS didn't cooperate** — Fallback triggered by external failure
- **(c) Heuristic targeting missed** — Best-effort action (Ghostty, Alacritty) lacks precision

**Panel location:** Inline on edges (hover tooltips). In Debug mode, a dedicated "Failure Diagnosis" sidebar section.

---

### Change 5: Mode-Specific Panel Layouts

**Research backing:** Competitive Research (Backstage metadata-driven nav, D2's separate diagrams) + Journey Design (3 distinct panel priority orderings) + Gap Analysis (observation that all journeys share graph + trace but differ in primary panels)

**What to build:**

Three default panel arrangements that activate when the user switches modes:

**Learn Mode Layout:**
```
┌──────────────────────────────────────────────────┐
│ [Overview: High-level 3-box architecture]        │
├───────────┬─────────────────────┬────────────────┤
│ Step-by-  │                     │ Contracts      │
│ Step      │   Interface Graph   │ (auto-expand   │
│ Narrative │   (animated edges)  │  on boundary   │
│ (left)    │                     │  entry)        │
├───────────┴─────────────────────┴────────────────┤
│ [Flow Selector: Realtime | Dashboard | Activate] │
└──────────────────────────────────────────────────┘
```

**Debug Mode Layout:**
```
┌──────────────────────────────────────────────────┐
│ [Decision Outcome Banner — color-coded result]   │
├──────────────────────────────────────────────────┤
│ [Decision Trace Table — candidates + rank keys]  │
├───────────┬─────────────────────┬────────────────┤
│ Policy    │                     │ Failure        │
│ Rules     │   Interface Graph   │ Diagnosis      │
│ Breakdown │   (auto-focus on    │ Shell State    │
│ (left)    │    activation flow) │ Inspector      │
├───────────┴─────────────────────┴────────────────┤
│ [Execution Trace Log — with OS API results]      │
└──────────────────────────────────────────────────┘
```

**Trace Mode Layout:**
```
┌──────────────────────────────────────────────────┐
│ [Live Status Banner — connection + event count]  │
├──────────────────────────────────────────────────┤
│ [Event Stream Timeline — last 60s, color-coded]  │
├───────────┬─────────────────────┬────────────────┤
│ Filters   │                     │ Event Feed     │
│ (flow,    │   Interface Graph   │ (reverse-chron │
│  edge,    │   (live pulse on    │  auto-scroll,  │
│  node,    │    active edges)    │  pause-on-     │
│  search)  │                     │  hover)        │
├───────────┴─────────────────────┴────────────────┤
│ [Scrubber Timeline — markers + click-to-replay]  │
└──────────────────────────────────────────────────┘
```

---

## Interaction Model

### Core Principles (from competitive research consensus)

1. **Graph is persistent.** It never disappears. Detail panels slide beside or below it, never replace it.
2. **Selection dims, not hides.** Clicking a node reduces unrelated nodes to 40% opacity. Spatial memory is preserved.
3. **Tabs for peer content, triangles for hierarchy.** Detail panels use tabs (Overview | State | Events | Flow). Expandable nodes use disclosure triangles (▸).
4. **Layer 4 by explicit action.** Source code, raw JSON payloads — these open in a modal or copy to clipboard. Never inline.
5. **Mode switching = layout switching.** It's "selecting a different diagram" (D2/Mermaid mental model), not "filtering the same diagram."

### Navigation Flow

```
Mode Selector (Learn | Debug | Trace)
  ↓
Panel layout reconfigures
  ↓
Node click → Side panel appears (tabbed: Overview | State | Events | Flow)
  ↓
Edge click → Focus box shows boundary type, data shape, failure modes
  ↓
[Optional] "View Source" button → Modal with syntax-highlighted code
```

---

## Disagreements Between Research Tracks

### 1. Static SVGs vs. Dynamic Graph

- **Competitive Research** recommends static SVGs per mode (D2/Mermaid pattern) — simpler, faster rendering
- **Journey Design** assumes a single dynamic graph with mode-specific highlighting and animation
- **Resolution:** Keep a single dynamic graph (the current approach works well) but pre-compute node visibility per mode. Some nodes are hidden in Learn mode (e.g., SQLite detail nodes) but revealed in Debug mode. This is a middle ground: one graph engine, mode-specific node sets.

### 2. Side Panel vs. Bottom Panel for Details

- **Competitive Research** recommends side panel (Chrome DevTools pattern) — doesn't reduce graph height
- **Journey Design** uses both side and bottom panels depending on mode
- **Resolution:** Use a **right sidebar** for node/edge details (persistent, doesn't reduce graph area). Use the **bottom panel** only for temporal data (trace logs, timeline scrubbers) which benefit from full-width horizontal layout.

### 3. "Explain This Step" AI Copilot (from Journey Design)

- **Journey Design** proposes an AI-powered "Why does this matter?" modal
- **No other track addresses this**
- **Resolution:** Defer to Phase 5 (polish). The static content (state machines, policy tables, failure modes) already answers "why" for most questions. An AI copilot adds value but is a separate feature, not an IA change.

### 4. "What Should Have Happened?" Counterfactual (from Journey Design)

- **Journey Design** proposes re-running the resolver with hypothetical shell state
- **No other track addresses this**
- **Resolution:** This is a killer debugging feature but requires runtime infrastructure (a WASM-compiled resolver or daemon endpoint). Classify as Phase 4, after core IA changes land.

---

## Phased Implementation Order

### Phase 1: Data Model + Core Panels (Foundation)
*Prerequisite for everything else*

- [ ] Implement the enriched data model (`EnrichedNode`, `EnrichedEdge`, `EnrichedFlow`)
- [ ] Populate `stateMachine` for daemon node from reducer.rs data
- [ ] Populate `policyTable` for resolver node from policy.rs data
- [ ] Populate `failureModes` for edges from boundary analysis
- [ ] Add `boundaryType`, `latencyClass`, `directionality` to all edges
- [ ] Create tabbed detail panel (Overview | State | Events | Flow) for node selection
- [ ] Implement dim-on-select (40% opacity for unrelated nodes)

### Phase 2: Mode-Specific Layouts
*Makes each mode purposeful*

- [ ] Implement layout switching on mode change
- [ ] **Learn mode:** Add step-by-step narrative sidebar with auto-advance
- [ ] **Debug mode:** Add Decision Outcome Banner + Decision Trace Table
- [ ] **Trace mode:** Add Live Status Banner + Event Stream Timeline
- [ ] Pre-compute node visibility sets per mode (Learn shows fewer nodes)
- [ ] Add flow-path highlighting with traveling dot animation (Learn mode)

### Phase 3: Behavioral Panels
*The "why" layer*

- [ ] Session State Machine visualization (embedded SVG in daemon detail)
- [ ] Policy Rules Breakdown with pass/fail indicators per rule
- [ ] Structured Candidate Trace Table with rank keys
- [ ] Boundary Failure tooltips with ⚠️ icons
- [ ] Failure Category Diagnosis sidebar for Debug mode (Rust wrong / OS failed / heuristic missed)

### Phase 4: Live Integration
*Connect to running system*

- [ ] SSE/WebSocket connection to daemon for live events
- [ ] Real-time state highlighting (XState Inspector pattern)
- [ ] Event burst compression (5+ events in <1s → cluster)
- [ ] Scrubber-to-replay with graph state restoration
- [ ] "What Should Have Happened?" counterfactual engine

### Phase 5: Polish
*Refinement and delight*

- [ ] Keyboard shortcuts: 1/2/3 for modes, ←/→ for steps, Space for play/pause
- [ ] "View Source" modal with syntax highlighting
- [ ] Export trace as JSON / PNG
- [ ] Permalink to specific step
- [ ] "Explain This Step" AI copilot
- [ ] Contract auto-expansion when entering a boundary in Learn mode
- [ ] "Replay Last 30 Seconds" causal graph (Trace mode)

---

## Concrete Panel Layout Spec

### Shared Chrome (all modes)

| Element | Position | Content |
|---------|----------|---------|
| Mode Selector | Top bar, left | `Learn` · `Debug` · `Trace` (tab buttons) |
| Search | Top bar, right | Text input: "Filter nodes, edges, events…" |
| Interface Graph | Center canvas | 13 nodes, 17 edges — always visible |
| Detail Panel | Right sidebar, 320px | Tabbed: Overview · State · Events · Flow |
| Trace Log | Bottom, 180px | Append-only event history |

### Learn Mode Additions

| Element | Position | Content |
|---------|----------|---------|
| Step Narrative | Left sidebar, 260px | Ordered list of steps with plain-language descriptions |
| Contracts Ref | Right sidebar, below detail | 3 collapsible contract summaries |
| Flow Selector | Below mode selector, sticky | Dropdown: Realtime \| Dashboard \| Activation |

### Debug Mode Additions

| Element | Position | Content |
|---------|----------|---------|
| Decision Banner | Full-width, below mode selector | Color-coded outcome with primary/fallback/reason |
| Candidate Table | Below banner, 240px | Sortable: PID \| CWD \| Match \| Live \| Tmux \| Parent |
| Policy Sidebar | Left sidebar, 260px | 6 ranked rules with pass/fail indicators |
| Failure Diagnosis | Right sidebar, below detail | Category indicators: Rust / OS / Heuristic |

### Trace Mode Additions

| Element | Position | Content |
|---------|----------|---------|
| Live Banner | Full-width, below mode selector | Connection status + event counter + playback controls |
| Event Timeline | Below banner, 80px | Horizontal timeline with color-coded event dots |
| Filter Panel | Left sidebar, 260px | Checkboxes: flow, edge, node, text search |
| Event Feed | Right sidebar (replaces detail) | Reverse-chronological, auto-scroll, expandable |

---

## Deliverable Inventory

| Track | Agent | Output File | Key Contribution |
|-------|-------|-------------|------------------|
| Competitive IA Patterns | competitive-researcher | `.claude/docs/transparent-ui-ia-research.md` | 3-layer hierarchy + persistent overview + 8 anti-patterns |
| Gap Matrix | gap-analyst | `.claude/gap-matrix-explorer-vs-system.md` | 28 gaps in 4 tiers, 5 P0-critical |
| User Journey IA | journey-architect | `.claude/plans/REFERENCE-task3-ux-architecture-design.md` | 3 journey designs, 22 total panels, 3 killer features |
| Semantic Data Model | data-modeler | `docs/transparent-ui/enriched-data-model.ts` | TypeScript interfaces for enriched nodes/edges/flows |
| **Synthesis** | **team lead** | **This document** | Unified recommendation with phased implementation |

---

## One-Line Summary

> **Transform the Interface Explorer from "here are the boxes and arrows" into "here is exactly why Capacitor made this decision, what could have gone wrong, and what state the system was in when it happened."**
