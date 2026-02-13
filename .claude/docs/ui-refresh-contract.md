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
- **Only newest refresh may apply.**
  - `SessionStateManager.refreshSessionStates(for:)` increments a monotonic generation counter.
  - Any detached fetch that is canceled or has a stale generation is dropped before apply.
  - This prevents older daemon responses from overwriting newer project-card state.
- **If the daemon is unavailable**, state refreshes may fail; the UI should keep last known state and retry on next tick.

## Client Behavior Guarantees

- Project cards reflect **daemon project-level aggregation** (not per-session merges).
- Shell focus resolution uses daemon shell snapshots filtered by staleness.
- No file-based state is read for session/project state.

## Project Card Transition Invariants (2026-02-12)

### Problem
Project cards regressed to visual `Idle`/`nil` while daemon state was `Ready`/`Working` when animation work changed list structure or identity boundaries.

### Cause
- Splitting card rendering into separate `grouped.active` and `grouped.idle` loops caused cross-section update stalls.
- Invalidating at card-root scope (for example `.id(ProjectOrdering.cardContentStateFingerprint(...))`) remounted card content and disrupted in-place state transitions.
- Forcing status text identity resets (for example `.id(state)`) broke continuity for SwiftUI text transitions.

### Solution
- Keep one unified row pipeline in `ProjectsView`: `rows = grouped.active + grouped.idle`, rendered by a single `ForEach`.
- Keep outer card identity stable (`project.path` / `ProjectOrdering.cardIdentityKey`), independent of session state.
- Do not remount whole card content for state transitions; animate only internal status/effect layers.
- Keep status text on SwiftUI content transitions (`.contentTransition(... .numericText())`) without identity resets.
- Ensure views observe both `appState.sessionStateRevision` and `appState.sessionStateManager.sessionStates`.

### Prevention
- Guard with regression tests:
  - `ProjectCardIdentityRegressionTests`
  - `ProjectCardSessionObservationRegressionTests`
  - `ProjectCardStateResolutionRegressionTests`
- Manual verification loop for transition changes:
  - `./scripts/dev/restart-app.sh --channel alpha`
  - Correlate daemon and view telemetry (`SessionStateManager.merge`, `ProjectsView ResolvedCardStates`, `ProjectCardView CardState`).

## Change Control

Any changes to polling intervals or refresh triggers should update this doc and
be justified against CPU/logging impact and UI responsiveness.
