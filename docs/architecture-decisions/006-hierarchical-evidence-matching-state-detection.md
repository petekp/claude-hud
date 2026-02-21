# ADR-006: Redesign State Detection with a Hierarchical Evidence Matching Engine

**Status:** Proposed

**Date:** 2026-02-13

## Context

Capacitor's current state detection is reliable enough for alpha, but it is tightly coupled to the exact behavior of today's Claude Code hooks and reducer semantics.

We need a redesign that:

1. Handles today's Claude Code limits directly and explicitly.
2. Is configurable and extensible so future Claude Code improvements can be adopted by toggling capabilities and rules, not rewriting core logic.
3. Preserves daemon single-writer guarantees from ADR-005.

Current known limits from Claude Code hooks and runtime behavior:

1. Hook config edits are not guaranteed to apply to the current session without hook review/reload flow.
2. Event payload quality is uneven across events and tools.
3. Async hook execution can introduce ordering and delivery uncertainty.
4. Some high-value observability is missing (runtime hook snapshot introspection, explicit delivery guarantees, richer structured correlation).

## Current Shortcomings and Bug Inventory

This redesign is based on concrete issues in the current implementation.

### Confirmed bugs

1. **Inconsistent daemon enable defaults across subsystems (High)**  
   `hud-hook` treats missing `CAPACITOR_DAEMON_ENABLED` as enabled (`core/hud-hook/src/daemon_client.rs:153-157`), while `hud-core` daemon reads treat the same missing variable as disabled (`core/hud-core/src/state/daemon.rs:118-122`). This can produce contradictory behavior and diagnostics in mixed environments.

2. **Shell CWD retry is not idempotent (Medium)**  
   `send_shell_cwd_event()` builds a fresh `event_id` per retry attempt (`core/hud-hook/src/daemon_client.rs:105-107`, `191-201`). Since dedupe is keyed by event id in DB (`core/daemon/src/db.rs:46-49`), a successful first write with a lost response can still generate a second distinct event on retry.

3. **HUD hook detection is over-broad and can mutate unrelated hook commands (Medium)**  
   Hook ownership detection currently uses substring matching (`c.contains("hud-hook")`) (`core/hud-core/src/setup.rs:742-745`). Any unrelated command containing that token can be normalized as a HUD hook entry.

### Structural shortcomings

1. **Runtime hook activation ambiguity**  
   Claude Code snapshots hook config at session start and requires `/hooks` review/reload for external edits (`docs/claude-code-docs-official/hooks.md:1258-1264`). Current install logic validates file content but cannot prove active runtime uptake in the current session.

2. **Unused event subscriptions increase noise and complexity**  
   We install hooks for `SubagentStart`, `SubagentStop`, and `TeammateIdle` (`core/hud-core/src/setup.rs:32-46`) while reducer currently skips these (`core/daemon/src/reducer.rs:144-146`).

3. **Hook pre-classification in `hud-hook` has dead branches for heartbeat optimization**  
   `process_event()` supports `Action::Heartbeat` for repeated `Working` events, but is invoked with `current_state = None` (`core/hud-hook/src/handle.rs:86`, `148-187`), so those branches never execute. The daemon reducer still handles correctness, but this pre-classifier is misleading and non-authoritative.

### Immediate remediation backlog before full HEM cutover

1. Align daemon enable behavior across `hud-hook`, `hud-core`, and Swift integration points with one contract: default-enabled when env is missing, explicit falsey value disables.
2. Remove forced `CAPACITOR_DAEMON_ENABLED=1` override from installed hook command and replace hook ownership identity with a Capacitor marker contract.
3. Make shell CWD retry idempotent by reusing one logical `(event_id, recorded_at)` across retries.
4. Tighten hook ownership detection from substring to canonical command identity (`hud-hook handle`) plus marker semantics.
5. Remove or downscope unused hook subscriptions (`SubagentStart`, `SubagentStop`, `TeammateIdle`) for Phase 1 unless a concrete HEM rule consumes them.
6. Add daemon state-application idempotency gate: duplicate `event_id` must not re-apply reducer effects.
7. Guarantee serialized event application (single worker or equivalent lock/transaction discipline).
8. Remove or repurpose dead heartbeat pre-classification logic.

## External Review Reconciliation (2026-02-13)

