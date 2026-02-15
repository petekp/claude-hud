# Ambient Routing Engine (ARE) Rollout Runbook

This runbook covers rollout gating and cutover decisions for daemon-owned routing snapshots.

## Scope

- Daemon is source of truth for routing snapshots.
- Swift status row and launcher consume daemon snapshots only (hard cutover).
- Swift active project resolution no longer falls back to shell CWD detection.
- Legacy Swift shell-routing heuristics and shadow-compare runtime path are removed.
- Dual-run compares daemon snapshot output against daemon-side legacy decisioning for rollout health.

Manual interaction validation for project-card activation is documented in:

- `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md` (canonical)

## Flags

Daemon (`~/.capacitor/daemon/hem-v2.toml`):

```toml
[routing]
enabled = false

[routing.feature_flags]
dual_run = true
emit_diagnostics = true
```

Swift (`AppConfig`) legacy ARE overrides are deprecated and ignored at runtime.

## Health Gate Fields

Read from `get_health.data.routing.rollout`:

- `agreement_gate_target`: fixed at `0.995`
- `min_comparisons_required`: fixed at `1000`
- `min_window_hours_required`: fixed at `168` (7 days)
- `comparisons`: number of dual-run comparisons
- `volume_gate_met`
- `window_gate_met`
- `status_agreement_rate`
- `target_agreement_rate`
- `first_comparison_at`
- `last_comparison_at`
- `window_elapsed_hours`
- `status_gate_met`
- `target_gate_met`
- `status_row_default_ready`
- `launcher_default_ready`

Interpretation:
- Status-row default gate: `status_row_default_ready == true`
- Launcher default gate: `launcher_default_ready == true`
- Gate readiness requires all of:
  - `dual_run_enabled == true`
  - `volume_gate_met == true`
  - `window_gate_met == true`
  - `status_agreement_rate >= 0.995` (status row)
  - `target_agreement_rate >= 0.995` (launcher)

## Rollout Procedure

1. Shadow mode
- Set `routing.enabled=false`, `routing.feature_flags.dual_run=true`.
- Swift client does not expose legacy ARE runtime toggles.

2. Observe agreement rates
- Poll `get_health`.
- Require `status_agreement_rate >= 0.995`.
- Require `target_agreement_rate >= 0.995`.
- Require `comparisons >= 1000`.
- Require `window_elapsed_hours >= 168` (at least 7 days between first and latest comparison sample).

3. Status row cutover
- Runtime status row remains daemon-snapshot-only.
- Treat `status_row_default_ready=true` as operational evidence that default cutover is healthy.
- Keep launcher validation under observation until `launcher_default_ready=true`.

4. Launcher cutover
- Runtime launcher remains daemon-snapshot-only.
- Treat `launcher_default_ready=true` as operational evidence that full activation targeting is healthy.
- Keep dual-run running through the release cycle validation window.

5. Cleanup phase (complete)
- Status row and launcher are daemon-snapshot-only.
- Swift heuristic status-row copy and shadow divergence compare runtime path are removed.

## Sustained Cleanup Policy

Code deletion requires a stricter window than daemon default-ready gates:

- Status-row cleanup eligibility:
  - `status_row_default_ready == true` for 14 consecutive days.
  - `dual_run_enabled == true` for the full 14-day window.
- Phase 4 cleanup eligibility (shadow + launcher legacy consumers):
  - `launcher_default_ready == true` for 14 consecutive days.
  - `dual_run_enabled == true` for the full 14-day window.

Regression reset rule:

- Any sampled `get_health` response where the required gate is false resets that gate's 14-day sustained counter.
- Any sampled `get_health` response where `dual_run_enabled == false` resets both sustained counters.

## Blocking Conditions

Do not cut over defaults if any are true:
- `dual_run_enabled == false`
- `volume_gate_met == false`
- `window_gate_met == false`
- `status_gate_met == false`
- `target_gate_met == false` (for launcher cutover)
- Sustained increase in mismatch counters:
  - `legacy_vs_are_status_mismatch`
  - `legacy_vs_are_target_mismatch`

## Quick Checks

Request:

```json
{
  "protocol_version": 1,
  "method": "get_health"
}
```

Expected gate-ready example:

```json
{
  "routing": {
    "dual_run_enabled": true,
    "rollout": {
      "comparisons": 1462,
      "window_elapsed_hours": 241,
      "status_row_default_ready": true,
      "launcher_default_ready": true
    }
  }
}
```
