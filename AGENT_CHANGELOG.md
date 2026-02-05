# Agent Changelog

> This file helps coding agents understand project evolution, key decisions,
> and deprecated patterns. Updated: 2026-02-05

## Current State Summary

Capacitor is a native macOS SwiftUI app (Apple Silicon, macOS 14+) that acts as a sidecar dashboard for Claude Code. The architecture uses a Rust core (`hud-core`) with UniFFI bindings to Swift plus a **Rust daemon (`capacitor-daemon`) that is the canonical source of truth** for session, shell, activity, and process-liveness state. Hooks emit events to the daemon over a Unix socket (`~/.capacitor/daemon.sock`), and Swift reads daemon snapshots (shell state + project aggregation). File-based JSON fallbacks (`sessions.json`, `shell-cwd.json`, `file-activity.json`) and lock compatibility have been removed in daemon-only mode. The app auto-starts the daemon via LaunchAgent and surfaces daemon status in debug builds only. Terminal activation uses a Rust-only decision path (Swift executes macOS APIs). **v0.1.27** completed hook audit remediations (heartbeat gating, safe hook tests, activity migration) and activation matching parity across Rust/Swift.

> **Historical note:** Timeline entries below may reference pre-daemon artifacts (locks, `sessions.json`, `shell-cwd.json`). Treat them as historical context only; they are not current behavior.

## Stale Information Detected

| Location | States | Reality | Since |
|----------|--------|---------|-------|
| docs/architecture-decisions/003-sidecar-architecture-pattern.md | “Hooks write `~/.capacitor/sessions.json` and HUD reads files.” | Daemon is the single writer; hooks/app are IPC clients; JSON is legacy/fallback only. | 2026-01 |

## Timeline

### 2026-02-04 — Worktrees + Workspace Mapping (Foundation Completed)

**What changed:**
- Started branch `codex/worktrees-model` to explore multi-workspace support across git worktrees.
- Drafted schema and daemon mapping algorithm for `project_id` + `workspace_id` (see notes in thread).
- Added Swift-side worktree-aware project matching (git common dir detection) plus a failing/now-targeted test.
- Added daemon-side project identity resolution (canonicalizes worktree paths, emits `project_id` in sessions/project states).
- Added daemon `workspace_id` derivation and a worktree stability test; ipc_smoke now skips in environments where unix sockets cannot be bound.
- Swift client now computes workspace identities (MD5 over project_id + relative path) and prefers workspace_id matching when merging daemon project states.
- Session snapshots now include `workspace_id` alongside `project_id`.
- Fixed daemon reducer to preserve the last package-level project_path on events without file_path (e.g., PreCompact) to avoid sticky Working/Compacting on monorepos.
- Aligned daemon and Swift workspace ID hashing on macOS by lowercasing the daemon hash source before MD5 (matches Swift path normalization behavior).
- Hardened daemon `.git` file handling: only treat `.git` files as worktrees when `commondir` exists; submodule-style gitdir files no longer get miscanonicalized as worktrees.
- Added shell fallback matching by repository identity in Swift active-project resolution, so shell CWDs in sibling worktrees still map to the pinned workspace.
- Added deterministic tests for the above cases in daemon and Swift test suites.

**Why:**
- Users want parallel tasks within a project without caring about worktrees or monorepo layout.

**Agent impact:**
- Treat `project_id` + `workspace_id` as the canonical identity path for worktree-safe attribution.
- Do not rely on path-prefix matching as the only resolver path; use git common-dir identity when worktree paths diverge.
- Keep macOS workspace hashing behavior aligned across Rust and Swift, or cross-process workspace matching will break.

**Remaining feature work:**
- Worktree lifecycle UX is still pending (create/list/remove worktrees from Capacitor UI and related safety guardrails).

### 2026-02-05 — Session Staleness + Ghostty Activation (In Progress)

**What changed:**
- Daemon now downgrades `Working`/`Waiting`/`Compacting` to `Ready` after 8s of inactivity (prevents stuck Working states).
- Added tests covering the downgrade and recent-activity behavior.
- Ghostty activation now prefers activating the app when a tmux client is attached (avoid spawning new windows on project click).
- Daemon offline banner moved to debug-only diagnostics (no user-facing daemon status).
- Debug daemon status now avoids transient “offline” states: 20s startup grace + 2 consecutive failures required before showing unavailable.
- Fixed Swift `GitRepositoryInfo.findRepoRoot` to stop at filesystem root (`/`) and avoid `URL.deletingLastPathComponent()` producing `"/.."` for `"/"` (prevented infinite loops when resolving non-repo paths). Added `GitRepositoryInfoTests`.
- Swift session matching now maps daemon activity in a repo to pinned workspaces within that repo (git common dir when available), so monorepo subdirectory pins stay accurate even if the Claude session runs from another worktree or sibling directory.
- App now attempts silent daemon recovery (re-kickstarts) on IPC connection failures, with a cooldown to avoid restart thrash.
- Fixed daemon LaunchAgent management to be idempotent (no repeated `bootout` / forced restarts during health checks), which was causing the daemon to be killed every few seconds and leaving the UI stuck in `Idle`.

**Why:**
- Users reported projects stuck in Working after no activity; Ghostty clicks occasionally spawned new windows.

**Next steps:**
- Manual verification: idle project flips to Ready within ~8s after activity stops.
- Validate Ghostty click path in tmux (no new window; just focus + switch).

### 2026-02 — Agent Knowledge Optimization + Daemon-Only Doc Sweep

**What changed:**
- Added a retrieval-optimized knowledge manifest: `.claude/KNOWLEDGE.md`
- Compiled dense agent references under `.claude/compiled/` with task markers
- Performed a daemon-only documentation sweep to reduce fallback ambiguity

**Why:**
- Agents need fast, high-signal entry points without reading long docs.
- The daemon-only migration requires consistent documentation to avoid backsliding into file fallbacks.

**Agent impact:**
- Read `.claude/KNOWLEDGE.md` first to decide what to load for a task.
- Prefer `.claude/compiled/*` for quick facts; use source docs only for deep dives.

---

### 2026-02 — Phase 7 Robustness + Daemon-Only State Authority (Completed)

**What changed:**
1. **Daemon TTL + aggregation policy solidified**
   - Working/Waiting staleness uses `updated_at` (8s → Ready)
   - TTL pruning enforced in daemon snapshots (Active 20m, Ready 30m, Idle 10m)
   - Project-level aggregation via `GetProjectStates` is canonical

2. **Client-side heuristics removed**
   - `hud-core` no longer applies local staleness or activity fallbacks
   - Session detection uses daemon snapshots only

3. **UI refresh contract documented**
   - Standardized polling cadence in `.claude/docs/ui-refresh-contract.md`

4. **Legacy naming cleanup**
   - `is_locked` renamed to `has_session` in daemon state + client models

**Why:**
- Ensure daemon is the single source of truth with deterministic TTL/aggregation.
- Prevent divergent client interpretations from reintroducing state inconsistencies.

**Agent impact:**
- Treat daemon project aggregation as canonical (no client-side staleness logic).
- Use `has_session` for “non-idle session exists” instead of any lock semantics.
- Consult `.claude/docs/ui-refresh-contract.md` before changing polling cadence.

---

### 2026-02 — Daemon-Only Cleanup + Schema Naming (Completed)

**What changed:**
- Removed remaining client-side heuristics and activity fallbacks in `hud-core`.
- Renamed `is_locked` → `has_session` across daemon, Rust core, and Swift client models.
- Audit trail for legacy/dead code removals is kept in git history; `.claude/docs/audit/` was removed during cleanup.

**Why:**
- Eliminate legacy lock semantics from the daemon-first architecture.
- Keep client state purely declarative and daemon-derived.

