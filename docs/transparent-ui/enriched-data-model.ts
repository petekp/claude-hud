/**
 * Enriched Data Model for Capacitor Interface Explorer
 *
 * This TypeScript schema enriches the existing visualization primitives
 * (nodes, edges, flows) with semantic properties extracted from the real
 * system implementation (reducer.rs, policy.rs, activation.rs).
 *
 * Design Principle:
 * - Every addition makes BEHAVIOR visible, not just structure
 * - UI can answer: "Why did this state transition happen?"
 * - UI can render: "What policy rule selected this candidate?"
 *
 * Example Use Cases:
 * - Highlight which POLICY_TABLE rule eliminated a candidate
 * - Show state machine transitions when hovering a daemon node
 * - Render decision trace to explain resolver selections
 */

// ═══════════════════════════════════════════════════════════════════════════
// 1. Node Enrichment
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Layer assignment for visual swimlane grouping.
 * UI uses this to vertically position nodes in separate tiers.
 */
type Layer = "external" | "process" | "daemon" | "persistence" | "ui" | "logic" | "executor";

/**
 * State machine definition embedded in a node.
 * UI renders this as an expandable panel showing possible transitions.
 */
interface StateMachine {
  /** Human-readable name (e.g., "SessionState FSM") */
  name: string;

  /** All possible states (e.g., ["Working", "Ready", "Idle", "Compacting", "Waiting"]) */
  states: string[];

  /** Valid transitions with their triggering events */
  transitions: StateTransition[];

  /** Current state (for live visualization) */
  currentState?: string;
}

interface StateTransition {
  from: string;
  to: string;
  trigger: string; // Event name (e.g., "UserPromptSubmit")
  condition?: string; // Guard condition (e.g., "session is not active")
}

/**
 * Policy table for ranked decision logic.
 * UI renders this as a numbered list, highlights which rule was decisive.
 */
interface PolicyTable {
  /** Human-readable name (e.g., "Activation Selection Policy") */
  name: string;

  /** Ordered rules (rank 0 = highest priority) */
  rules: PolicyRule[];

  /** Optional context that enables/disables rules */
  context?: Record<string, boolean>; // e.g., { prefer_tmux: true }
}

interface PolicyRule {
  rank: number;
  description: string; // e.g., "live shells beat dead shells"
  enabled: boolean; // Some rules are conditional (tmux preference)
}

/**
 * Sample payloads for this node's inputs/outputs.
 * UI shows these in a code block with syntax highlighting.
 */
interface SamplePayload {
  label: string; // e.g., "SessionStart event"
  mimeType: "application/json" | "text/plain";
  content: string; // JSON or plaintext sample
}

/**
 * Known failure modes for this node.
 * UI renders as warning icons with hover tooltips.
 */
interface FailureMode {
  scenario: string; // e.g., "Stale event arrives after newer event"
  symptom: string; // e.g., "Session state doesn't update"
  mitigation: string; // e.g., "Timestamp comparison skips stale events"
}

/**
 * Enriched node schema.
 */
interface EnrichedNode {
  // Existing fields
  id: string;
  title: string;
  subtitle: string;
  x: number;
  y: number;
  tag: string;

  // NEW: Semantic enrichment
  layer: Layer;
  stateMachine?: StateMachine;
  policyTable?: PolicyTable;
  samplePayloads?: SamplePayload[];
  failureModes?: FailureMode[];
}

// ═══════════════════════════════════════════════════════════════════════════
// 2. Edge Enrichment
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Boundary type classification.
 * UI color-codes edges by boundary type.
 */
type BoundaryType =
  | "process-boundary" // Hook → daemon
  | "ipc-boundary" // daemon socket
  | "ffi-boundary" // Swift ↔ Rust
  | "in-process" // Function call
  | "system-boundary"; // macOS APIs

/**
 * Latency class for visual delay indication.
 * UI animates edges with different speeds.
 */
type LatencyClass = "instant" | "fast" | "network" | "blocking";

/**
 * Directionality of data flow.
 * UI renders different arrow styles.
 */
type Directionality = "request-response" | "fire-and-forget" | "bidirectional";

/**
 * Known failure modes for this edge.
 * UI shows warning icon if edge has failure modes.
 */
interface EdgeFailureMode {
  scenario: string; // e.g., "Daemon socket file missing"
  symptom: string; // e.g., "Connection refused"
  recovery: string; // e.g., "Daemon restarts, recreates socket"
}

