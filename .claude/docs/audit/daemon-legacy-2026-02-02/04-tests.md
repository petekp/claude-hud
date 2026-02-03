# Subsystem 04: Tests (Legacy Harnesses)

## Findings

### [TESTS] Finding 1: Resolver integration tests target removed lock-based API

**Severity:** Medium
**Type:** Dead code
**Location:** `core/hud-core/tests/resolver_integration.rs:1-60`

**Problem:**
The test suite imports `StateStore`, `resolve_state_with_details`, and `create_lock`, which no longer exist in hud-core. These tests are based on lock-file semantics that were removed in daemon-only mode, so they are effectively obsolete.

**Evidence:**
- Test imports reference removed APIs (`resolver_integration.rs:23-26`).
- Comments and test cases are built around lock detection and `sessions.json` state (`resolver_integration.rs:1-12`).

**Recommendation:**
Delete these tests or rewrite them to assert daemon snapshot-based behavior.

---

### [TESTS] Finding 2: Tombstone bats test assumes sessions.json + filesystem tombstones

**Severity:** Medium
**Type:** Dead code
**Location:** `tests/hud-hook/tombstone.bats:12-62`

**Problem:**
The bats test suite verifies `sessions.json` and `ended-sessions/` tombstones, but hooks now send events to the daemon and tombstones live in the daemon database. This test no longer reflects real behavior.

**Evidence:**
- Test config targets `sessions.json` and `ended-sessions` (`tombstone.bats:12-16`).
- Assertions read JSON files and tombstone files directly (`tombstone.bats:46-61`).

**Recommendation:**
Remove the test or rework it to drive daemon IPC and validate tombstones via the daemon API.

