# Subsystem 01: Daemon Core + Protocol

## Findings

### [DAEMON] Finding 1: Tombstone IPC method appears unused outside tests

**Severity:** Low
**Type:** Dead code
**Location:** `core/daemon-protocol/src/lib.rs:16-24`, `core/daemon/tests/ipc_smoke.rs:344-358`

**Problem:**
`Method::GetTombstones` is defined in the shared IPC protocol and exercised by the daemon test suite, but there is no production client usage in the Swift app or hud-core. This leaves a test-only surface that is effectively unused in normal operation.

**Evidence:**
- Protocol enum includes `GetTombstones` (`core/daemon-protocol/src/lib.rs:16-24`).
- Only in-repo call site is the IPC smoke test (`core/daemon/tests/ipc_smoke.rs:344-358`).

**Recommendation:**
If tombstone introspection is not required outside tests, remove the method from the protocol and handler, or gate it behind a debug-only feature.

