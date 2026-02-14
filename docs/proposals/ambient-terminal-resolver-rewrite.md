# Ambient Terminal Resolver Rewrite Proposal

## 1. Executive Summary

This proposal replaces the current ambient shell routing stack with a single authoritative resolver service.

Current behavior is split across hook-derived shell telemetry, daemon snapshots, Swift-side heuristics, and direct tmux introspection in separate code paths. This creates observable mismatches such as:
- UI showing `tmux detached` while tmux has an attached client
- `target unknown` despite known historical targets
- project cards resolving as `ready` while a nested workspace is actively working

The rewrite centralizes all routing and status decisions into one deterministic resolver with explicit reason codes and confidence levels.

## 2. Problem Statement

### 2.1 User-visible failures
- Status row can diverge from real tmux state during long-running pane activity.
- Global-most-recent shell selection can overshadow project-scoped intent.
- Different freshness thresholds across layers lead to unstable state transitions.

### 2.2 Architectural root causes
- Split source of truth: Swift UI, daemon snapshot, and launcher each infer state independently.
- Hook cadence dependence: shell telemetry only updates on prompt/postexec boundaries.
- Heuristic coupling: UI logic infers tmux attachment from stale shell entries.
- Ambiguous fallback semantics: “live but unknown” and “stale with known target” are merged inconsistently.

## 3. Goals and Non-goals

### 3.1 Goals
1. One source of truth for routing decisions.
2. Deterministic decision algorithm with explainable output.
3. Project/workspace-scoped target resolution.
4. Explicit handling of stale/partial telemetry.
5. Shared status model consumed by both UI and activation flows.

### 3.2 Non-goals
1. Rebuilding all tmux/terminal activation execution logic.
2. Redesigning UI visuals beyond status semantics.
3. Supporting legacy schema compatibility by default (breaking changes are acceptable unless explicitly requested otherwise).

## 4. Proposed Architecture

### 4.1 New component: Ambient Routing Engine (ARE)

ARE runs in the daemon and exposes a single API:
- `get_routing_snapshot(project_path, scope_context)`

All consumers use this API:
- Projects status row
- Active project resolver hints
- Terminal launcher preflight logic

### 4.2 Signal model

ARE ingests three signal streams:

1. **ShellSignal** (event-driven, low trust)
- source: `hud-hook cwd`
- fields: `pid`, `proc_start`, `cwd`, `tty`, `parent_app`, `tmux_session?`, `tmux_client_tty?`, `recorded_at`

2. **TmuxSignal** (polled, high trust)
- source: daemon tmux poller every 1-2s
- fields: `client_tty`, `session_name`, `pane_tty`, `pane_current_path`, `captured_at`

3. **ProcessSignal** (guardrail)
- source: process liveness checks
- fields: `pid`, `proc_start`, `is_alive`, `checked_at`

Trust order for tmux attachment:
1. `TmuxSignal` attached clients
2. recent validated shell signal
3. unknown

### 4.3 State stores

1. `ShellRegistry` keyed by `(pid, proc_start)`
2. `TmuxRegistry` keyed by `client_tty` and `session_name`
3. `WorkspaceBindings` mapping workspace identity -> preferred session candidates and path patterns
4. `RoutingState` materialized cache of last resolver output per workspace

### 4.4 Resolver contract

ARE returns a `RoutingSnapshot`:

```json
{
  "version": 1,
  "workspace_id": "...",
  "project_path": "...",
  "status": "attached|detached|unavailable",
  "target": {
    "kind": "tmux_session|terminal_app|none",
    "value": "capacitor"
  },
  "confidence": "high|medium|low",
  "reason_code": "TMUX_CLIENT_ATTACHED",
  "reason": "Attached tmux client on /dev/ttys022 mapped to session capacitor",
  "evidence": [
    {"type": "tmux_client", "value": "/dev/ttys022", "age_ms": 420},
    {"type": "pane_path", "value": "/Users/.../capacitor", "age_ms": 430}
  ],
  "updated_at": "2026-02-14T21:03:52Z"
}
```

### 4.5 Resolver algorithm (deterministic)

