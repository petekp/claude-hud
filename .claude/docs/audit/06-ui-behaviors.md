# Subsystem Audit: UI Session State Behaviors

**Files reviewed**
- `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift`
- `apps/swift/Sources/Capacitor/Models/ActiveProjectResolver.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/DockLayoutView.swift`

**Purpose**
Consume daemon project/session state and drive UI rendering + active project selection.

---

### [UI] Finding 1: Session state matching is string-based (no normalization)

**Severity:** Medium
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:112-140`, `apps/swift/Sources/Capacitor/Models/ActiveProjectResolver.swift:250-254`

**Problem:**
The UI matches daemon `project_path` to pinned projects using exact string equality and prefix matching. This fails when the daemon emits a canonicalized path (case, symlink, or realpath) that differs from the pinned path string. The result is missing session state in UI and failure to select the active project even though a session exists.

**Evidence:**
- `SessionStateManager.mergeDaemonProjectStates` filters `states` using `projectLookup[projectPath]` (exact key match). (`SessionStateManager.swift:112-140`)
- `ActiveProjectResolver.projectContaining` uses `path == project.path` or `hasPrefix(project.path + "/")` with no normalization. (`ActiveProjectResolver.swift:250-254`)

**Recommendation:**
Normalize both daemon paths and pinned project paths before matching (e.g., use a shared normalization helper or call into `hud_core` path matching utilities). At minimum, apply case normalization and symlink resolution to avoid false negatives.

---

### [UI] Finding 2: Active project selection uses a fractional-only ISO8601 parser

**Severity:** Medium
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/ActiveProjectResolver.swift:122-145`

**Problem:**
`ActiveProjectResolver` parses `updatedAt/stateChangedAt` using an `ISO8601DateFormatter` configured with `.withFractionalSeconds` only. If the daemon returns timestamps without fractional seconds (valid RFC3339), parsing fails and falls back to `Date.distantPast`, which can cause the resolver to pick the wrong active project.

**Evidence:**
- Formatter is created with `.withInternetDateTime` + `.withFractionalSeconds` only. (`ActiveProjectResolver.swift:122-145`)
- When parsing fails, `Date.distantPast` is used as the timestamp for sorting. (`ActiveProjectResolver.swift:137-146`)

**Recommendation:**
Use the same tolerant parsing strategy as `DaemonClient.parseDaemonDate` (fractional + non-fractional + normalization) or inject a shared date parser into the resolver.

