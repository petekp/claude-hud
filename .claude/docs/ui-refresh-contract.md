# UI Refresh Contract (Daemon-Only)

This document defines the **expected polling cadence** and **UI refresh behavior** now that
project/session state is sourced exclusively from the daemon.

## Primary Polling Loops

### 1) Session state + UI refresh (AppState)
- **Cadence:** every **2s**
- **Source:** `AppState.setupStalenessTimer()`
- **Actions:**
  - `refreshSessionStates()` → daemon project states + ActiveProjectResolver
  - `checkIdeasFileChanges()`
  - `checkHookDiagnostic()` every ~10s (every 5 ticks)
  - `checkDaemonHealth()` every ~16s (every 8 ticks)
  - `loadDashboard()` every ~30s (every 15 ticks)

**File:** `apps/swift/Sources/Capacitor/Models/AppState.swift`

### 2) Shell state polling (ShellStateStore)
- **Cadence:** every **2s**
- **Source:** `ShellStateStore.startPolling()`
- **Action:** `daemonClient.fetchShellState()`
- **Staleness filter:** shells older than **10 minutes** are ignored for focus resolution

**File:** `apps/swift/Sources/Capacitor/Models/ShellStateStore.swift`

## Refresh Semantics

- **Daemon is authoritative.** Clients must not reinterpret state (no local staleness/TTL heuristics).
- **UI updates are coalesced** to avoid layout churn:
  - `AppState.refreshSessionStates()` uses a **16ms debounce** before `objectWillChange.send()`.
- **If the daemon is unavailable**, state refreshes may fail; the UI should keep last known state and retry on next tick.

## Client Behavior Guarantees

- Project cards reflect **daemon project-level aggregation** (not per-session merges).
- Shell focus resolution uses daemon shell snapshots filtered by staleness.
- No file-based state is read for session/project state.

## Change Control

Any changes to polling intervals or refresh triggers should update this doc and
be justified against CPU/logging impact and UI responsiveness.