1. Determine effective workspace scope.
2. Pull freshest `TmuxSignal` within freshness window.
3. If attached client exists:
- resolve candidate sessions by path proximity + workspace bindings
- emit `attached` + chosen tmux target
4. If no attached client but tmux sessions exist for scope:
- emit `detached` + tmux target (actionable attach/switch)
5. Else evaluate terminal shell fallback by scoped shell signals.
6. Emit `unavailable` only when no trusted evidence exists.

Tie-break precedence:
1. Scope match quality (exact workspace > repo sibling > global)
2. Signal trust (tmux poll > shell telemetry)
3. State activity class (working/waiting/compacting > ready/idle)
4. Freshness

## 5. API Surface

### 5.1 New daemon endpoints
- `get_routing_snapshot(project_path, workspace_id?)`
- `get_routing_diagnostics(project_path)` (debug-only)

### 5.2 Existing endpoint changes
- Keep `get_shell_state` for diagnostics only; not primary UI status input.
- Session/project state APIs unchanged except optional `routing_hint` embedding for migration.

## 6. Data and Freshness Policy

Single shared thresholds (daemon-owned):
- `TMUX_SIGNAL_FRESH_MS = 5000`
- `SHELL_SIGNAL_FRESH_MS = 600000`
- `SHELL_RETENTION_HOURS = 24`

No separate Swift-side staleness constants.

## 7. Migration Plan

### Phase 0: Instrumentation
- Add reason-code telemetry and decision snapshots behind feature flag.

### Phase 1: Dual-run
- Compute ARE snapshots in daemon while UI still uses legacy path.
- Log divergence metrics: `legacy_vs_are_status_mismatch`, `legacy_vs_are_target_mismatch`.

### Phase 2: Read-only cutover
- UI status row reads ARE snapshot.
- Launcher still keeps legacy fallback path as safety net.

### Phase 3: Full cutover
- Activation preflight uses ARE snapshot as primary input.
- Remove Swift-side routing heuristics and stale inference code.

### Phase 4: Cleanup
- Retain `get_shell_state` and low-level diagnostics only for debug panels.

## 8. Testing Strategy

1. **Property tests (daemon)**
- deterministic outputs for identical input sets
- precedence invariants

2. **Scenario tests (integration)**
- attached tmux + stale shell
- detached tmux + live shell
- multiple workspaces in same repo
- rapid shell churn and pid reuse

3. **Contract tests (Swift client)**
- rendering by `status/reason_code` only
- no local heuristic recomputation

4. **Shadow-mode production checks**
- divergence budget thresholds before cutover

## 9. Observability

Emit structured events:
- `routing_snapshot_emitted`
- `routing_signal_stale`
- `routing_conflict_detected`
- `routing_scope_ambiguous`

Each includes `workspace_id`, `reason_code`, `confidence`, `selected_target`, `signal_ages_ms`.

## 10. Risks and Mitigations

1. **tmux polling overhead**
- mitigate with bounded cadence and incremental diffing

2. **workspace mapping ambiguity in monorepos**
- mitigate with explicit `WorkspaceBindings` and path-scoring diagnostics

3. **migration regressions**
- mitigate with dual-run divergence gating

## 11. Acceptance Criteria

1. Status row and activation resolver agree on attachment/target in >99.5% of events during dual-run.
2. `tmux detached` false negatives reduced by >95% against baseline.
3. No Swift routing heuristics needed for status determination.
4. All routing decisions explainable via `reason_code` + evidence.

## 12. Open Questions for External Reviewer

1. Should tmux polling be event-driven (socket hooks) instead of periodic polling?
2. Is confidence scoring useful, or should status be strictly categorical + reason code?
3. Do we need cross-machine awareness for shared tmux sessions in future?
4. Is the proposed precedence ordering robust for managed worktrees and nested repos?

## 13. Suggested Initial Task Breakdown

1. Add `RoutingSnapshot` schema + endpoint in daemon.
2. Implement tmux poller and registry.
3. Implement resolver with deterministic precedence.
4. Add dual-run divergence metrics.
5. Cut UI status row to snapshot consumption.
6. Cut launcher preflight to snapshot consumption.
7. Remove legacy Swift routing heuristics.