This section reconciles external review feedback against this ADR and classifies each item as:
`confirmed bug`, `valid concern`, or `out-of-scope for this ADR`.

### Critical Feedback Classification

1. Model-layer animation coupling in `SessionStateManager`: **valid concern, out-of-scope for HEM ADR**.  
   This is a Swift UI architecture concern (`apps/swift`), not daemon state-detection core logic. Track as a separate UI remediation item.
2. Inconsistent daemon enable defaults: **confirmed bug**.  
   Keep in immediate backlog and fix before HEM cutover.
3. Non-idempotent shell CWD retries: **confirmed bug**.  
   Keep in immediate backlog and fix before HEM cutover.
4. Over-broad hook ownership detection: **confirmed bug**.  
   Keep in immediate backlog and fix before HEM cutover.
5. Missing persistence for tuning parameters: **valid concern, out-of-scope for HEM ADR**.  
   Address in Swift tuning/config export workstream.
6. HEM migration divergence risk: **valid concern**.  
   Adopt stricter shadow-mode gates and replay-based regression requirements.

### Important Feedback Classification

1. Row order tracker lifecycle: **valid concern, out-of-scope for HEM ADR** (Swift UI behavior).
2. Separation of concerns for animation ownership: **valid concern, out-of-scope for HEM ADR**.
3. Refresh concurrency and cancellation coverage: **valid concern** (applies to daemon/UI boundary tests).
4. Reset-value semantics: **valid concern, out-of-scope for HEM ADR**.
5. HEM performance viability under load: **valid concern** (add profiling gate pre-cutover).
6. Capability degradation behavior for unknown/partial support: **valid concern** (codified below).

### Explicit Disagreements

1. None on daemon-side critical findings.  
   The three daemon-side bugs are accepted as pre-HEM remediation blockers.

## Second-Opinion Reconciliation Addendum (2026-02-13)

This addendum incorporates a second independent review and converts validated concerns into hard preconditions.

### Critical items (validated)

1. Daemon enable semantic mismatch: **confirmed bug**.  
   Decision: default-enabled when env var is missing; explicit falsey value disables. Apply uniformly across daemon producers/consumers and aligned Swift integration points.
2. Shell CWD retry idempotency: **confirmed bug**.  
   Decision: one logical `event_id` and `recorded_at` per emission across retries, with regression coverage for lost-response retry.
3. Hook ownership substring matcher: **confirmed bug**.  
   Decision: strict identity matcher plus marker contract; false negatives are preferred over false positives.
4. Daemon state-layer idempotency gap: **confirmed critical risk**.  
   Event-log dedupe alone is insufficient; state mutation must be conditional on first-insert semantics for `event_id`.
5. Event processing serialization uncertainty: **confirmed critical gate**.  
   Before shadow default-on, daemon must prove serialized application semantics or equivalent transactional correctness.

### Important items (validated)

1. Unused subagent/teammate hooks currently add ingestion/storage noise.
2. HEM thresholds/weights require telemetry-backed tuning with explicit sample-size rules.
3. Perf gating must include CPU/memory/write amplification and burst-tail behavior, not only event-to-snapshot latency.
4. Tombstone TTL resilience for delayed events needs an explicit policy and test coverage.
5. Deterministic output ordering is required for reliable shadow diffing and agreement metrics.

### Questions resolved for this ADR

1. **Daemon enable intent**: default-enabled on missing env; explicit disable remains supported during migration.
2. **Rollback model in Phase 2**: read-path cutover first, reducer remains fallback; rollback must not require data migration.
3. **Shadow telemetry extraction**: SQLite + logs remain source of truth; operator retrieval path must be documented before default-on shadow.

## Problem Classification (Hierarchical Matching Checklist)

This state detection problem is:

- `TWO-SIDED`: No
- `ONE-SIDED`: Yes
- `HIERARCHICAL`: Yes
- `WEIGHTED`: Yes
- `CONSTRAINED`: Yes
- `STABLE`: No (blocking-pair stability is not required)
- `OPTIMAL`: Yes (maximize match confidence under constraints)
- `FUZZY`: Yes (boundary inference can be ambiguous)

Selected family: one-sided, weighted, constrained hierarchical matching with deterministic tie-breaking.

## Decision

Adopt a new state engine called **HEM** (Hierarchical Evidence Matching).

HEM has four strict stages:

