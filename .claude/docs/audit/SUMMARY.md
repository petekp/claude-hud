# Hook System Audit Summary

**Scope:** Hook-driven session state detection (hooks → hud-hook → daemon → session state → diagnostics).

## Findings By Severity
- **Critical:** 0
- **High:** 1
- **Medium:** 5
- **Low:** 0

## Top Findings (Priority Order)
1. **Active sessions downgrade to Ready after 8s of inactivity** (`core/daemon/src/state.rs`) — causes incorrect “Ready” while Claude is still working/waiting.
2. **SessionEnd can be rejected when `cwd` is missing** (`core/hud-hook/src/handle.rs`, `core/daemon-protocol/src/lib.rs`) — session cleanup can fail.
3. **UI session matching is string-based (no normalization)** (`SessionStateManager`, `ActiveProjectResolver`) — drops state/active project when paths differ by case/symlink.
4. **Stale heartbeat treated as healthy when any session is active** (`core/hud-core/src/engine.rs`) — masks hook failures.
5. **Session events have 150ms IPC timeout with no retry** (`core/hud-hook/src/daemon_client.rs`) — transient daemon stalls can drop events.

**Other findings:**
- **Active project resolver uses fractional-only timestamp parsing** (`ActiveProjectResolver`) — can misorder sessions when timestamps omit fractional seconds.

## Recommended Fix Order
1. Fix active-state demotion logic (raise threshold or base on heartbeat/TTL).
2. Align SessionEnd validation with missing `cwd` handling.
3. Normalize paths for UI state matching (case/symlink aware).
4. Tighten hook health heuristics to avoid masking stale hooks.
5. Add retry or loosen timeouts for session event IPC.
6. Use tolerant timestamp parsing in active project resolver.

## Fixes Applied (2026-02-03)
- Preserved `Working/Waiting` session states in project aggregation (removed 8s demotion).
- Allowed `SessionEnd` without `cwd` in protocol validation.
- Normalized paths in UI session matching and active project selection.
- Added tolerant timestamp parsing via `DaemonDateParser`.
- Hook health now uses a 5-minute grace window when sessions are active to reduce false alarms.
- Increased `hud-hook` IPC timeouts to 600ms and added a retry for session events.
- Hid the setup status card when hooks are merely idle (post-first-run) to reduce noise.
- Added targeted tests for hook event retries and hook diagnostic presentation.

## Files
- `.claude/docs/audit/00-analysis-plan.md`
- `.claude/docs/audit/01-hook-config-install.md`
- `.claude/docs/audit/02-hud-hook-cli.md`
- `.claude/docs/audit/03-daemon-reducer-state.md`
- `.claude/docs/audit/04-session-detection.md`
- `.claude/docs/audit/05-health-diagnostics.md`
- `.claude/docs/audit/06-ui-behaviors.md`
- `.claude/docs/audit/07-targeted-tests.md`
