# Legacy / Dead Code Audit Summary (Daemon Phase 7)

## Findings by Severity
- **High:** 1
- **Medium:** 3
- **Low:** 3

## Top Issues (Fix Order)
1. Remove hud-core local staleness overrides so daemon state is authoritative (`core/hud-core/src/sessions.rs`).
2. Remove or align stale staleness constants (`core/hud-core/src/state/types.rs`).
3. Fix/remove dead test referencing `ProcessLivenessSnapshot` (`core/hud-core/src/state/daemon.rs`).
4. Mark ADR-002 and other legacy docs as historical/superseded.
5. Rename or document `is_locked` meaning across daemon + Swift client.

## Recommended Next Actions
- Strip local staleness logic in hud-core and rely exclusively on daemon state.
- Delete legacy constants and tests that refer to removed types.
- Add doc banners for lock-file/lock-holder ADRs and completed plans.
- Rename `is_locked` to a daemon-native term or add clarifying comment.
