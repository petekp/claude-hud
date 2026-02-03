# Targeted Tests (Hook Session State Pipeline)

## Added
- `apps/swift/Tests/CapacitorTests/SessionStateManagerTests.swift`
  - `testSessionStateMatchingIgnoresCaseDifferences`: guards against path normalization regressions between daemon `project_path` and pinned project paths.
- `apps/swift/Tests/CapacitorTests/DaemonDateParserTests.swift`
  - Validates daemon timestamp parsing for fractional, non-fractional, microsecond, and invalid inputs.
- `apps/swift/Tests/CapacitorTests/ActiveProjectResolverTests.swift`
  - `testSelectsMostRecentReadySessionWhenNoActiveSessions`: uses non-fractional RFC3339 timestamps to ensure resolver ordering stays correct.
- `core/daemon-protocol/src/lib.rs`
  - `session_end_allows_missing_cwd`: validates `SessionEnd` accepts missing `cwd`.
- `core/hud-hook/src/daemon_client.rs`
  - `send_event_retries_after_daemon_error`: verifies session event retry succeeds after a transient daemon error.
- `core/hud-core/src/engine.rs`
  - `heartbeat_status_allows_grace_when_active` and `heartbeat_status_marks_stale_after_grace`: assert the active-session grace window behavior.

## Recommended Next Tests
None at the moment.