**Agent impact:**
- Use `has_session` for “non-idle session exists” checks.
- Do not reintroduce local staleness or file-activity heuristics.

**Commits:** `e6cd8ef`, `1d135dc`

---

### 2026-02 — Daemon-First State Tracking + Lock Deprecation (In Progress)

**What changed:**

1. **Daemon protocol + persistence foundations**
   - New `core/daemon` + `core/daemon-protocol` crates
   - SQLite persistence + event replay for shell state
   - IPC endpoints for shell state + process liveness + sessions/project states

2. **Daemon-first readers + cleanup**
   - Swift reads daemon snapshots (shell + sessions) with JSON fallbacks removed
   - `hud-core` cleanup and lock/liveness decisions routed through daemon
   - Startup backoff and health probes to avoid crash loops

3. **Hooks → daemon only**
   - Hooks emit events over IPC and **return errors when daemon is unavailable** (no file writes)
   - Shell CWD tracking moved to daemon-first route

4. **Lock deprecation**
   - Lock writes suppressed when daemon is healthy; lock-holder checks use daemon liveness
   - Lock cleanup gated by daemon health/read-only modes

5. **App auto-start + daemon health**
   - LaunchAgent installation + kickstart from app startup
   - Debug-only daemon health UI + debounce

**Why:**
- Eliminate multi-writer JSON races and PID-reuse edge cases by centralizing state in a single-writer daemon.
- Provide reliable, transactionally persisted state with replay and liveness checks.

**Agent impact:**
- Treat the daemon IPC contract as authoritative for session/shell state.
- Avoid reintroducing file-based fallbacks unless explicitly required (migration goal is daemon-only).
- Use `get_process_liveness` and daemon-derived `state_changed_at` for staleness decisions.

**Commits (selection):** `23ec83d`, `9241b46`, `a155796`, `77ed85e`, `803fd3c`, `34c2aaa`, `8d30f5a`

---

### 2026-01 — Daemon Migration Plan + ADR

**What changed:**
- Added daemon migration ADR and an exhaustive, phase-based plan
- Documented IPC contract (`docs/daemon-ipc.md`) as source of truth

**Why:**
- Establish a single-writer architecture and a clear migration sequence for lock deprecation and daemon-only behavior.

**Agent impact:**
- Consult `.claude/docs/architecture-deep-dive.md` and `.claude/docs/ui-refresh-contract.md` for invariants and current daemon-only behavior.

**Commits:** `6809018`

---

### 2026-01-30 — v0.1.27: Hooks Audit Remediation + Activation Matching Parity

**What changed:**

1. **Hook test safety + heartbeat gating** (commit `9a987d0`)
- `run_hook_test()` writes an isolated legacy sessions-format file instead of touching live `sessions.json` (historical; daemon-only no longer depends on this)
- Health checks verified `sessions.json` writability when present (historical)
   - Heartbeat updates only after parsing a valid hook event (no false positives)

2. **Activity migration consolidation** (`hud-hook`)
   - Writes native `activity[]` entries with `project_path`
   - Migrates legacy `files[]` arrays on write; resolves relative paths against session CWD
   - Added coverage for legacy absolute-path entries and duplicate suppression

3. **Lock robustness + test resilience**
   - `create_session_lock()` refreshes stale locks on PID reuse by validating `proc_started`
   - Lock tests skip cleanly when process start time is unavailable (CI-friendly)

4. **Activation matching parity (macOS)**
   - Path matching is now case-insensitive in Rust resolver and Swift tmux selection
   - New normalization helper: `normalize_path_for_matching` (no filesystem access)

5. **Version detection improvements**
   - App auto-detects version from multiple sources; CI fallback documented

**Why:**
- Finalize hooks functionality audit findings without risking live state corruption
- Ensure shell/tmux matching behaves consistently across Rust + Swift on macOS
- Avoid flaky test failures in environments with limited process metadata access

**Agent impact:**
- Use `normalize_path_for_matching` for activation comparisons; keep action paths unmodified
- Historical: hook tests avoided writing live `sessions.json`; daemon-only builds no longer rely on that file
- Audit docs from this period were removed during cleanup; use git history if you need the original audit context.

**Commits:** `9a987d0`, `7271c5a`, `9e98dde`, `366930b`

---

### 2026-01-29 — v0.1.26: Simplified Window Behavior and About Panel

**What changed:**

1. **Removed custom WindowResizeHandles** (commit `377586e`)
   - Deleted `WindowResizeHandles.swift` (~237 lines)
   - Window now uses default `isMovableByWindowBackground = true` behavior
   - Custom resize handles caused conflicts with window dragging (dual drag/resize on edges, cursor flickering)
   - Default macOS behavior is simpler and more reliable

2. **Fixed header dead zones** (`HeaderView.swift`)
   - Changed BackButton from `opacity(0)` + `allowsHitTesting(false)` to conditional rendering (`if !isOnListView`)
   - Invisible views still block `NSWindow.isMovableByWindowBackground` even with hit testing disabled
   - Removed `onTapGesture(count: 2)` that blocked window dragging

