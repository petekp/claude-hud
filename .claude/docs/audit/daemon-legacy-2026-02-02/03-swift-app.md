# Subsystem 03: Swift App State/Activation

## Findings

### [SWIFT] Finding 1: ShellHistoryStore reads deprecated `shell-history.jsonl` with no writer

**Severity:** Medium
**Type:** Dead code
**Location:** `apps/swift/Sources/Capacitor/Models/ShellHistoryStore.swift:30-66`, `apps/swift/Sources/Capacitor/Models/AppState.swift:87-199`

**Problem:**
`ShellHistoryStore` loads `~/.capacitor/shell-history.jsonl`, but the daemon/hud-hook no longer write this file. AppState wires the store and exposes accessors, yet no Views reference these methods, so the feature is effectively dead.

**Evidence:**
- The store only reads `~/.capacitor/shell-history.jsonl` (`ShellHistoryStore.swift:30-66`).
- AppState initializes and calls it (`AppState.swift:87-199`).
- No UI call sites for `recentlyVisitedProjects/lastVisited/visitCount` exist in `Views/`.

**Recommendation:**
Remove `ShellHistoryStore` and its AppState accessors, or reimplement the feature using daemon event history if still desired.

---

### [SWIFT] Finding 2: Shell integration status still checks deprecated `shell-cwd.json`

**Severity:** Medium
**Type:** Stale logic
**Location:** `apps/swift/Sources/Capacitor/Models/ShellSetupInstructions.swift:164-176`, `apps/swift/Sources/Capacitor/Models/SetupRequirements.swift:115-124`

**Problem:**
Setup UI treats the existence of `~/.capacitor/shell-cwd.json` as proof of shell integration. That file is deprecated in daemon-only mode, so this check can misreport the setup status.

**Evidence:**
- `ShellIntegrationChecker.stateFileExists()` checks for `shell-cwd.json` (`ShellSetupInstructions.swift:173-176`).
- `updateShellStatus()` uses it as a completion signal (`SetupRequirements.swift:120-124`).

**Recommendation:**
Remove the file check. Base status on daemon shell state presence and/or shell snippet installation only.

---

### [SWIFT] Finding 3: Terminal activation comments still cite `shell-cwd.json`

**Severity:** Low
**Type:** Stale docs
**Location:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:104-118`

**Problem:**
Comments describe shell-cwd.json as the source of active shells, but the app now pulls shell state from the daemon. The data shape is compatible, but the file is deprecated.

**Evidence:**
Activation priority comments reference `shell-cwd.json` (`TerminalLauncher.swift:104-118`).

**Recommendation:**
Update comments to reference daemon shell state snapshots.

---

### [SWIFT] Finding 4: Startup cleanup logging still references legacy counters

**Severity:** Low
**Type:** Stale docs
**Location:** `apps/swift/Sources/Capacitor/Models/AppState.swift:135-139`

**Problem:**
AppState logs cleanup stats (`locksRemoved`, `legacyLocksRemoved`, `sessionsRemoved`) that are not populated in daemon-only cleanup, leading to misleading output.

**Evidence:**
AppState prints legacy fields from `CleanupStats` (`AppState.swift:135-139`).

**Recommendation:**
Log only the daemon-era counters (e.g., orphaned lock-holder processes) or update the stats struct to match daemon-only behavior.