1. **Capability Layer**: declares what the upstream hook provider can and cannot guarantee.
2. **Evidence Layer**: normalizes all incoming signals into typed evidence with reliability metadata.
3. **Matching Layer**: performs hierarchical constrained weighted assignment:
   - session -> project
   - shell -> project
   - project -> effective state
4. **Synthesis Layer**: emits explainable project/session snapshots with confidence, reason chains, and deterministic outputs.

The key design constraint is that all behavior is driven by versioned configuration plus capability flags.

## Requirements Translation

| Requirement | Type | Formal Expression |
|---|---|---|
| One session maps to at most one project at a time | Capacity | `|M(session)| <= 1` |
| A shell process maps to at most one project at a time | Capacity | `|M(shell)| <= 1` |
| Project may hold multiple sessions | Capacity | `|M^-1(project)| <= project.capacity_sessions` |
| If hard exclusion rule exists, match is forbidden | Exclusion | `(entity, project) notin M if excluded(entity, project)` |
| Events older than selected watermark cannot override newer state | Ordering | `event.ts < watermark(project) => ignore` |
| Claimed state must be supported by evidence confidence threshold | Hard threshold | `confidence(state) >= theta_state` |
| Unknown capabilities must lower confidence, not silently pass | Reliability | `confidence *= capability_factor` |
| Same input and capability profile produce same output | Determinism | `run(I, C) = run(I, C)` |

Hard constraints:

1. Determinism.
2. Capacity.
3. Exclusions.
4. Monotonic watermarking by logical clocks.
5. Source reliability bounds.

Soft constraints:

1. Prefer higher-confidence and lower-latency evidence.
2. Prefer project boundary evidence from direct file paths over cwd-only.
3. Prefer local shell focus evidence for "active project" selection.

## Algorithm Choice

### Level 1 and Level 2 Matching

For `session -> project` and `shell -> project`:

1. Build sparse candidate graph from boundary resolver.
2. Compute edge score from weighted evidence model.
3. Solve assignment with deterministic sparse weighted auction-style assignment.

Why auction-style over dense Hungarian:

1. Candidate graph is sparse.
2. Capacities can be >1 and dynamic.
3. We need streaming recomputation and incremental updates.

Deterministic tie-breaker order:

1. Higher score.
2. More recent evidence timestamp.
3. Higher source reliability tier.
4. Lexicographic `(project_id, entity_id)`.

### Level 3 State Synthesis

For `project -> state`:

1. Aggregate matched evidence into state candidates (`Working`, `Waiting`, `Compacting`, `Ready`, `Idle`).
2. Apply hard guards (`tools_in_flight`, compaction guards, stop-gate guards, liveness).
3. Select max-confidence state with deterministic tie-breaker.

## Data Model

### Capability Profile

Capability profile is first-class and versioned.

```toml
[provider]
name = "claude_code"
version = "2.x"

[capabilities]
hook_snapshot_introspection = false
event_delivery_ack = false
global_ordering_guarantee = false
per_event_correlation_id = false
notification_matcher_support = true
tool_use_id_consistency = "partial" # none | partial | strong
```

### Evidence Envelope

All raw signals are normalized into:

```text
Evidence {
  evidence_id
  source_kind          # hook_event | shell_cwd | process_liveness | synthetic_guard
  source_reliability   # 0..1, capability-adjusted
  observed_at
  logical_seq          # per-session or per-entity monotonic sequence
  entity_id            # session_id or shell_pid
  project_candidates[] # from boundary resolver
  features{}           # tool_name, notification_type, stop_hook_active, etc.
}
```

### Matching Output Contract

```text
MatchResult {
  entity_id
  matched_project_id | unmatched_reason
  score
  score_breakdown[]
  constraints_applied[]
}
```

### State Output Contract

```text
ProjectStateResult {
  project_id
  state
  confidence
  updated_at
  reason_chain[]
  supporting_evidence_ids[]
  suppressed_candidates[]
}
```

## Architecture

### Components

1. `CapabilityRegistry`
2. `EvidenceNormalizer`
3. `BoundaryResolver` (project identity + containment policy)
4. `ConstraintEngine` (hard rules)
5. `ScoringEngine` (weighted soft signals)
6. `AssignmentEngine` (hierarchical matching)
7. `StateSynthesizer`
8. `SnapshotPublisher`

### Implementation Boundaries