/**
 * TypeScript type annotation for data shape.
 * UI shows this in a hover tooltip.
 */
interface DataShape {
  request?: string; // TypeScript type (e.g., "{ protocol_version: number, method: string }")
  response?: string; // TypeScript type (e.g., "{ ok: boolean, data: any }")
}

/**
 * Enriched edge schema.
 */
interface EnrichedEdge {
  // Existing fields
  id: string;
  from: string;
  to: string;
  label: string;
  name: string;
  boundary: string;
  request: string;
  response: string;
  confidence?: "deterministic" | "heuristic" | "best-effort";
  confidenceNote?: string;
  files: string[];

  // NEW: Semantic enrichment
  boundaryType: BoundaryType;
  latencyClass: LatencyClass;
  directionality: Directionality;
  failureModes?: EdgeFailureMode[];
  dataShape?: DataShape;
}

// ═══════════════════════════════════════════════════════════════════════════
// 3. Flow Enrichment
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Branch point in a flow where execution can fork.
 * UI renders as diamond decision nodes.
 */
interface BranchPoint {
  stepIndex: number; // Which step triggers the branch
  condition: string; // e.g., "has_attached_client == true"
  truePath: string[]; // Edge IDs if condition is true
  falsePath: string[]; // Edge IDs if condition is false
}

/**
 * Invariant that must hold at a step.
 * UI renders as assertion badges.
 */
interface Invariant {
  stepIndex: number;
  description: string; // e.g., "session_id must be present"
  violation: string; // What happens if violated
}

/**
 * Debug hints for troubleshooting.
 * UI shows these in a "Debug Tips" panel.
 */
interface DebugHint {
  stepIndex: number;
  symptom: string; // e.g., "Activation doesn't switch to correct shell"
  checkpoints: string[]; // e.g., ["Verify tmux client is attached", "Check shell TTY matches"]
}

/**
 * State change at a step.
 * UI animates state transitions.
 */
interface StateChange {
  stepIndex: number;
  stateMachine: string; // Which state machine (e.g., "SessionState")
  from?: string; // Previous state (omit if initializing)
  to: string; // New state
  trigger: string; // Event that caused transition
}

/**
 * Enriched flow step.
 */
interface EnrichedFlowStep {
  edgeId: string;
  note: string;

  // NEW: Semantic enrichment
  branchPoint?: BranchPoint;
  invariants?: Invariant[];
  debugHints?: DebugHint[];
  stateChange?: StateChange;
}

/**
 * Enriched flow schema.
 */
interface EnrichedFlow {
  id: string;
  name: string;
  description: string;
  steps: EnrichedFlowStep[];
}

// ═══════════════════════════════════════════════════════════════════════════
// 4. New Top-Level Concepts
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Reusable state machine definition.
 * UI can reference these by ID in nodes.
 */
interface StateMachineDefinition {
  id: string;
  name: string;
  states: string[];
  transitions: StateTransition[];
}

/**
 * Ranked decision table.
 * UI renders as a visual decision matrix.
 */
interface DecisionTable {
  id: string;
  name: string;
  rules: PolicyRule[];
  context: Record<string, boolean>; // Runtime context that affects rule evaluation
}

/**
 * Concrete example scenario walking through a flow.
 * UI plays these as animated walkthroughs.
 */
interface Scenario {
  id: string;
  name: string;
  description: string;
  flowId: string; // Which flow this scenario exercises
  payload: Record<string, any>; // Input data
  expectedOutcome: string;
  trace: ScenarioTraceStep[];
}

interface ScenarioTraceStep {
  stepIndex: number;
  edgeId: string;
  snapshot: Record<string, any>; // State snapshot at this step
  note: string;
}

/**
 * Catalog of what can go wrong and where.
 * UI shows this as a troubleshooting guide.
 */
interface FailureCatalog {
  id: string;
  name: string;
  entries: FailureCatalogEntry[];
}

interface FailureCatalogEntry {
  symptom: string;
  affectedNodes: string[]; // Node IDs
  affectedEdges: string[]; // Edge IDs
  diagnosis: string;
  resolution: string;
  severity: "info" | "warning" | "error" | "critical";
}

// ═══════════════════════════════════════════════════════════════════════════
// 5. Before/After Comparison
// ═══════════════════════════════════════════════════════════════════════════

