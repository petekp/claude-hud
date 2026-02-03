# Subsystem Audit: hud-hook CLI + IPC Client

**Files reviewed**
- `core/hud-hook/src/main.rs`
- `core/hud-hook/src/handle.rs`
- `core/hud-hook/src/cwd.rs`
- `core/hud-hook/src/daemon_client.rs`
- `core/daemon-protocol/src/lib.rs`

**Purpose**
Parses Claude Code hook payloads and forwards events to the daemon. Also sends shell CWD events to the daemon for ambient tracking.

---

### [HUD-HOOK] Finding 1: SessionEnd can be rejected when `cwd` is missing

**Severity:** Medium
**Type:** Bug
**Location:** `core/hud-hook/src/handle.rs:80-97`, `core/daemon-protocol/src/lib.rs:182-221`

**Problem:**
`hud-hook` only skips events with missing `cwd` when the action is not `Delete`. For `SessionEnd`, it allows the missing `cwd` through and substitutes an empty string. The daemon protocol requires a non-empty `cwd` for `SessionEnd`, so the event is rejected. This can leave sessions undeleted until TTL cleanup, showing stale session state.

**Evidence:**
- `handle.rs` skips missing `cwd` only when `action != Delete`, then uses `cwd.unwrap_or_default()` before sending. (`core/hud-hook/src/handle.rs:80-97`)
- The daemon protocol requires `session_id`, `pid`, and non-empty `cwd` for `SessionEnd`. (`core/daemon-protocol/src/lib.rs:182-221`)

**Recommendation:**
Either:
- Allow `SessionEnd` to omit `cwd` in the protocol (treat as optional and rely on stored session), or
- Preserve last-known `cwd` for the session in the hook payload (e.g., pass through from `HookInput` when available) and explicitly skip `SessionEnd` if it cannot be resolved.

---

### [HUD-HOOK] Finding 2: Session events have a 150ms IPC timeout with no retry

**Severity:** Medium
**Type:** Design flaw
**Location:** `core/hud-hook/src/daemon_client.rs:21-23`, `core/hud-hook/src/daemon_client.rs:164-185`

**Problem:**
Hook events rely on a 150ms read/write timeout and have no retry on failure. Under transient daemon load or slow I/O, events can be dropped, leading to incorrect session state (missed transitions or stuck state). Shell CWD events retry once, but session events do not.

**Evidence:**
- `READ_TIMEOUT_MS`/`WRITE_TIMEOUT_MS` are both 150ms. (`core/hud-hook/src/daemon_client.rs:21-23`)
- `send_handle_event` returns `false` on error; no retry is attempted. (`core/hud-hook/src/daemon_client.rs:164-185`)

**Recommendation:**
Add a limited retry for session events (same as shell CWD) or increase timeouts slightly (e.g., 500–1000ms) to avoid dropping events during brief daemon stalls.