HEM will live inside `core/daemon` (no new top-level crate required in initial rollout):

1. New internal modules under `core/daemon/src/hem/*` for capability, normalization, constraints, scoring, assignment, and synthesis.
2. `reducer.rs` remains authoritative during shadow mode and continues publishing production snapshots.
3. HEM shadow output is computed from the same ingested event stream and compared against reducer output through a divergence reporter.
4. Existing IPC/data contracts (`DaemonProjectState`, `ProjectSessionState`) remain the published API during shadow mode; HEM internals adapt to these contracts until cutover.
5. Canonical multi-session project-state precedence is owned by the daemon state layer (`project_state_policy`); HEM consumes that shared policy instead of defining a separate precedence table.

### Processing Flow

1. Ingest raw event.
2. Normalize to evidence.
3. Validate hard constraints.
4. Generate candidates.
5. Score candidates.
6. Solve assignment incrementally.
7. Synthesize project state.
8. Publish explainable snapshot.

## Configuration and Malleability

All behavior comes from configuration:

1. Capability profile.
2. Constraint pack.
3. Scoring weights.
4. Tie-break policy.
5. Per-state confidence thresholds.
6. TTL and guard windows.

Reference profile for implementation:

- `core/daemon/config/hem-v2.example.toml`

This enables immediate adoption of wishlist features:

1. If Claude adds hook runtime introspection:
   - set `hook_snapshot_introspection = true`
   - enable strict runtime config verification rule.
2. If Claude adds delivery guarantees:
   - set `event_delivery_ack = true`
   - tighten stale-event and missing-event guard penalties.
3. If Claude adds stronger correlation ids:
   - set `per_event_correlation_id = true`
   - switch in-flight tracking from counters to correlation sets.
4. If richer matchers become available:
   - reduce inbound event noise at source by matcher specialization.

## Determinism and Correctness Invariants

1. Same input batch + same config + same capability profile yields identical output.
2. No state transition without supporting evidence over threshold.
3. Watermark monotonicity prevents older events from overriding newer accepted state.
4. Constraint violations produce explicit `unmatched_reason` or suppressed candidate log.
5. Every emitted state includes reason chain and evidence ids.
6. Duplicate `event_id` deliveries are a no-op at state-application layer (not only event-log insertion layer).
7. Event application is serialized (or proven equivalent via lock/transaction semantics) for reducer-visible state.
8. Public snapshot/report ordering is deterministic for identical state (no hash-order variance in emitted arrays).

## Testing Strategy

### Phase 0.5 Regression Set (must pass before shadow default-on)

1. Daemon-enable contract tests in both `hud-hook` and `hud-core`: env missing, `"0"`, `"1"`.
2. Shell CWD retry lost-response test verifies same request/event id across retry attempts.
3. Hook ownership matcher table tests cover strict positives/negatives and prove unrelated hooks are never rewritten.
4. Duplicate-event idempotency test proves repeated `event_id` does not re-apply reducer/state mutations.
5. Serialization/race test proves no lost updates for concurrent ingress attempts.
6. Snapshot ordering test proves stable sorted output for shadow diff comparators.

### Unit Tests

1. Capability fallback behavior.
2. Candidate generation and boundary policy.
3. Constraint enforcement.
4. Score normalization and tie-break determinism.

### Property Tests

1. Determinism under repeated runs.
2. Capacity and exclusion invariants.
3. Watermark monotonicity.
4. Confidence threshold safety.

### Regression Tests

1. Stop false-positive transitions during tool completion.
2. Compaction transition correctness.
3. Missing/late notification events.
4. Subagent event leakage into parent state.
5. Late event handling after session end/tombstone window policy.

### Performance Targets

1. `P95` event-to-snapshot latency under 50 ms for typical active workspace.
2. Incremental recompute cost scales with changed entities, not full table size.
3. Burst-tail behavior remains bounded under worst-plausible tool-loop + shell-cwd spam load (no daemon/client timeout cascade).
4. Shadow-mode CPU and memory overhead stay within defined budgets vs reducer-only baseline.
5. Shadow telemetry write amplification and growth are bounded by retention policy.

## Migration Plan

### Phase 0: Schema and Config Foundation

1. Add capability profile and v2 config schema.
2. Add evidence tables without changing current reducer behavior.

### Phase 0.5: Pre-HEM Bug Remediation (Tests First)