/**
 * OLD MODEL:
 *
 * daemon node = {
 *   id: "daemon",
 *   title: "capacitor-daemon",
 *   subtitle: "single writer + reducer",
 *   x: 540, y: 162,
 *   tag: "core/daemon"
 * }
 *
 * This tells you WHERE the daemon is, but not HOW IT BEHAVES.
 */

/**
 * NEW MODEL:
 *
 * daemon node = {
 *   id: "daemon",
 *   title: "capacitor-daemon",
 *   subtitle: "single writer + reducer",
 *   x: 540, y: 162,
 *   tag: "core/daemon",
 *   layer: "daemon",
 *   stateMachine: {
 *     name: "SessionState FSM",
 *     states: ["Working", "Ready", "Idle", "Compacting", "Waiting"],
 *     transitions: [
 *       { from: "Ready", to: "Working", trigger: "UserPromptSubmit" },
 *       { from: "Working", to: "Waiting", trigger: "PermissionRequest" },
 *       { from: "Working", to: "Ready", trigger: "Stop (hook_active=false)" },
 *       // ... all 8+ transitions from reducer.rs
 *     ]
 *   },
 *   samplePayloads: [
 *     {
 *       label: "SessionStart event",
 *       mimeType: "application/json",
 *       content: '{"event_id":"evt-1","event_type":"session_start","session_id":"abc"}'
 *     }
 *   ],
 *   failureModes: [
 *     {
 *       scenario: "Stale event arrives (older timestamp)",
 *       symptom: "Session state doesn't update",
 *       mitigation: "reduce_session() compares timestamps, skips stale events"
 *     }
 *   ]
 * }
 *
 * Now the UI can:
 * - Show a state diagram with live state highlighting
 * - Animate transitions when events flow through
 * - Warn about staleness when hovering the daemon node
 * - Provide sample payloads for debugging
 */

/**
 * OLD MODEL:
 *
 * resolver node = {
 *   id: "resolver",
 *   title: "resolve_activation()",
 *   subtitle: "pure decision logic",
 *   x: 810, y: 590,
 *   tag: "Rust module"
 * }
 *
 * This says it's "decision logic" but gives no insight into HOW it decides.
 */

/**
 * NEW MODEL:
 *
 * resolver node = {
 *   id: "resolver",
 *   title: "resolve_activation()",
 *   subtitle: "pure decision logic",
 *   x: 810, y: 590,
 *   tag: "Rust module",
 *   layer: "logic",
 *   policyTable: {
 *     name: "Activation Selection Policy",
 *     rules: [
 *       { rank: 0, description: "live shells beat dead shells", enabled: true },
 *       { rank: 1, description: "path specificity: exact > child > parent", enabled: true },
 *       { rank: 2, description: "tmux preference (when attached)", enabled: false },
 *       { rank: 3, description: "known parent app beats unknown", enabled: true },
 *       { rank: 4, description: "most recent timestamp wins", enabled: true },
 *       { rank: 5, description: "higher PID breaks ties", enabled: true }
 *     ],
 *     context: { prefer_tmux: false }
 *   },
 *   samplePayloads: [
 *     {
 *       label: "Shell candidates",
 *       mimeType: "application/json",
 *       content: '[{"pid":12345,"cwd":"/project","parent_app":"Ghostty","is_live":true}]'
 *     }
 *   ],
 *   failureModes: [
 *     {
 *       scenario: "Multiple shells at same path with different recency",
 *       symptom: "Wrong shell selected",
 *       mitigation: "Policy table ranks by liveness > path > tmux > parent > timestamp"
 *     }
 *   ]
 * }
 *
 * Now the UI can:
 * - Render the POLICY_TABLE as a numbered list
 * - Highlight which rule was decisive for a selection
 * - Show why tmux preference is disabled (no attached client)
 * - Explain the ranked comparison logic visually
 * - Provide concrete examples of candidate evaluation
 */

// ═══════════════════════════════════════════════════════════════════════════
// 6. How UI Would Use These Enrichments
// ═══════════════════════════════════════════════════════════════════════════

/**
 * NODE PANEL (when daemon node is clicked):
 *
 * [Daemon Node Detail]
 *
 * State Machine: SessionState FSM
 * Current State: Working
 *
 * Possible Transitions:
 *   → Waiting (on PermissionRequest)
 *   → Ready (on Stop with hook_active=false)
 *   → Compacting (on PreCompact)
 *
 * Sample Input:
 * {
 *   "event_type": "user_prompt_submit",
 *   "session_id": "abc123"
 * }
 *
 * Known Issues:
 * ⚠️ Stale events: Events with old timestamps are skipped
 */