3. **Custom About panel** (`App.swift`)
   - Added `showAboutPanel()` method to AppDelegate with tinted Capacitor logomark (#67FC94)
   - Uses `ResourceBundle.url(forResource:)` for SPM resource loading (not `NSImage(named:)`)
   - Added `NSImage.tinted(with:size:)` extension for compositing
   - Icon rendered at 48×48 pixels

4. **New gotchas documented** (`.claude/docs/gotchas.md`)
   - NSImage tinting compositing order: draw image with `.copy` first, then fill color with `.sourceAtop`
   - SwiftUI hit testing: use conditional rendering, not `opacity(0) + allowsHitTesting(false)`
   - SwiftUI gestures block NSView events: `onTapGesture(count: 2)` intercepts `mouseDown`

**Why:**
- Custom resize handles were over-engineered; default macOS behavior works well for floating windows
- SwiftUI's hit testing model has subtle behaviors that can break window dragging
- Users expected a custom About panel with the app's branding

**Agent impact:**
- **Do not re-add custom window resize handles** — use `isMovableByWindowBackground = true`
- For hiding views that shouldn't block events, use conditional `if` statements, not `opacity(0)`
- Avoid `onTapGesture` on draggable areas; use `NSViewRepresentable` if double-click needed
- For resource loading in SPM builds, use `ResourceBundle.url(forResource:withExtension:)`
- NSImage tinting: compositing order matters — draw first, then fill

**Files changed:**
- `Views/Components/WindowResizeHandles.swift` (DELETED)
- `Views/Header/HeaderView.swift` (conditional rendering, removed double-click gesture)
- `ContentView.swift` (removed resize handles overlay)
- `App.swift` (About panel, NSImage tinting extension)
- `.claude/docs/gotchas.md` (3 new sections)

**Commits:** `377586e` (resize handles removal), others pending commit

---

### 2026-01-29 — UI Polish: Progressive Blur (kept) and Header/Footer Padding

**What changed:**

1. **ProgressiveBlurView component** (`Views/Components/ProgressiveBlurView.swift`)
   - Gradient-masked NSVisualEffectView for smooth edge transitions
   - Supports four directions: `.up` (footer), `.down` (header), `.left`, `.right`
   - Applied to header (fades down) and footer (fades up) with 30pt zones
   - Uses standard vibrancy without additional glass overlays (kept simple after testing alternatives)

2. **Header/footer padding reduction** (~25%)
   - Header: top padding 12→9 (floating) / 8→6 (docked), bottom 8→6
   - Footer: vertical padding 8→6, bottom extra 8→6
   - Tighter, more compact appearance

**Why:**
- Progressive blur: Smooth visual transition where content meets navigation bars (masking scrolling content)
- Padding reduction: Overall tighter/denser UI feel

**Agent impact:**
- `ProgressiveBlurView` is reusable—use `.progressiveBlur(edge:height:)` modifier on any view
- Header/footer heights are now more compact—keep this in mind for layout calculations

**Files changed:**
- `Views/Components/ProgressiveBlurView.swift` (new)
- `Views/Header/HeaderView.swift` (progressive blur + padding)
- `Views/Footer/FooterView.swift` (progressive blur + padding)

---

### 2026-01-28 — Post v0.1.25: Stale TTY and HOME Path Fixes

**What changed:**
Two additional terminal activation bugs fixed after v0.1.25 release:

1. **Stale tmux_client_tty fix** (`TerminalLauncher.swift`)
- Daemon shell snapshots store `tmux_client_tty` captured at hook time
   - TTY becomes stale when users reconnect to tmux (get new TTY device)
   - Fix: Query fresh client TTY via `tmux display-message -p '#{client_tty}'` at activation time
   - Telemetry shows: `Fresh TTY query: /dev/ttys000 (shell record had: /dev/ttys005)`

2. **HOME exclusion from parent matching** (`activation.rs`)
   - `paths_match()` allowed parent-directory matching for monorepo support
   - HOME (`/Users/pete`) is parent of everything—shell at HOME matched ALL projects
   - Symptom: Clicking "plink" project selected HOME shell → `ActivateByTty` instead of `SwitchTmuxSession`
   - Fix: New `paths_match_excluding_home()` function excludes HOME from parent matching
   - HOME can only match itself exactly; non-HOME parents still work for monorepos

**Why:**
- Stale TTY: Users reconnect to tmux sessions, get new TTY devices, but shell record has old TTY → TTY discovery fails
- HOME exclusion: HOME is too broad to be useful as a parent; a shell at HOME shouldn't match every project

**Agent impact:**
- New gotcha: "Terminal Activation: Query Fresh Client TTY" in `.claude/docs/gotchas.md`
- New gotcha: "Shell Selection: HOME Excluded from Parent Matching" in `.claude/docs/gotchas.md`
- `TmuxContextFfi` now includes `home_dir: String` field for Rust decision logic
- OSLog limitation documented: Swift `Logger` doesn't capture output for unsigned debug builds; use stderr telemetry for debugging

**Files changed:**
- `TerminalLauncher.swift` — `getCurrentTmuxClientTty()`, `telemetry()` helper, fresh TTY query in `activateHostThenSwitchTmux`
- `activation.rs` — `paths_match_excluding_home()`, `TmuxContextFfi.home_dir`, 4 new unit tests
- `.claude/docs/gotchas.md` — Three new sections (OSLog, Fresh TTY, HOME exclusion)
- `.claude/docs/debugging-guide.md` — OSLog limitation section

**Commits:** `31edfe2` (stale TTY), pending (HOME exclusion)

---

### 2026-01-28 — v0.1.25: Terminal Activation Hardening Validated

**What changed:**
Released v0.1.25 with two critical bug fixes for terminal activation, then validated all scenarios via manual test matrix.

**Bug fixes:**
1. **Shell selection: Tmux priority when client attached** (`activation.rs:find_shell_at_path`)
   - When multiple shells exist at the same path (e.g., 1 tmux, 2 direct shells), tmux shells are now preferred when a client is attached
   - Fixes: Clicking project would use recent non-tmux shell → `ActivateByTty` instead of `ActivateHostThenSwitchTmux` → session switch failed

2. **Client detection: ANY client, not session-specific** (`TerminalLauncher.swift:hasTmuxClientAttached`)
   - Changed from checking if client is attached to *target* session to checking if *any* tmux client exists
   - Fixes: Viewing session A, click project B → old code reported "no client" → spawned unnecessary new windows

**Test matrix validated:**
- A1-A4: Single Ghostty window with tmux ✅
- B1-B3: Multiple Ghostty windows ✅
- C1: No client, sessions exist → spawns window ✅
- D1: Client attached → switches session, no new window ✅
- D2-D3: Detach/no clients → spawns window to attach ✅
- E1, E3: Multiple shells same path → prefers tmux ✅

**Why:**
- Shell selection bug caused incorrect terminal behavior when users had both tmux and direct shells at same project path
- Client detection bug caused unnecessary window spawning because "no client on THIS session" ≠ "no client anywhere"
- Semantic clarification: "has attached client" answers "can we use `tmux switch-client`?" — if ANY client exists, we can switch it

**Agent impact:**
- Gotchas documented: "Shell Selection: Tmux Priority When Client Attached" and "Tmux Context: Has Client Means ANY Client"
- Test matrix at `.claude/docs/terminal-activation-test-matrix.md` — run this after terminal activation changes
- Key invariant: **Never spawn new windows when any tmux client is attached**

**Files changed:** `activation.rs`, `TerminalLauncher.swift`

**Commits:** `fc9071e`, `fb76352`

**Release:** v0.1.25 (GitHub, notarized DMG + ZIP)

---

### 2026-01-27 — Terminal Activation: Phase 3 Polish

**What changed:**
Nice-to-have improvements completing the terminal activation hardening work.

1. **Proper timestamp parsing with chrono**
   - Added `parse_timestamp()` to parse RFC3339 strings into `DateTime<Utc>`
   - Added `is_timestamp_older_or_equal()` to handle comparison with malformed timestamps
   - Unparseable timestamps lose to parseable ones; both unparseable treats as dominated

2. **Ghostty cache size limit**
   - `cleanupExpiredGhosttyCache()` now caps at 100 entries
   - When exceeded, trims to 50 most recent entries
   - Prevents unbounded memory growth in edge cases

3. **Export `paths_match` via UniFFI**
   - Added `#[uniffi::export]` to `paths_match()` function
   - Swift can now call `pathsMatch(a:b:)` directly
   - Enables consistent path matching logic across Rust/Swift

**Why:**
- RFC3339 strings are lexicographically sortable, but chrono adds validation and timezone handling
- Ghostty cache could theoretically grow unbounded without size limit
- Swift had to duplicate path matching logic; now it can call Rust directly

**Agent impact:**
- Timestamps are now properly parsed; malformed ones don't crash, just lose comparisons
- Ghostty session cache is self-limiting; no manual cleanup needed
- Use `pathsMatch(a:b:)` in Swift instead of duplicating path matching logic

**Files changed:** `activation.rs`, `TerminalLauncher.swift`, UniFFI bindings

**Commit:** `fb35347`

**Plan doc:** `.claude/plans/DONE-terminal-activation-fixes.md` (ALL PHASES COMPLETE)

---

### 2026-01-27 — Terminal Activation: Security & Reliability Hardening (Phase 1-2)

**What changed:**
Comprehensive security and reliability fixes to terminal activation system, based on 5-model code review synthesis.

**Phase 1 (Security & Critical):**
1. **Shell injection prevention** — Added `shellEscape()` and `bashDoubleQuoteEscape()` utilities. All tmux session names now properly escaped before interpolation into shell commands.
2. **Tmux switch-client exit codes** — Now checks exit code and returns `false` on failure, enabling fallback mechanisms.
3. **IDE CLI error handling** — `activateIDEWindowInternal()` now waits for process and checks `terminationStatus`.
4. **Multi-client tmux hook fix** — Changed from `list-clients` (arbitrary order) to `display-message -p "#S\t#{client_tty}"` (current client's TTY).

**Phase 2 (Reliability):**
1. **Tmux client re-verification** — Re-checks `hasTmuxClientAttached()` before executing switch.
2. **AppleScript error checking** — Added `runAppleScriptChecked()` that captures stderr and returns success/failure.
3. **Subdirectory matching** — `findTmuxSessionForPath()` now matches subdirectories (aligns with Rust `paths_match`).
4. **`is_live` flag** — Added to `ShellEntryFfi` so Rust prefers live shells over dead ones.
5. **TTY-first Ghostty detection** — Try TTY discovery before Ghostty-specific handling to prevent activating wrong terminal.

**Code refinements:**
- Used `is_some_and()` instead of `map_or(false, ...)` (idiomatic Rust 1.70+)
- Combined two tmux subprocess calls into one (`display-message -p "#S\t#{client_tty}"`)
- Removed dead code in `paths_match` (`rest.is_empty()` was unreachable)

**Why:**
- Shell injection was a real security vulnerability
- Silent failures in tmux/IDE/AppleScript calls defeated fallback mechanisms
- Multi-client tmux activation was non-deterministic
- Dead shells being preferred over live ones caused incorrect activations
- Ghostty running in background caused wrong terminal to activate

**Agent impact:**
- Use `shellEscape()` for single-quoted shell arguments, `bashDoubleQuoteEscape()` for double-quoted strings
- All functions that can fail must return actual success/failure for fallback chains
- Tmux multi-client: always use `display-message` (not `list-clients`) to get current client's TTY
- Rust now receives `is_live` flag via FFI — live shells always beat dead shells at same path
- TTY-first strategy: try TTY discovery → Ghostty fallback → launch new terminal

**Files changed:** `TerminalLauncher.swift`, `cwd.rs`, `activation.rs`

**Commits:** `8f72606`, `83d3608`, `38a0dd9`

**Plan doc:** `.claude/plans/DONE-terminal-activation-fixes.md`

**Documentation updated:**
- `.claude/docs/gotchas.md` — Shell escaping utilities, TTY-first strategy, tmux multi-client detection
- `.claude/docs/debugging-guide.md` — Tmux multi-client, Ghostty/iTerm priority, shell injection testing, dead shells, UniFFI debugging
- `CLAUDE.md` — Added UniFFI binding regeneration command

---

### 2026-01-27 — Terminal Activation: Rust-Only Path Migration

**What changed:**
Removed ~277 lines of legacy Swift decision logic from `TerminalLauncher.swift`. Terminal activation now uses a single path: Rust decides, Swift executes.

**Before:**
```
launchTerminalAsync()
├── if useRustResolver → launchTerminalWithRustResolver()
│   → Rust decision → Swift execution
└── else → launchTerminalLegacy()
    → Swift decision → Swift execution
```

**After:**
```
launchTerminalAsync()
└── launchTerminalWithRustResolver()
    → Rust decision → Swift execution
```

**Removed components:**
- Feature flag: `useRustResolver` property
- Legacy types: `ShellMatch`, `ActivationContext`
- Legacy methods: `launchTerminalLegacy`, `switchToTmuxSessionAndActivate`, `findExistingShell`, `partitionByTmux`, `findMatchingShell`, `isTmuxShell`
- Strategy system: `activateExistingTerminal`, `executeStrategy`, `activateByTTY`, `activateByApp`, `activateKittyRemote`, `activateIDEWindow`, `switchTmuxSession`, `activateHostFirst`, `launchNewTerminalForContext`, `activatePriorityFallback`

**Preserved (execution layer):**
- `executeActivationAction()` — routes Rust decisions to macOS APIs
- `activateByTtyAction()`, `activateIdeWindowAction()` — action executors
- All AppleScript helpers, TTY discovery, Ghostty window detection
- `launchTerminalWithTmuxSession()`, `findTmuxSessionForPath()`, `hasTmuxClientAttached()`

**Why:**
- Rust activation resolver was validated via feature flag testing
- 25+ Rust unit tests cover all scenarios
- Single code path is easier to maintain and reason about
- Decision logic in Rust is testable without macOS mocking

**Agent impact:**
- Terminal activation decision logic lives in `core/hud-core/src/activation.rs`
- Execution logic stays in Swift (`TerminalLauncher.executeActivationAction()`)
- Principle: **Rust decides, Swift executes** (macOS APIs require Swift)
- Don't add decision logic to Swift; add new `ActivationAction` variants in Rust instead

**Documentation updated:**
- `.claude/docs/gotchas.md` — Replaced obsolete "Activation Strategy Return Values" with "Rust Activation Resolver Is Sole Path"
- `.claude/docs/architecture-overview.md` — Added Terminal Activation section
- `.claude/plans/DONE-terminal-activation-api-contract.md` — Marked complete

**Files changed:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` (1092→815 lines)

---

### 2026-01-27 — Activity Store Hook Format Detection Fix

**What changed:**
Fixed critical bug in `ActivityStore::load()` where hook format data was silently discarded.

**Root cause:** When loading `file-activity.json` (hook format with `"files"` array), the code incorrectly parsed it as native format (with `"activity"` array) due to `serde(default)` making the activity field empty. The format detection logic treated `activity.is_empty()` as proof of native format.

**Why this matters:** The activity-based fallback enables correct project status when:
- Claude runs from subdirectory (e.g., `apps/swift/`)
- Project is pinned at root (e.g., `/project`)
- Exact-match lock resolution fails (by design)

Without this fix, projects showed "Idle" even when actively working because file activity data was lost.

**Fix:** Added explicit hook format marker detection—check for `"files"` key presence in raw JSON before deciding parsing strategy.

**Agent impact:**
- Hook format detection now checks raw JSON for `"files"` arrays, not just struct deserialization success
- The `serde(default)` behavior can mask format differences—always validate against raw JSON when format matters
- Activity fallback is a secondary signal; lock presence is still authoritative

**Files changed:** `core/hud-core/src/activity.rs`

**Test added:** `loads_hook_format_with_boundary_detection`

**Gotcha added:** `.claude/docs/gotchas.md` — Hook Format Detection section

---

### 2026-01-27 — Terminal Launcher Priority Fix

**What changed:**
Fixed terminal activation to check the daemon shell snapshot BEFORE tmux sessions.

**Root cause:** `launchTerminalAsync()` checked tmux first (lines 90-96), returning early before checking the daemon shell snapshot. If user had a non-tmux terminal window open AND a tmux session existed at the same path, clicking the project would open a NEW window in tmux instead of focusing the existing terminal.

**Fix:** Inverted priority order:
1. Check daemon shell snapshot first (active shells with verified-live PIDs)
2. Then check tmux sessions
3. Finally launch new terminal

**Why this order matters:**
- Shell-cwd.json entries are verified-live PIDs from recent shell hook activity
- Tmux sessions may exist but not be actively used
- User intent: focus what they're currently using, not what they used before

**Agent impact:**
- Terminal activation priority: daemon shell snapshot → tmux → new terminal
- Comments in `TerminalLauncher.swift` now document this priority chain and why
- When implementing activation features, prioritize "currently active" signals over "exists" signals

**Files changed:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

---

### 2026-01-27 — Test Hooks Button (Bulletproof Hooks Phase 4)

**What changed:**
1. Added `HookTestResult` struct to Rust types with UniFFI export
2. Added `run_hook_test()` method to HudEngine (FFI-exported)
3. Added "Test Hooks" button to SetupStatusCard UI
4. Button verifies hooks via heartbeat + state file I/O verification

**Test approach:**
- Heartbeat check: Is the heartbeat file recent (< 60s)?
- Historical: state file I/O checks against `sessions.json` (deprecated in daemon-only mode)

**Why:** Gives users confidence that the hook system is working. No subprocess spawn needed—tests what actually matters (file I/O, not binary execution).

**Agent impact:**
- `run_hook_test()` in engine.rs returns `HookTestResult` (success, heartbeat_ok, state_file_ok, message)
- SetupStatusCard now has callback pattern: `onTest: () -> HookTestResult`
- Test result auto-clears after 5 seconds
- Use PID + timestamp for unique test IDs (no rand crate needed)

**Files changed:** `types.rs`, `engine.rs`, `SetupStatusCard.swift`, `AppState.swift`, `ProjectsView.swift`

**Commit:** `5c58b17`

**Plan doc:** `.claude/plans/ACTIVE-bulletproof-hooks.md` (Phase 4 complete)

---

### 2026-01-27 — CLAUDE.md Optimization

**What changed:**
1. Reduced CLAUDE.md from 107 lines to 95 lines
2. Moved 16+ detailed gotchas to `.claude/docs/gotchas.md`
3. Kept only 4 most common gotchas in CLAUDE.md
4. Added gotchas.md to documentation table

**Why:** Following claude-md-author principles—keep CLAUDE.md lean with high-frequency essentials, use `.claude/docs/` for deeper reference material.

**Agent impact:**
- Common gotchas (cargo fmt, dylib copy, hook symlink, UniFFI Task) remain in CLAUDE.md
- Detailed gotchas (session locks, state resolution, testing hooks, etc.) moved to `.claude/docs/gotchas.md`
- Progressive disclosure: Claude/developers get detailed reference when they need it

**Files changed:** `CLAUDE.md`, `.claude/docs/gotchas.md` (new)

---

### 2026-01-27 — Dead Code Cleanup: Swift Terminal System

**What changed:**

1. **Fixed `activateKittyRemote` fallback chain** — Now returns actual `activateAppByName()` result instead of unconditional `true`. Enables fallback strategies when kitty isn't running.

2. **Simplified `launchNewTerminalForContext`** — Added `launchNewTerminal(forPath:name:)` overload. No longer reconstructs a fake 11-field `Project` object just to extract path and name.

3. **Updated `TerminalScripts.launch` signature** — Now accepts `projectPath` and `projectName` directly instead of a `Project` object.

4. **Made `normalize_path_simple` test-only** — Changed to `#[cfg(test)]` since only used in tests. Removed from public exports in `mod.rs`.

5. **Fixed UniFFI `Task` type shadowing** — Discovered and fixed pre-existing build failure where UniFFI-generated `Task` type shadows Swift's `_Concurrency.Task`. All async code now uses `_Concurrency.Task` explicitly.

**Why:**
- Strategy pattern methods must return actual success/failure for fallback chains to work correctly
- Creating fake objects to extract 2 fields is a code smell
- Test-only functions should be `#[cfg(test)]` not `pub`
- UniFFI type shadowing causes confusing "cannot specialize non-generic type 'Task'" errors

**Agent impact:**
- When implementing strategy pattern methods, always return actual success status
- Use `_Concurrency.Task` (not `Task`) in Swift files that import UniFFI bindings
- Prefer direct parameters over object reconstruction when only a few fields are needed
- Use `#[cfg(test)]` for Rust functions only used in tests

**New CLAUDE.md gotchas:**
- UniFFI `Task` shadows Swift concurrency `Task`
- Activation strategy methods must return actual success

**Files changed:** `TerminalLauncher.swift`, `ShellStateStore.swift`, `path_utils.rs`, `state/mod.rs`

**Plan doc:** `.claude/plans/ACTIVE-dead-code-cleanup.md` (updated status)

---

### 2026-01-27 — hud-hook Audit Remediation

**What changed:** Fixed 2 of 3 findings from Session 12 (hud-hook system audit):

1. **Lock dir read errors now use fail-safe sentinel** — `count_other_session_locks()` returns `usize::MAX` (not 0) when `read_dir` fails for non-ENOENT errors. Callers treat any non-zero count as "preserve session record." This prevents transient FS errors from tombstoning active sessions.

2. **Logging guard properly held, not forgotten** — `logging::init()` now returns `Option<WorkerGuard>` which is held in `main()` scope. The guard's `Drop` implementation flushes buffered logs. Previously `std::mem::forget()` prevented final log entries from being written.

**Finding skipped:** Activity format duplication between `hud-hook` and `hud-core` (Finding 1) was intentionally skipped as a design decision—the conversion overhead is acceptable.

**Why:**
- Lock dir errors could incorrectly tombstone active sessions during transient FS issues
- `std::mem::forget()` on `WorkerGuard` contradicts the Rust ownership model—`Drop` has important side effects (flushing)

**Agent impact:**
- Error handling in `count_other_session_locks()` demonstrates fail-safe sentinel pattern—return `usize::MAX` when uncertain
- When `Drop` has side effects, hold values in scope rather than `forget()`ing them
- New CLAUDE.md gotchas document both patterns

**Files changed (historical; lock.rs removed in daemon-only mode):** `core/hud-hook/src/logging.rs`, `core/hud-hook/src/main.rs`

**Tests added:** `test_count_other_session_locks_nonexistent_dir`, `test_count_other_session_locks_unreadable_dir`

**Audit doc:** Removed during cleanup; see git history if needed.

---

### 2026-01-27 — Side Effects Analysis Audit Complete

**What changed:** Completed comprehensive 11-session audit of all side-effect subsystems across Rust and Swift codebases.

**Scope:**
- **Phase 1 (State Detection Core):** Lock System, Lock Holder, Session Store, Cleanup, Tombstone
- **Phase 2 (Shell Integration):** Shell CWD Tracking, Shell State Store, Terminal Launcher
- **Phase 3 (Supporting Systems):** Activity Files, Hook Configuration, Project Resolution

**Why:** Systematic verification that code matches documentation, with focus on atomicity, race conditions, cleanup, error handling, and dead code detection.

**Key findings:**
1. **All 11 subsystems passed** — No critical bugs or design flaws found
2. **1 doc fix applied (historical)** — `lock.rs` exact-match-only documentation (commit `3d78b1b`)
3. **1 low-priority item** — Vestigial function name `find_matching_child_lock` (optional rename)
4. **All 6 CLAUDE.md gotchas verified accurate** — Session-based locks, exact-match-only, hud-hook symlink, async hooks, Swift timestamp decoder, focus override
5. **Shell vs Lock path matching is intentionally different:**
   - Locks: exact-match-only (Claude sessions are specific to launch directory)
   - Shell: child-path matching (shell in `/project/src` matches project `/project`)

**Agent impact:**
- Audit artifacts from this period were removed during cleanup; use git history if needed.
- Design decisions documented and validated—don't second-guess these patterns
- `ActiveProjectResolver` focus override mechanism is intentionally implicit (no clearManualOverride method)
- Active sessions (Working/Waiting/Compacting) always beat passive sessions (Ready) in priority

**Plan doc:** `.claude/plans/COMPLETE-side-effects-analysis.md`

---

### 2026-01-27 — Lock Holder Timeout Fix and Dead Code Removal

**What changed:**
1. Fixed critical bug: lock holder 24h timeout no longer releases locks when PID is still alive
2. Removed ~650 lines of dead code: `is_session_active()`, `find_by_cwd()`, redundant `normalize_path`
3. Updated stale v3→v4 documentation across state modules

**Why:**
- **Timeout bug**: Sessions running >24h would incorrectly have their locks released, causing state tracking to fail. The lock holder's safety timeout was unconditionally releasing locks instead of only when PID actually exited.
- **Dead code**: The codebase evolved from child→parent path inheritance (v3) to exact-match-only (v4), leaving orphaned functions and tests that no longer applied.
- **Stale docs**: Module docstrings still described v3 behavior (path inheritance, read-only store, hash-based locks).

**Agent impact:**
- Lock holder now tracks exit reason: only releases lock if `pid_exited == true`
- Functions removed: `is_session_active()`, `is_session_active_with_storage()`, `find_by_cwd()`, `boundaries::normalize_path()`
- Documentation in `store.rs`, `mod.rs`, `lock.rs`, `resolver.rs` now accurately describes v4 behavior (historical; lock/resolver removed in daemon-only mode)
- Path matching is exact-match-only—don't implement child→parent inheritance

**Files changed (historical; lock_holder/lock/resolver removed in daemon-only mode):** `sessions.rs`, `store.rs`, `boundaries.rs`, `mod.rs`, `claude.rs`

**Commit:** `3d78b1b`

---

### 2026-01-26 — fs_err and tracing for Improved Debugging

**What changed:**
1. Replaced `std::fs` with `fs_err` in all production code (20 files)
2. Added `tracing` infrastructure with daily log rotation (7 days retention)
3. Migrated custom `log()` functions to structured `tracing` macros
4. Replaced `eprintln!` with `tracing::warn!/error!` throughout
5. Consolidated duplicate `is_pid_alive` into single export from `hud_core::state`
6. Added graceful stderr fallback if file appender creation fails

**Why:** Debugging hooks was difficult—errors like "Permission denied" lacked file path context. Custom `log()` functions were scattered and inconsistent. The `fs_err` crate enriches error messages with the file path, and `tracing` provides structured, configurable logging with automatic rotation.

**Agent impact:**
- Logs written to `~/.capacitor/hud-hook-debug.{date}.log` (daily rotation, 7 days)
- Log level configurable via `RUST_LOG` env var (default: `hud_hook=debug,hud_core=warn`)
- Use `fs_err as fs` import pattern in all new Rust files (see existing files for examples)
- `is_pid_alive` is now exported from `hud_core::state` — don't duplicate it
- Use structured fields with tracing: `tracing::debug!(session = %id, "message")`

**Files changed:** 23 files across `hud-core` and `hud-hook`, new `logging.rs` module

**Commit:** `f1ce260`

---

### 2026-01-26 — Rust Best Practices Audit

**What changed:**
1. Added `#[must_use]` to 18 boolean query functions to prevent ignored return values
2. Fixed `needless_collect` lint (use `count()` directly instead of collecting to Vec)
3. Removed unused `Instant` from thread-local sysinfo cache
4. Extracted helper functions in `handle.rs` for clearer event processing
5. Fixed ignored return value in `lock_holder.rs` (historical; lock-holder removed in daemon-only mode)

**Why:** Code review identified patterns that could lead to bugs (ignored boolean returns) and unnecessary allocations (collecting iterators just to count).

**Agent impact:**
- Functions like `is_session_running()`, `has_any_active_lock()` are marked `#[must_use]`—compiler warns if return value is ignored
- When counting matches, use `.filter().count()` not `.filter().collect::<Vec<_>>().len()`
- Helper functions `is_active_state()`, `extract_file_activity()`, `tool_use_action()` in `handle.rs` encapsulate event processing logic

**Commit:** `35dfc56`

---

### 2026-01-26 — Security Audit: Unsafe Code and Error Recovery

**What changed:**
1. Added SAFETY comments to all `unsafe` blocks documenting invariants
2. `RwLock` poisoning in session cache now recovers gracefully instead of panicking
3. Added `#![allow(clippy::unwrap_used)]` to `patterns.rs` for static regex (documented)
4. Documented intentional regex capture group expects in `ideas.rs`

**Why:** Unsafe code needs clear documentation of safety invariants. Lock poisoning shouldn't crash the app—it should recover and continue.

**Agent impact:**
- All `unsafe` blocks must have `// SAFETY:` comments explaining why the operation is safe
- Use `unwrap_or_else(|_| cache.write().unwrap_or_else(...))` pattern for RwLock recovery
- Static regex compilation can use `expect()` with `#![allow(clippy::unwrap_used)]` at module level
- See `cwd.rs`, `handle.rs` for canonical `// SAFETY:` comment format (lock_holder.rs removed in daemon-only mode)

**Commit:** `a28eee5`

---

### 2026-01-26 — Self-Healing Lock Management

**What changed:** Added multi-layered cleanup to prevent accumulation of stale lock artifacts:
1. `cleanup_orphaned_lock_holders()` kills lock-holder processes whose monitored PID is dead (historical)
2. `cleanup_legacy_locks()` removes MD5-hash format locks from older versions
3. Lock-holders have 24-hour safety timeout (`MAX_LIFETIME_SECS`)
4. Locks now include `lock_version` field for debugging

**Why:** Users accumulate stale artifacts when Claude crashes without SessionEnd, terminal force-quits, or app updates. The system relied on "happy path" cleanup—processes exiting gracefully—but real-world usage is messier.

**Agent impact:**
- `CleanupStats` now has `orphaned_processes_killed` and `legacy_locks_removed` fields
- Lock metadata includes `lock_version` (currently `CARGO_PKG_VERSION`)
- `run_startup_cleanup()` runs process cleanup **first** (before file cleanup) to prevent races
- Lock-holder processes self-terminate after 24 hours regardless of PID monitoring state

**Files changed (historical; lock-holder removed in daemon-only mode):** `cleanup.rs` (process/legacy cleanup), `types.rs` (LockInfo)

---

### 2026-01-26 — Session-Based Locks (v4) and Exact-Match-Only Resolution

**What changed:**
1. Locks keyed by `{session_id}-{pid}` instead of path hash (MD5)
2. Path matching uses exact comparison only—no child→parent inheritance
3. Sticky focus: manual override persists until user clicks different project
4. Path normalization handles macOS case-insensitivity and symlinks

**Why:**
- **Concurrent sessions**: Old path-hash locks created 1:1 path↔lock, so two sessions in same directory competed
- **Monorepo independence**: Child paths shouldn't inherit parent's state; packages track independently
- **Sticky focus**: Prevents jarring auto-switching between multiple active sessions

**Agent impact:**
- Lock files: `~/.capacitor/sessions/{session_id}-{pid}.lock/` (v4) vs `{md5-hash}.lock/` (legacy)
- `find_all_locks_for_path()` returns multiple locks (concurrent sessions)
- `release_lock_by_session()` releases specific session's lock
- Resolver's stale Ready fallback removed—lock existence is authoritative
- Legacy MD5-hash locks are stale and should be deleted

**Deprecated:** Path-based locks (`{hash}.lock`), child→parent inheritance, stale Ready fallback.

**Commits:** `97ddc3a`, `3e63150`

**Plan doc:** `.claude/plans/DONE-session-based-locking.md`

---

### 2026-01-26 — Bulletproof Hook System

**What changed:** Hook binary management now uses symlinks instead of copies, with auto-repair on failure.

**Why:** Copying adhoc-signed Rust binaries triggered macOS Gatekeeper SIGKILL (exit 137). Symlinks work reliably.

**Agent impact:**
- `~/.local/bin/hud-hook` must be a **symlink** to `target/release/hud-hook`
- Never copy the binary—always symlink
- See `scripts/sync-hooks.sh` for the canonical approach

**Commits:** `ec63003`

---

### 2026-01-25 — Status Chips Replace Prose Summaries

**What changed:** Replaced three-tier prose summary system (`workingOn` → `lastKnownSummary` → `latestSummary`) with compact status chips showing session state and recency.

**Why:** Prose summaries required reading and parsing. For rapid context-switching between projects, users need **scannable signals**, not narratives. A chip showing "🟡 Waiting · 2h ago" is instantly parseable.

**Agent impact:**
- Don't implement prose summary features—the pattern is deprecated
- Status chips are the canonical way to show project context
- Stats now refresh every 30 seconds to keep recency accurate
- Summary caching logic removed from project cards

**Deprecated:** Three-tier summary fallback, `workingOn` field, prose-based project context display.

**Commits:** `e1b8ed5`, `cca2c28`

---

### 2026-01-25 — Async Hooks and IDE Terminal Activation

**What changed:**
1. Hooks now use Claude Code's `async: true` feature to run in background
2. Setup card detects missing async configuration and prompts to fix
3. Clicking projects with shells in Cursor/VS Code activates the correct IDE window

**Why:**
- Async hooks eliminate latency impact on Claude Code (sidecar philosophy: observe without interfering)
- IDE support handles growing use case of integrated terminals vs standalone terminal apps

**Agent impact:**
- Hook config now includes `async: true` and `timeout: 30` for most events
- `SessionEnd` stays synchronous to ensure cleanup completes
- New `IDEApp` enum in `TerminalLauncher.swift` handles Cursor, VS Code, VS Code Insiders
- Setup card validation checks async config, not just hook existence

**Commits:** `24622a4`, `225a0d7`, `8c8debc`

---

### 2026-01-24 — Terminal Window Reuse and Tmux Support

**What changed:** Clicking a project reuses existing terminal windows instead of always launching new ones. Added tmux session switching and TTY-based tab selection.

**Why:** Avoid terminal window proliferation. Users typically want to switch to existing sessions, not create new ones.

**Agent impact:**
- `TerminalLauncher` now searches daemon shell snapshots for matching shells before launching new terminals
- Supports iTerm, Terminal.app tab selection via AppleScript
- Supports kitty remote control for window focus
- Tmux sessions are switched via `tmux switch-client -t <session>`

**Commits:** `5c58d3d`, `bcfc5f9`

---

### 2026-01-24 — Shell Integration Performance Optimization

**What changed:** Rewrote shell hook to use native macOS `libproc` APIs instead of subprocess calls for process tree walking.

**Why:** Target <15ms execution time for shell precmd hooks. Subprocess calls (`ps`, `pgrep`) were too slow.

**Agent impact:** The `hud-hook cwd` command is now the canonical way to track shell CWD. Shell history stored in `~/.capacitor/shell-history.jsonl` with 30-day retention.

**Commits:** `146f2b4`, `a02c54d`, `a1d371b`

---

### 2026-01-23 — Plan File Audit and Compaction

**What changed:** Archived completed plans with `DONE-` prefix, compacted to summaries. Removed stale documentation.

**Why:** Keep `.claude/plans/` focused on actionable implementation plans.

**Agent impact:** When looking for implementation history, check `DONE-*.md` files for context. Git history preserves original detailed versions.

**Commit:** `052cecb`

---

### 2026-01-21 — Binary-Only Hook Architecture

**What changed:** Removed bash wrapper script for hooks, now uses pure Rust binary at `~/.local/bin/hud-hook`.

**Why:** Eliminate shell parsing overhead, improve reliability, reduce dependencies.

**Agent impact:** Hooks are installed via `./scripts/sync-hooks.sh`. The hook binary handles all Claude Code events directly.

**Deprecated:** Wrapper scripts, bash-based hook handlers.

**Commits:** `13ef958`, `6321e4d`

---

### 2026-01-20 — Bash to Rust Hook Migration

**What changed:** Migrated hook handler from bash script to compiled Rust binary (`hud-hook`).

**Why:** Performance (bash was too slow), reliability, better error handling.

**Agent impact:** Hook logic lives in `core/hud-hook/src/`. The binary is installed to `~/.local/bin/hud-hook`.

**Commit:** `c94c56b`

---

### 2026-01-19 — V3 State Detection Architecture

**What changed:** Adopted new state detection that uses lock file existence as authoritative signal. Removed conflicting state overrides.

**Why:** Lock existence + live PID is more reliable than timestamp freshness. Handles tool-free text generation where no hook events fire.

**Agent impact (historical):** Pre-daemon debugging used lock files. In daemon-only mode, use `get_sessions`/`get_project_states` over IPC instead.

**Deprecated:** Previous state detection approaches that relied on timestamp freshness.

**Commits:** `92305f5`, `6dfa930`

---

### 2026-01-17 — Agent SDK Integration Removed

**What changed:** Removed experimental Agent SDK integration.

**Why:** Discarded direction—Capacitor is a sidecar, not an AI agent host.

**Agent impact:** Do not attempt to add Agent SDK or similar integrations. The app observes Claude Code, doesn't run AI directly.

**Commit:** `1fd6464`

---

### 2026-01-16 — Storage Namespace Migration

**What changed:** Migrated from `~/.claude/` to `~/.capacitor/` namespace for Capacitor-owned state.

**Why:** Respect sidecar architecture—read from Claude's namespace, write to our own.

**Agent impact:** All Capacitor state files are in `~/.capacitor/`. Claude Code config remains in `~/.claude/`.

**Key paths (historical):**
- `~/.capacitor/hud-hook-debug.{date}.log` — Debug logs
- Legacy session/lock JSON files are deprecated in daemon-only mode.

**Commits:** `1d6c4ae`, `1edae7d`

---

### 2026-01-15 — Thinking State Removed

**What changed:** Removed deprecated "thinking" state from session tracking.

**Why:** Claude Code no longer uses extended thinking in a way that needs separate UI state.

**Agent impact:** Session states are: `Working`, `Ready`, `Idle`, `Compacting`, `Waiting`. No "Thinking" state.

**Commit:** `500ae3f`

---

### 2026-01-14 — Caustic Underglow Feature Removed

**What changed:** Removed experimental visual effect (underglow/glow).

**Why:** Design decision—cleaner UI without the effect.

**Agent impact:** Do not add back underglow or similar effects. The app uses subtle visual styling.

**Commit:** `f3826d5`

---

### 2026-01-13 — Daemon Architecture Removed

**What changed:** Removed background daemon process architecture.

**Why:** Simplified to foreground app with file-based state.

**Agent impact:** The app runs as a standard macOS app, not a daemon. State persistence is file-based.

**Deprecated:** Any daemon/background service patterns.

**Commit:** `1884e78`

---

### 2026-01-12 — Artifacts Feature Removed

**What changed:** Removed Artifacts feature, replaced with floating header with progressive blur.

**Why:** Artifacts was over-scoped. Simpler floating header serves the use case.

**Agent impact:** Do not add "artifacts" or similar content management features. The app focuses on session state and project switching.

**Commit:** `84504b3`

---

### 2026-01-10 — Relay Experiment Removed

**What changed:** Removed relay/proxy experiment.

**Why:** Discarded direction.

**Agent impact:** The app communicates directly with Claude Code via filesystem, not through relays.

**Commit:** `9231c39`

---

### 2026-01-07 — Tauri Client Removed, SwiftUI Focus

**What changed:** Removed Tauri/web client, focused entirely on native macOS SwiftUI app.

**Why:** Native performance, ProMotion 120Hz support, better macOS integration.

**Agent impact:** This is a SwiftUI-only project. No web technologies, no Tauri, no Electron.

**Commit:** `2b938e9`

---

### 2026-01-06 — Project Created

**What changed:** Initial commit, Rust + Swift architecture established.

**Why:** Build a native macOS dashboard for Claude Code power users.

**Agent impact:** Core architecture: Rust business logic + UniFFI + Swift UI.

---

## Deprecated Patterns

| Don't | Do Instead | Deprecated Since |
|-------|------------|------------------|
| Read or write `~/.capacitor/sessions.json` as primary state | Use daemon IPC (`get_sessions`, `get_project_states`) | 2026-02 |
| Write lock directories as a liveness source | Use daemon `get_process_liveness` | 2026-02 |
| Add new file-based fallbacks when daemon is down | Surface daemon-down errors and recover via LaunchAgent | 2026-02 |
| Use custom WindowResizeHandles overlay | Use `isMovableByWindowBackground = true` (default macOS behavior) | 2026-01-29 |
| Use `opacity(0)` + `allowsHitTesting(false)` to hide views | Use conditional `if` statement to remove from view hierarchy | 2026-01-29 |
| Use `onTapGesture(count: 2)` on draggable areas | Use `NSViewRepresentable` with `mouseDown` and `event.clickCount` | 2026-01-29 |
| Fill color first then draw image for tinting | Draw image with `.copy`, then fill color with `.sourceAtop` | 2026-01-29 |
| Use `NSImage(named:)` in SPM builds | Use `ResourceBundle.url(forResource:withExtension:)` | 2026-01-29 |
| Use shell record's `tmux_client_tty` directly for TTY discovery | Query fresh TTY via `getCurrentTmuxClientTty()` at activation time | 2026-01-28 |
| Allow HOME to match project paths via parent matching | Use `paths_match_excluding_home()` which excludes HOME from parent matching | 2026-01-28 |
| Check if client attached to *specific* tmux session | Check if *any* tmux client exists (`hasTmuxClientAttached()`) | 2026-01-28 |
| Select shells by timestamp alone when tmux client attached | Prefer tmux shells via `is_preferred_tmux` sort key | 2026-01-28 |
| Interpolate user input into shell commands without escaping | Use `shellEscape()` or `bashDoubleQuoteEscape()` | 2026-01-27 |
| Use `tmux list-clients` first line for multi-client detection | Use `tmux display-message -p "#{client_tty}"` | 2026-01-27 |
| Check Ghostty running before TTY discovery | Try TTY discovery first, Ghostty fallback second | 2026-01-27 |
| Use `map_or(false, \|x\| ...)` in Rust | Use `is_some_and(\|x\| ...)` (Rust 1.70+) | 2026-01-27 |
| Make multiple tmux subprocess calls for related data | Combine into single call with tab separator | 2026-01-27 |
| Filter dead shells before passing to Rust | Pass `is_live` flag, let Rust prefer live shells | 2026-01-27 |
| Rely on `serde(default)` to distinguish file formats | Check raw JSON for format-specific keys | 2026-01-27 |
| Check tmux before daemon shell snapshot in terminal activation | Check daemon shell snapshot first (active > exists) | 2026-01-27 |
| Use `Task` in Swift files with UniFFI imports | Use `_Concurrency.Task` to avoid shadowing | 2026-01-27 |
| Return `true` unconditionally from strategy methods | Return actual success status for fallback chains | 2026-01-27 |
| Create fake objects to extract few fields | Add overloads that accept the needed fields directly | 2026-01-27 |
| Return 0 from query functions on read errors | Return fail-safe sentinel (`usize::MAX`) to preserve state | 2026-01-27 |
| Use `std::mem::forget()` on guards with important `Drop` | Hold guard in scope, let it drop naturally | 2026-01-27 |
| Use `is_session_active()` or path-based session checks | Use daemon snapshots (`get_sessions`, `get_project_states`) | 2026-02 |
| Use `find_by_cwd()` for path→session lookup | Use daemon session snapshots keyed by `session_id` | 2026-02 |
| Use `boundaries::normalize_path()` | Use `normalize_path_for_hashing()` or `normalize_path_for_comparison()` | 2026-01-27 |
| Use `std::fs` directly | Use `fs_err as fs` import | 2026-01-26 |
| Duplicate `is_pid_alive` function | Import from `hud_core::state` | 2026-01-26 |
| Use custom `log()` functions | Use `tracing::debug!/info!/warn!/error!` | 2026-01-26 |
| Use `eprintln!` for errors | Use `tracing::warn!` or `tracing::error!` | 2026-01-26 |
| Write to `~/.claude/` | Write to `~/.capacitor/` | 2026-01-16 |
| Use bash for hook handling | Use Rust `hud-hook` binary | 2026-01-20 |
| Use wrapper scripts for hooks | Use binary-only architecture | 2026-01-21 |
| Track "Thinking" state | Use: Working, Ready, Idle, Compacting, Waiting | 2026-01-15 |
| Use Tauri or web technologies | Use SwiftUI only | 2026-01-07 |
| Run AI directly in app | Call Claude Code CLI instead | 2026-01-17 |
| Check timestamp freshness for session liveness | Use daemon `get_process_liveness` results | 2026-02 |
| Use `Bundle.module` directly | Use `ResourceBundle.url(forResource:)` | 2026-01-23 |
| Implement prose summaries | Use status chips for project context | 2026-01-25 |
| Use path-hash locks (`{md5}.lock`) | Use session-based locks (`{session_id}-{pid}.lock`) | 2026-01-26 |
| Inherit child lock state to parent path | Use exact-match-only path comparison | 2026-01-26 |
| Copy hook binary to `~/.local/bin/` | Symlink to `target/release/hud-hook` | 2026-01-26 |
| Rely on stale Ready record fallback | Use daemon `state_changed_at` + liveness for TTL decisions | 2026-02 |
| Ignore `#[must_use]` function return values | Always handle return values from query functions | 2026-01-26 |
| Use `.collect().len()` for counting | Use `.count()` directly on iterator | 2026-01-26 |
| Write unsafe code without SAFETY comments | Document safety invariants with `// SAFETY:` | 2026-01-26 |

## Trajectory

Primary near-term trajectory:

1. **Daemon-only cutover** — remove legacy JSON fallbacks and finalize lock deprecation.
2. **Session state heuristics** — eliminate stuck Working/Ready states with daemon-side TTL + liveness.
3. **UI responsiveness** — reduce polling/jank and avoid redundant UI refreshes during daemon reads.
4. **Debug build stability** — harden Sparkle/dylib bundling and app launch workflow to prevent crashes.
    - Added regression test for format detection

13. **Terminal activation priority** — ✅ Fixed (2026-01-27)
    - Shell-cwd.json now checked before tmux sessions
    - Fixes issue where clicking project opened new tmux window instead of focusing existing terminal

14. **Terminal activation security/reliability** — ✅ All Phases Complete (2026-01-27)
    - Phase 1: Shell injection prevention, tmux exit codes, IDE CLI errors, multi-client tmux fix
    - Phase 2: Tmux re-verification, AppleScript error checking, subdirectory matching, `is_live` flag, TTY-first Ghostty
    - Phase 3: Chrono timestamp parsing, Ghostty cache size limit, `pathsMatch` UniFFI export
    - Plan doc: `.claude/plans/DONE-terminal-activation-fixes.md`

15. **Plan housekeeping** — ✅ Complete (2026-01-28)
    - All ACTIVE plans marked DONE: bulletproof-hooks, terminal-shell-test-expansion
    - Terminal test expansion P1 gaps were already fixed during terminal activation hardening
    - Manual test matrix already documented at `.claude/docs/terminal-test-matrix.md`
    - Only DRAFT plan remaining: `activation-config-rust-migration.md` (deferred until second client needed)

16. **Terminal activation hardening validated** — ✅ Complete (2026-01-28)
    - v0.1.25 released with shell selection and client detection fixes
    - Test matrix validated: 15 scenarios pass (A1-A4, B1-B3, C1, D1-D3, E1, E3)
    - Test matrix doc: `.claude/docs/terminal-activation-test-matrix.md` (status columns updated)
    - Gotchas added: tmux priority, ANY-client detection

17. **Post v0.1.25 activation fixes** — ✅ Complete (2026-01-28)
    - Stale TTY fix: Query fresh client TTY at activation time (shell records become stale on tmux reconnect)
    - HOME exclusion: Exclude HOME from parent-directory matching (HOME matched everything)
    - OSLog limitation documented: Use stderr telemetry for debug builds
    - 4 new unit tests for HOME exclusion behavior

The core sidecar architecture is stable and validated. The 12-session side-effects audit confirmed all major subsystems work correctly; the few issues found have been remediated. **All implementation plans are now complete.** Terminal activation has been hardened with comprehensive test coverage (15 scenarios validated). Focus areas: lock reliability (session-based, self-healing, fail-safe error handling), exact-match path resolution for monorepos, terminal integration, and codebase hygiene (dead code removal, documentation accuracy).