1. Enforce unified daemon-enable contract across `hud-hook` and `hud-core` (default-on when missing; explicit falsey disable), with Swift alignment tracked in parallel.
2. Remove forced daemon-enable env injection from installed hook command; introduce a Capacitor hook marker contract for ownership.
3. Make shell CWD retry idempotent (single logical `(event_id, recorded_at)` across retries).
4. Replace substring hook ownership detection with strict command identity matching (`hud-hook handle`) plus marker requirement.
5. Remove/downscope `SubagentStart`/`SubagentStop`/`TeammateIdle` default subscriptions unless consumed in Phase 1 rules.
6. Implement state-layer duplicate-event protection: reducer/state writes must no-op when `event_id` already persisted.
7. Guarantee serialized event application (single stream or equivalent correctness proof).
8. Add regression tests for each item before behavior patching (red/green/refactor).

### Phase 1: Dual-Run Evaluation (Default-On Shadow)

1. Run HEM in shadow mode beside current reducer.
2. Emit divergence reports only.
3. Track mismatch taxonomy, confidence deltas, and confusion-matrix breakdown by state pair.
4. Feature flag defaults to shadow mode; no production state decisions from HEM in this phase.
5. Gate progression on replay suite + runtime agreement targets across both synthetic and scrubbed real traces.
6. Require minimum one-week shadow soak before cutover decision.
7. Keep shadow diagnostics on SQLite + logs; no new public IPC endpoint required in this phase.

### Phase 2: Controlled Cutover

1. Enable HEM for read path behind feature flag.
2. Keep legacy reducer as fallback.
3. Roll back read path on divergence threshold breach without migration of persisted event data.

### Phase 3: Legacy Removal

1. Remove old reducer assumptions from primary path.
2. Keep conversion tooling for historical replay.

## Consequences

Positive:

1. Clear separation between upstream capability limits and local state logic.
2. Stronger determinism and explainability.
3. Safer adoption of future Claude Code features through configuration.

Negative:

1. Higher upfront complexity than direct reducer logic.
2. Requires a new config lifecycle and validation tooling.

## Non-Goals

1. Replacing daemon single-writer architecture.
2. Introducing cloud dependencies.
3. Designing custom upstream hook semantics outside Claude Code support.

## Acceptance Criteria

1. Phase 0.5 regression set is green, including daemon-enable contract, retry-id stability, strict hook ownership matching, duplicate-event no-op, and serialization/race protection.
2. Shadow mode shows >= 99.5% agreement on **operationally defined stable states** over representative traces.
3. Stable-state agreement definition is explicit: sampling interval, transition-exclusion window, weighting policy, and mismatch severity classes.
4. Remaining divergences are categorized with explicit rule-based explanations and confusion-matrix counts.
5. Determinism property tests pass for 10 repeated runs on identical fixtures.
6. Feature-flagged capability toggles can change behavior without code edits.
7. Unknown or partially supported capabilities reduce confidence and emit structured warnings (never silently treated as strong support).
8. Performance targets are met in replay and live shadow runs: `P95` event-to-snapshot latency < 50 ms plus bounded burst-tail, CPU/memory overhead, and telemetry growth.

## Stable-State Agreement Semantics (Implemented)

For the 99.5% cutover gate, agreement is now explicitly defined in daemon code and health metrics:

1. Sampling interval: per shadow evaluation event on transition-relevant daemon events (`SessionEnd`, `TaskCompleted`, `Stop`, `ShellCwd`, `Notification`).
2. Candidate set: reducer projects whose state is in `{ready, idle}` only.
3. Transition exclusion window: exclude projects where `event.recorded_at - reducer.state_changed_at < 20s`.
4. Weighting policy: project-weighted (each eligible project contributes one sample).
5. Match rule: sample is a match only when HEM has the same project path with identical stable state.
6. Severity relation: `state_mismatch` remains `critical`, `missing_in_hem`/`extra_in_hem` remain `important`; stable-state agreement is tracked separately from mismatch severity counters.
7. Health exposure (`GetHealth.data.hem_shadow`): `stable_state_samples`, `stable_state_matches`, `stable_state_agreement_rate`, `stable_state_agreement_gate_target`, `stable_state_agreement_gate_met`.

## Capability Detection Strategy (Implemented)

Phase 1 now uses a hybrid capability-detection contract with explicit strategy control:

1. Default strategy is `runtime_handshake`.
2. Daemon reads capability declarations from config and opportunistically ingests runtime handshake data from event metadata (`capabilities` / `hem_capabilities`).
3. If declared capabilities are `unknown` or `misdeclared` at runtime, HEM applies a confidence penalty factor and emits structured warnings.
4. If deterministic behavior is preferred over runtime probing, `config_only` can be set to bypass runtime handshake and use config declarations as authoritative.
5. Capability status is exposed via `GetHealth.data.hem_shadow.capability_status` for cutover operability.

## Benchmark Acceptance Guardrails (Implemented)

The Phase 1 benchmark harness now enforces explicit acceptance thresholds and fails the benchmark run when exceeded.

1. Guarded latency metrics: shadow absolute `P95`, shadow absolute `P99`, and shadow-vs-baseline `P95/P99` deltas.
2. Guarded replay metric: replay startup delta percentage vs baseline.
3. Guarded resource metrics: peak RSS delta %, peak CPU delta %, and daemon SQLite footprint delta % (including `state.db`, `-wal`, `-shm`).
4. Thresholds are configurable via environment variables (`CAPACITOR_BENCH_MAX_*`) and included in the emitted JSON benchmark report with pass/fail evaluation details.
5. Percentage-delta gates include deterministic noise floors (`CAPACITOR_BENCH_MIN_*_DELTA_MS_FOR_PCT_GATE`) so tiny absolute shifts cannot fail the run on inflated percentages alone.
6. Percentage-delta gates also require minimum baseline latency floors (`CAPACITOR_BENCH_MIN_*_BASELINE_MS_FOR_PCT_GATE`) so relative deltas are enforced only when baseline percentiles are large enough to be meaningful.
7. Benchmark report now includes `shadow.hem_shadow_health` snapshot fields from `GetHealth` so stable-state gate readiness and blocking mismatch trends are retained per run.

## Phase 1 Operability Policy (Implemented)

### CI/Nightly Guardrail Automation

1. Nightly guardrail runs via `.github/workflows/hem-shadow-nightly.yml` on `macos-14`.
2. The job executes `scripts/ci/hem-shadow-bench.sh`, which defines the accepted benchmark profile and threshold defaults.
3. Benchmark JSON report is emitted to `CAPACITOR_BENCH_REPORT_PATH` and retained as a workflow artifact for 30 days.
4. Manual re-runs use `workflow_dispatch` with the same pinned profile to keep calibration comparisons apples-to-apples.

### Threshold Ownership and Calibration

1. Owner: daemon maintainers for `core/daemon` (PR-reviewed changes only; no ad-hoc threshold edits in local runs).
2. Source of truth: defaults in `scripts/ci/hem-shadow-bench.sh` plus benchmark gate definitions in `core/daemon/tests/hem_shadow_bench.rs`.
3. Calibration window: minimum of 7 nightly reports before raising/loosening thresholds.
4. Tightening policy: allowed after 7-run rolling median and p95 trend both show >=10% headroom to existing limit with no acceptance failures.
5. Loosening policy: requires evidence of stable regression across >=3 consecutive nightly runs, plus root-cause notes in the threshold-change PR.
6. Every threshold change PR must include: before/after limits, 7-run summary stats, and expected failure-mode impact.

### Extended Shadow Soak Readiness

1. Cutover readiness requires at least one week of shadow soak observation before any strict-mode promotion.
2. Soak tracking input is `GetHealth.data.hem_shadow` (especially `stable_state_agreement_rate`, `stable_state_agreement_gate_met`, `gate_blocking_mismatches`, and `blocking_mismatch_rate`) plus persisted mismatch categories from SQLite.
3. Weekly review should include trend snapshots from retained nightly benchmark artifacts and mismatch category counts.
4. Stable-state gate target remains `>= 0.995`; any recurring increase in blocking mismatch counters is a cutover blocker.
5. Transition-event-only shadow evaluation (`SessionEnd`, `TaskCompleted`, `Stop`, `ShellCwd`, `Notification`) is the Phase 1 final policy and is intentionally not feature-flagged.

## Alpha Fast-Cutover Override (Implemented)

For alpha usage, the daemon default engine configuration now enables HEM in `primary` mode by default when no local runtime config exists. This intentionally prioritizes fast validation and iteration over a longer shadow-only soak window.