/**
 * NODE PANEL (when resolver node is clicked):
 *
 * [Resolver Node Detail]
 *
 * Selection Policy (ranked):
 *   1. ✅ Live shells beat dead shells
 *   2. ✅ Path specificity (exact > child > parent)
 *   3. ❌ Tmux preference (disabled: no attached client)
 *   4. ✅ Known parent app beats unknown
 *   5. ✅ Most recent timestamp wins
 *   6. ✅ Higher PID breaks ties
 *
 * Last Decision:
 *   Selected PID: 22222 (Ghostty)
 *   Decisive Rule: #4 (known parent)
 *   Rejected: PID 11111 (Unknown parent)
 *
 * Sample Candidates:
 * [Show table with pid, parent_app, is_live, match_rank, timestamp]
 */

/**
 * EDGE PANEL (when e14 "executor → OS" is clicked):
 *
 * [Edge Detail: Executor → OS]
 *
 * Boundary: Swift → macOS system boundary
 * Latency: Blocking (~100-500ms)
 * Direction: Request-response
 * Confidence: Heuristic
 *
 * Data Shape:
 *   Request: tmux switch-client, AppleScript, NSWorkspace
 *   Response: Bool (success/failure)
 *
 * Known Issues:
 * ⚠️ Ghostty window targeting is heuristic (no exact window API)
 * ⚠️ User focus may be blocked by another app
 *
 * Files: ActivationAdapters.swift, ActivationActionExecutor.swift
 */

/**
 * FLOW PANEL (when activation flow is playing):
 *
 * Step 7: Executor routes by action variant
 *
 * Branch Point:
 *   Condition: primary action success?
 *   ✓ True → Return success
 *   ✗ False → Execute fallback (step 8)
 *
 * Invariants:
 *   ✓ ActivationAction variant is valid
 *   ✓ Adapter for action exists
 *
 * Debug Tips:
 *   If activation doesn't work, check:
 *   • Tmux client is attached (run `tmux list-clients`)
 *   • Shell TTY matches expected value
 *   • Parent app has accessibility permissions
 *
 * State Change:
 *   [none] (executor is stateless)
 */

// ═══════════════════════════════════════════════════════════════════════════
// 7. Implementation Notes
// ═══════════════════════════════════════════════════════════════════════════

/**
 * To populate this enriched model:
 *
 * 1. Extract state machines from reducer.rs:
 *    - Parse SessionState enum variants
 *    - Parse reduce_session() match arms
 *    - Build transition table
 *
 * 2. Extract policy tables from policy.rs:
 *    - Parse POLICY_TABLE constant
 *    - Parse SelectionPolicy.compare() logic
 *    - Identify conditional rules (prefer_tmux)
 *
 * 3. Extract decision traces from trace.rs:
 *    - Use DecisionTraceFfi + CandidateTraceFfi
 *    - Map to UI-friendly structure
 *
 * 4. Extract failure modes from:
 *    - CLAUDE.md gotchas section
 *    - Test case descriptions
 *    - Code comments with "IMPORTANT" or "BUG FIX"
 *
 * 5. Add live data integration:
 *    - Fetch daemon state snapshot from /daemon-snapshot
 *    - Fetch routing snapshot/diagnostics from /routing-snapshot + /routing-diagnostics
 *    - Fetch rollout gate state from /routing-rollout
 *    - Overlay activation outcome events from /telemetry-stream
 */

export type {
  // Nodes
  EnrichedNode,
  Layer,
  StateMachine,
  StateTransition,
  PolicyTable,
  PolicyRule,
  SamplePayload,
  FailureMode,

  // Edges
  EnrichedEdge,
  BoundaryType,
  LatencyClass,
  Directionality,
  EdgeFailureMode,
  DataShape,

  // Flows
  EnrichedFlow,
  EnrichedFlowStep,
  BranchPoint,
  Invariant,
  DebugHint,
  StateChange,

  // New top-level
  StateMachineDefinition,
  DecisionTable,
  Scenario,
  ScenarioTraceStep,
  FailureCatalog,
  FailureCatalogEntry
};
