# Agent Changelog

> This file helps coding agents understand project evolution, key decisions,
> and deprecated patterns. Updated: 2026-02-12 (alpha release pipeline guardrails + clippy dead-code hygiene)

## Current State Summary

Capacitor is a native macOS SwiftUI app (Apple Silicon, macOS 14+) that acts as a sidecar dashboard for Claude Code. The architecture uses a Rust core (`hud-core`) with UniFFI bindings to Swift plus a **Rust daemon (`capacitor-daemon`) that is the canonical source of truth** for session, shell, activity, and process-liveness state. Hooks emit events to the daemon over a Unix socket (`~/.capacitor/daemon.sock`), and Swift reads daemon snapshots (shell state + project aggregation); file-based JSON fallbacks are removed in daemon-only mode. Workstreams (managed git worktrees) are first-class with create/open/destroy UX and slug-prefixed naming; activation matching avoids crossing repo cards with managed worktree tmux panes. Project-card rendering now uses a **single unified active+idle row pipeline**, **stable outer identity by project path**, and **in-place status/effect animations** (no card-root remount invalidation), with status text using SwiftUI `numericText` content transitions. Manual ordering now persists as one global list (`projectOrder`) and active/idle groups are projections over that list with hysteresis bands (`active`/`cooling`/`idle`) to reduce Ready/Idle thrash. Daemon empty project snapshots are also quality-gated in Swift: one empty snapshot is held as transient noise, and clearing applies on consecutive empties. Terminal activation uses a Rust resolver plus Swift execution, explicitly targeting the attached tmux client TTY (`switch-client -c <tty>`) and then foregrounding the terminal window that owns that TTY. Build channel + alpha gating are runtime via `AppConfig` (env/Info.plist/config file), not compile-time flags; release versioning is centralized in `VERSION` (current alpha: `0.2.0-alpha.1`). **Release packaging defaults are now alpha-safe by script guardrail** (`build-distribution.sh` defaults to channel `alpha`, and `release.sh` forwards channel explicitly), reducing risk of shipping prod-channel feature flags in alpha artifacts. Daemon startup and steady-state now include dead-session reconciliation plus health-exposed reconcile telemetry, demoting dead non-idle sessions to `Idle` without waiting for TTL or manual cleanup.

> **Historical note:** Timeline entries below may reference pre-daemon artifacts (locks, `sessions.json`, `shell-cwd.json`). Treat them as historical context only; they are not current behavior.

## Stale Information Detected

| Location | States | Reality | Since |
|----------|--------|---------|-------|
| `AGENT_CHANGELOG.md` (2026-02-11 "Project-Card State Resolution + Daemon Startup Catch-up Hardening") | "List and dock rendering now key row identity by per-card session fingerprint (`ProjectOrdering.cardIdentityKey`)..." | `ProjectOrdering.cardIdentityKey` currently returns stable `project.path` only; session-state-based row-key coupling is intentionally removed | 2026-02-12 |
| `.claude/plans/ACTIVE-alpha-release-checklist.md` ("Build & Signing" block) | `App is code-signed`, `App is notarized`, and `DMG or ZIP artifact for download` remain unchecked | Local release verification now demonstrates successful code signing, notarized DMG acceptance (`spctl`), and generated ZIP/DMG artifacts for `0.2.0-alpha.1`; checklist needs manual status refresh | 2026-02-12 |

## Timeline

### 2026-02-12 — Alpha Release Pipeline Guardrails + Clippy Dead-Code Hygiene (Completed / Uncommitted)

**What changed:**
- Release distribution defaults now target alpha channel by default (`scripts/release/build-distribution.sh` sets `CHANNEL="alpha"`).
- Full release workflow now parses and forwards channel explicitly (`--alpha`, `--channel`) and passes args via arrays to avoid brittle shell expansion (`scripts/release/release.sh`).
- App bundle verifier warning/error counters no longer use post-increment under `set -e`; helper functions now increment safely and return success, preventing warning-only false failures (`scripts/release/verify-app-bundle.sh`).
- Clippy `-D warnings -W dead_code` daemon blockers were eliminated by scoping replay/reset helpers to test-only usage:
  - `Db::list_events`, `Db::clear_tombstones`, `Db::clear_sessions`, `Db::clear_activity`
  - `replay::rebuild_from_events`
- Added release guardrail bats tests (`tests/release-scripts/release-flow-guardrails.bats`) to lock:
  - alpha default channel in distribution script
  - explicit channel propagation in release workflow
  - no post-increment in verifier helpers
- Updated release quick workflow docs to call alpha channel explicitly (`.claude/docs/release-guide.md`).

**Why:**
- Public alpha packaging had a channel-safety gap: release scripts defaulted artifacts to `prod`, risking out-of-scope feature exposure in alpha builds.
- `verify-app-bundle.sh` could exit early due to `set -e` + arithmetic post-increment semantics, producing false negatives.
- CI-equivalent clippy dead-code failures blocked readiness signaling despite otherwise healthy tests/builds.

**Agent impact:**
- Treat alpha channel propagation as a release invariant: if adjusting release scripts, preserve explicit `--channel` forwarding and alpha-safe defaults.
- For release verification scripts running with `set -e`, avoid `((var++))` in helpers; use assignment arithmetic (`var=$((var + 1))`) or explicit `|| true` guard patterns.
- Do not widen test-scoped replay reset helpers into runtime paths without a concrete replay requirement; current production flow relies on catch-up over session-affecting events, not full DB replay resets.
- Keep `tests/release-scripts/release-flow-guardrails.bats` green when modifying release scripts.

**Evidence / tests:**
- `cargo clippy -- -D warnings -W dead_code` passes.
- `cargo test` passes.
- `bats tests/release-scripts` passes (includes new guardrail suite).
- `bats tests/hud-hook/hud-hook-smoke.bats` passes.
- `./scripts/release/verify-app-bundle.sh` exits 0 (warning-only path no longer aborts).
- `./scripts/release/build-distribution.sh --skip-notarization` now emits artifacts with `CapacitorChannel=alpha` in bundled `Info.plist`.

---

### 2026-02-12 — Holistic Project-Card Ordering Stabilization (In Progress / Uncommitted)

**What changed:**
- Replaced dual persisted ordering lists (`activeProjectOrder`, `idleProjectOrder`) with a single persisted global manual order (`projectOrder`) in Swift state and storage.
- Updated list and dock ordering to derive active/idle projections from one order source while keeping unified rendering (`grouped.active + grouped.idle`) and stable row identity.
- Added explicit activity hysteresis bands in `ProjectOrdering`:
  - `active` (`Working`, `Ready`, `Waiting`, `Compacting`)
  - `cooling` (recently `Idle`, within demotion grace)
  - `idle` (steady idle / no session)
- Added `movedGlobalOrder(...)` so drag reorder inside one visible group rewrites only those subset positions in the global order, preserving other cards' relative placement.
- Reworked `reconcileProjectGroups()` to maintain global-order hygiene (dedupe/missing/removed cleanup) instead of shuffling between dual lists; emits order telemetry.
- Added daemon snapshot quality guard in `SessionStateManager`: hold first empty `get_project_states` merge as transient; clear after consecutive empties.
- Added telemetry for ordering and snapshot decisions:
  - `project_order_changed`
  - `project_order_anomaly`
  - `session_state_empty_snapshot`
- Expanded regression coverage for global-order transitions, cooling-band classification, and empty-snapshot hold/commit behavior.

**Why:**
- Ready/Idle flapping and intermittent daemon empty snapshots were causing cards to jump off-screen/on-screen and reorder unexpectedly.
- A single global order plus hysteresis and snapshot-quality gating reduces visual thrash while preserving user intent.

**Agent impact:**
- Use `projectOrder` as the only persisted manual order source; do not reintroduce split active/idle order persistence.
- Preserve group projection semantics (active first visually), but keep relative ordering anchored to global order.
- Treat a single empty daemon project-state snapshot as likely transient transport/snapshot noise; avoid immediate UI demotion/clear behavior.
- For ordering regressions, inspect telemetry events above before changing view identity/animation code.

**Evidence / tests:**
- Swift tests pass with new coverage in:
  - `ProjectOrderingTests`
  - `ProjectOrderStoreTests`
  - `SessionStateManagerTests`
  - `DaemonClientTests` (sequential test socket responses).

---

### 2026-02-12 — Project Card Transition Invariants + In-Place Status Text Transitions (Completed)

**What changed:**
- Replaced split active/idle rendering loops in `ProjectsView` with a single unified `rows = grouped.active + grouped.idle` pipeline and one `ForEach`.
- Kept card row identity stable by path and removed card-root invalidation hooks (`.id(ProjectOrdering.cardContentStateFingerprint(...))`) from list and dock cards.
- Kept status/effect updates in-place: removed status identity resets (`.id(state)`) and restored SwiftUI status text transition path to `.contentTransition(... .numericText())`.
- Expanded regression guardrails:
  - list/dock must not remount cards for state updates
  - list must use unified rows loop
  - status indicator must use `numericText` and avoid forced identity resets
  - session observation hooks remain required.
- Aligned terminal/debug documentation with current client-TTY-targeted tmux switching semantics and public alpha terminal support scope.
- Documented these invariants in `.claude/docs/ui-refresh-contract.md` and `CLAUDE.md`.

**Why:**
- Repeated regressions occurred whenever animation work crossed the identity/update boundary, causing either `Idle`-stuck cards (under-invalidation) or hard-cut transitions (over-invalidation/remount).

**Agent impact:**
- Do not use card-root `.id(...)` state fingerprints to force visual refresh.
- Keep outer row identity stable and animate only internal status/effect layers.
- Treat unified row rendering and session observation hooks as hard invariants for state correctness.

**Commits:** `350d20d`, `67c7cae`, `213b341`

---

### 2026-02-12 — Dead Session Self-Healing (Startup + Periodic Reconciliation) (Unreleased)

**What changed:**
- Daemon project aggregation now demotes `Ready` to `Idle` when session process liveness is explicitly false (`is_alive == Some(false)`), preventing dead sessions from rendering as active cards.
- Added daemon-level reconciliation API (`SharedState::reconcile_dead_non_idle_sessions`) that rewrites dead non-idle sessions to `Idle`, resets `tools_in_flight`, clears `ready_reason`, and stamps `last_event` with `dead_pid_reconcile_<source>`.
- Added startup repair pass (`source=startup`) so stale persisted sessions are corrected immediately on daemon boot.
- Added periodic background repair loop in daemon main (`source=periodic`, every 15s) so missed `SessionEnd` paths self-heal during runtime.
- Added reconcile telemetry counters by source (`startup`, `periodic`) with run/repair totals + last-run timestamps, exposed on daemon `get_health` as `dead_session_reconcile` and `dead_session_reconcile_interval_secs`.
- Transparent UI telemetry server now includes daemon `get_health` in `/daemon-snapshot`, and the Interface Explorer Live panel renders reconcile telemetry under a new "Daemon Health" section.
- Added regression coverage for:
  - dead-ready demotion in project snapshots
  - unknown-pid (`pid=0`) non-demotion
  - startup repair of persisted dead-ready sessions
  - periodic repair of dead working sessions
  - daemon health contract includes reconcile telemetry.

**Why:**
- Real-world failure mode: killed/abruptly terminated Claude sessions can miss `SessionEnd`, leaving a persisted non-idle session row that keeps project cards stuck in `Ready`.
- Relying only on TTL or ideal hook completion delays recovery and leaks stale state into UI.

**Agent impact:**
- Treat `SessionEnd` as best-effort, not guaranteed. For stuck non-idle cards, inspect daemon `sessions.last_event` for `dead_pid_reconcile_startup|periodic`.
- Do not infer activity from `Ready` alone; PID liveness reconciliation can force `Ready` → `Idle`.
- Keep `pid=0` behavior unchanged (`is_alive=None`): unknown PID does not auto-demote.
- For production monitoring, poll `get_health` and track `dead_session_reconcile.startup|periodic` counters over time.

**Commits:** `5b2643a`

---

### 2026-02-11 — Stop→Ready Drift Fix + Tmux Foreground Accuracy (Completed)

**What changed:**
- Session reducer stop gating now skips only explicit hook/subagent stops (`stop_hook_active=true` or `metadata.agent_id`), and no longer skips valid stop events just because `last_activity_at` is newer.
- Added reducer regression tests to preserve the intended split:
  - valid stop with future activity timestamp still transitions to Ready
  - genuinely stale stop events are still skipped via stale-order protection
- Rust activation resolver now prefers tmux-session actions when a tmux session at path matches the clicked project, including `unknown`-parent shell records with attached tmux clients.
- Swift `TerminalLauncher` now:
  - resolves current tmux client TTY (`tmux display-message -p '#{client_tty}'`)
  - switches with explicit client targeting (`tmux switch-client -c <tty> -t <session>`)
  - foregrounds terminal by TTY ownership (including Ghostty owner PID resolution).
- Hardened script-output handling to avoid deadlock risk on large stdout captures.

**Why:**
- Real incidents showed Stop events being received without a corresponding Ready upsert, leaving cards stuck in Working.
- Tmux switching could succeed in the background while the wrong Ghostty window was foregrounded.

**Agent impact:**
- Do not reintroduce a `last_activity_at > stop.recorded_at` skip in stop gating.
- For tmux activation debugging, inspect client TTY and verify `switch-client -c` usage before blaming resolver ranking.
- Treat "switched tmux session but wrong foreground window" as a focus-path issue, not a session-resolution success.

**Commits:** `74a0e4f`, `8a6dac5`

---

### 2026-02-11 — Project-Card State Resolution + Daemon Startup Catch-up Hardening (Completed)

**What changed:**
- Project-card state resolution now uses normalized path fallback with direct-match priority, and repo-fallback states no longer overwrite direct workspace matches.
- List and dock rendering now key row identity by per-card session fingerprint (`ProjectOrdering.cardIdentityKey`) instead of global revision-only IDs.
- Card state rendering/animations were stabilized:
  - status labels keyed by state
  - preview-state overrides removed from runtime state transitions
  - regression tests added for identity, observation, and state-resolution behavior.
- Daemon startup moved from broad replay triggers to bounded catch-up over **session-affecting events** only.
- Catch-up queries exclude non-session-mutating noise (`shell_cwd`, `subagent_start`, `subagent_stop`, `teammate_idle`) and use a bounded time window.
- Added startup catch-up tests and adjusted one test to use relative timestamps (time-stable across execution dates).

**Why:**
- Card UI could drift from actual daemon state due to stale row identity and path mismatch edge cases.
- Startup replay based on "latest event > latest session" could be triggered by irrelevant events and produce incorrect session rebuild behavior.

**Agent impact:**
- For project-card regressions, start with `SessionStateManager` merge priority + `ProjectOrdering.cardIdentityKey` before touching visual components.
- Keep daemon catch-up scoped to session-affecting events; avoid widening it to all event types.
- Use relative timestamps in catch-up tests to avoid date-window flakiness.

**Commits:** `375dd10`, `8192c82`

---

### 2026-02-09 — UI Polish Sprint: Empty State, Brand Color, Full-Bleed Dropzone (Completed)

**What changed:**
- Redesigned empty project list with full-frame marching ants border and multi-select suggestion list. Suggestion heuristics now filter junk paths (home, `/private/tmp`, subdirectories of pinned projects, dirs without project indicators or `CLAUDE.md`). Capped at 8 suggestions.
- Added dynamic footer CTA that transitions between default (pin/logo/plus) and contextual "Connect N Projects" when suggestions are selected. Moved suggestion selection state to AppState for cross-view coordination.
- Polished empty state: interactive logomark knob (drag-to-rotate, hover-to-brighten), inline "browse" text link, singular/plural CTA label.
- Codified brand color as `Color.brand` in Display P3 (`oklch(0.8647 0.2886 150.35)`). Used for empty state glow, ready status chips, and dropzone overlay.
- Added `logo-small.pdf` for footer LogoView with vibrancy masking.
- Added `TracklessScroller` (`NSScroller` subclass) to hide scrollbar track while preserving overlay knob, per `NSScroller.h` overlay contract.
- Replaced `MarchingAntsBorder` empty state animation with `EmptyStateBorderGlow` (animated angular gradient with tunable parameters via DEBUG tuning panel).
- Made dropzone overlay full-bleed: card-level `DropDelegate`s now handle `.fileURL` drags alongside `.text` reordering, bridging hover state through `AppState.isFileDragOverCard` so the overlay appears regardless of cursor position.
- Dropzone overlay uses `.ultraThinMaterial` frosted glass backdrop with brand-colored marching ants border and spring animations.
- **Critical fix:** marching ants use `@State` + `withAnimation(.repeatForever)` instead of `TimelineView(.animation)` — the latter re-evaluates every frame (120fps ProMotion), forcing WindowServer to re-composite material blur per-frame, which crashed the Mac and forced logout.
- Documented WindowServer crash gotcha in `.claude/docs/gotchas.md`.

**Why:**
- Create an inviting first-run experience that actively helps users connect projects rather than presenting a blank slate.
- Establish brand color system for consistent visual identity.
- Full-bleed dropzone was broken: SwiftUI's nested `.onDrop` modifiers prevent parent `isTargeted` from firing when cursor enters child views. Bridging via AppState resolves this.

**Agent impact:**
- `Color.brand` is the canonical green accent; prefer it over `Color.hudAccent` for new brand-touch UI.
- **Never use `TimelineView(.animation)` near material blur** — use `@State` + `withAnimation(.repeatForever)` instead (Core Animation interpolates without view body re-evaluation).
- `TracklessScroller` hides scrollbar tracks; use via `ScrollViewScrollerInsetsConfigurator`.
- `EmptyStateBorderGlow` is tunable via `GlassConfig` in debug builds.
- For nested `.onDrop` scenarios, use the `DockDropDelegate`/`ProjectDropDelegate` pattern: card-level delegates detect external file drags via `draggedProject == nil` and bridge state through AppState.
- Suggestion heuristics live in `AppState.suggestProjectPaths()` — add project indicators there when new patterns emerge.

**Files changed:**
- `ContentView.swift` — full-bleed dropzone overlay, `MarchingAntsBorder` struct, `EmptyStateBorderGlow`
- `AppState.swift` — `isFileDragOverCard`, `handleFileURLDrop()`, suggestion selection state, `addSuggestedProjects()`
- `ProjectsView.swift` — empty state redesign, `EmptyProjectsView`, `SuggestedProjectsBanner`, logomark knob
- `DockLayoutView.swift` — `DockDropDelegate` dual-type handling
- `FooterView.swift` — dynamic CTA, logo-small
- `HeaderView.swift` — removed connect button
- `Colors.swift` — `Color.brand` definition
- `ScrollViewScrollerInsetsConfigurator.swift` — `TracklessScroller`
- `GlassConfig.swift`, `TuningSections.swift` — glow tuning panel
- `.claude/docs/gotchas.md` — TimelineView + material blur crash

**Commits:** `9ef6f85`, `e8bc568`, `cd538fd`, `c255264`, `aa78867`

---

### 2026-02-09 — Session Attribution Hardening + Stuck-Session Diagnostics (Completed)

**What changed:**
- Session reducer now treats `PostToolUseFailure` as Working + activity heartbeat, adds `TaskCompleted` → Ready (`ready_reason=task_completed`), and maps `permission_prompt` notifications to Waiting; SubagentStart/Stop/TeammateIdle events are ignored.
- Stop gating loosened: stop no longer blocked by tools-in-flight or recent activity; it only skips when stop hook is active or when event timestamps are out-of-order. Stop/TaskCompleted reset `tools_in_flight`.
- Project identity derivation now ignores `file_path` when it resolves outside the current project path to avoid cross-project attribution.
- Daemon project aggregation can auto-ready Working sessions after 60s of tool inactivity when `tools_in_flight=0` (uses `last_activity_at` + last_event).
- Hook registration expanded to include `PostToolUseFailure`, `TaskCompleted`, `SubagentStart/Stop`, `TeammateIdle`, with required tool matchers.
- Added debug-only diagnostics snapshot logger writing JSONL to `~/.capacitor/daemon/diagnostic-snapshots.jsonl` for stuck Working sessions; new debug cards show daemon sessions/shells + `ready_reason`/`tools_in_flight`.

**Why:**
- Reduce stuck Working states, avoid mis-attribution from off-project file paths, and make recovery diagnosable without log spelunking.

**Agent impact:**
- For stuck-session investigations, start with diagnostics snapshots + debug session/shell cards; `ready_reason` and `tools_in_flight` explain Ready transitions.
- Stop events are now valid readiness gates even if recent tool activity exists (unless stop hook active or timestamp is older than last activity).
- Do not let off-project file paths override project identity; rely on cwd/project_path.

**Commits:** `0ec8f85`

---

### 2026-02-08 — Ready Gating + Compaction Tool Tracking (Completed)

**What changed:**
- Daemon sessions now persist `last_activity_at`, `tools_in_flight`, and `ready_reason` (DB schema adds columns; snapshots + Swift decoder include fields).
- Tools-in-flight tracking: PreToolUse increments, PostToolUse decrements, PreCompact resets; `last_activity_at` updates on tool + prompt events.
- Ready gating added: idle_prompt notification only sets Ready when `tools_in_flight=0`; Stop sets Ready with `ready_reason=stop_gate` when stop hook not active and no agent-id metadata; recent activity and tools-in-flight originally gated Ready.
- Compaction transitions explicitly reset `tools_in_flight` so Stop after PreCompact can set Ready without lingering tool counts.
- Hook sender now passes `agent_id` metadata and skips subagent Stop events before daemon send.

**Why:**
- Prevent Ready transitions while tools are still running, preserve compaction correctness, and make Ready transitions explainable.

**Agent impact:**
- Use `tools_in_flight` + `ready_reason` when debugging Ready/Working edges; compaction resets tool counts.
- DB migrations now expect sessions table to include `tools_in_flight` and `ready_reason`.
- Stop gating uses `agent_id` metadata; subagent stop events are ignored.

**Commits:** `be71dd4`

---

### 2026-02-08 — Public Alpha Hardening + Terminal Support Narrowing (Completed)

**What changed:**
- Alpha scope hardened in UI + docs: README rewritten for public alpha, help menu includes “Report a Bug”, and alpha checklist consolidated.
- Terminal activation narrowed to supported apps only (Ghostty, iTerm2, Terminal.app); unsupported launch branches removed and activation now fails gracefully when no supported terminal is installed.
- Project list UX tightened: drag-reorder preview + persistence helpers, missing project paths now surface as missing (tests added), and dormant override handling stabilized.
- Startup warnings/logging routed through `DebugLog` rather than `print()` for release hygiene.

**Why:**
- Reduce alpha surface area to the reliable core while removing confusing or unsupported terminal flows.

**Agent impact:**
- Treat any non-supported terminal paths as out-of-scope for alpha; use `TerminalLauncher`’s supported set only.
- When diagnosing activation issues, first confirm supported terminal presence + running state.
- Prefer `DebugLog` over `print()` for release-facing diagnostics.

---

### 2026-02-08 — Alpha Pre-release Versioning (0.2.0-alpha.1)

**What changed:**
- Central version bumped to `0.2.0-alpha.1` (`VERSION`, `Cargo.toml`, App.swift fallback) and lockfile updated.
- `scripts/release/bump-version.sh` now accepts prerelease/build suffixes (e.g., `0.2.0-alpha.1`).

**Why:**
- Align release tooling with public alpha distribution and enable SemVer prerelease tags.

**Agent impact:**
- Use `VERSION` as the source of truth; prerelease tags are now valid inputs to `bump-version.sh`.

---

### 2026-02-08 — Runtime Channel Feature Flags for Alpha Gating (Unreleased)

**What changed:**
- Added `AppConfig` + `FeatureFlags` with channel resolution order: env → Info.plist → `~/.capacitor/config.json` → default.
- Alpha channel defaults disable idea capture + project details; opt-in overrides via `CAPACITOR_FEATURES_*`, Info.plist keys, or config file.
- Removed compile-time `#if ALPHA` gates in Swift UI; runtime `appState.isIdeaCaptureEnabled` / `isProjectDetailsEnabled` now control all entry points.
- Build scripts now write `CapacitorChannel` into debug/release Info.plist and accept `--channel` / `--alpha` to set runtime channel.
- Added `AppConfigTests` to lock down channel precedence + feature override behavior.

**Why:**
- Avoid inconsistent alpha behavior across build variants; allow channel toggles without recompiling.

**Agent impact:**
- To test alpha gating, set channel via Info.plist or `CAPACITOR_CHANNEL`; no compile-time flags required.
- Feature overrides are supported for targeted testing (`CAPACITOR_FEATURES_ENABLED` / `CAPACITOR_FEATURES_DISABLED`).

### 2026-02-08 — Transparent UI Telemetry Hub + Agent Briefing (Completed)

**What changed:**
- Added local transparent UI server (`scripts/transparent-ui-server.mjs`) + launcher (`scripts/run-transparent-ui.sh`) that serves:
  - SSE activation trace (`/activation-trace`)
  - daemon snapshot (`/daemon-snapshot`)
  - telemetry ingest + stream (`/telemetry`, `/telemetry-stream`)
  - agent briefing payload (`/agent-briefing`)
- Wired Swift telemetry emitter (`Telemetry.swift`) and added structured events for activation decisions, daemon IPC errors, shell state refresh, active project resolution, and daemon health.
- Updated the Interface Explorer to show telemetry feed + agent briefing panel; briefing defaults to compact shells via `shells=recent` and `shell_limit`.

**Why:**
- Provide a single debugging hub for humans and coding agents; make runtime decisions observable without digging through logs.

**Agent impact:**
- Use `/agent-briefing` for compact context; add `shells=all` only when full shell inventory is required.
- Telemetry is in-memory only; restart clears events (persist in daemon or disk if needed).
- Prefer the transparent UI server during debugging; no production dependency.

### 2026-02-07 — Transparent UI IA Plan + Interface Explorer (Completed)

**What changed:**
- Added IA synthesis plan (`.claude/plans/ACTIVE-transparent-ui-ia-synthesis.md`) and Task3 UX architecture plan.
- Added initial Interface Explorer (`docs/transparent-ui/capacitor-interfaces-explorer.html`) and enriched data model (`docs/transparent-ui/enriched-data-model.ts`).

**Why:**
- Establish a unified IA roadmap and a concrete debugging/learning artifact for system behavior.

**Agent impact:**
- Treat the Interface Explorer as the canonical visual map for boundaries + activation flow.
- Use the IA plan to guide future transparent UI panel additions (behavior-first, progressive disclosure).

### 2026-02-07 — Alpha Feature Gating + UI Terminology Polish (Completed)

**What changed:**
- Gated non-alpha UI behind compile-time `#if !ALPHA` checks (idea capture, project detail view, activity panel, workstreams, new-idea flow).
- Build scripts gained `--alpha` to pass `-Xswiftc -DALPHA` during Swift builds.
- UI terminology polish: “Remove from HUD” → “Disconnect”, “Paused” → “Hidden”, hover actions stripped for alpha.
- Hidden section auto-scroll fix via `ScrollViewReader` + `PausedSectionHeader` delegation.

**Why:**
- Align public alpha scope to a smaller, reliable feature surface while keeping broader capabilities in mainline.

**Agent impact:**
- Alpha gating is **compile-time**; to test alpha behavior you must rebuild with `-DALPHA` (e.g., `restart-app.sh --alpha` or `build-distribution.sh --alpha`).
- If you run debug builds without `--alpha`, gated features will still appear.

### 2026-02-05 — Workstreams Lifecycle UX (Completed)

**What changed:**
- Added `WorktreeService` with deterministic command-driven tests for:
  - porcelain parsing (`git worktree list --porcelain`)
  - managed-root filtering (`{repo}/.capacitor/worktrees/`)
  - create/remove command construction
- Added destroy safety guardrails in `WorktreeService`:
  - stale metadata prune (`git worktree prune`) before list/remove
  - dirty-worktree block (`git status --porcelain`)
  - active-session guard (blocks if active path is at/under target worktree)
  - explicit locked-worktree error mapping for UI-safe messaging
- Added `WorkstreamsManager` state model and unit tests for:
  - loading/error states
  - create/open/destroy action transitions
  - next available workstream naming (`workstream-N`)
- Added `WorkstreamsPanel` and wired it into `ProjectDetailView` for create/list/open/destroy lifecycle actions.
- Added integration coverage for lifecycle flow (`create -> shell attribution -> destroy guardrail`) in `WorkstreamsLifecycleIntegrationTests`.
- Added workstream deletion flow + UI confirmations, with coverage in `WorkstreamsManagerTests`.
- Prefixed workstream names with the project slug for clarity and collision avoidance.
- Hardened activation matching for managed worktrees:
  - worktree activation ranking fixes in Rust policy
  - tmux session matching fixes for managed worktree open
  - repo card open no longer matches managed worktree tmux panes
  - create retry path made resilient

**Why:**
- Ship the user-visible workstreams lifecycle on top of the already-completed identity/mapping foundation.

**Agent impact:**
- Managed worktrees now have a canonical Swift service (`WorktreeService`) and UI-facing state model (`WorkstreamsManager`).
- Destroy UX should use service errors directly; avoid ad-hoc string parsing in UI.
- Treat `.capacitor/worktrees/` under repo root as the managed namespace.
- Workstream names now use `${projectSlug}-workstream-N`; rely on this naming for UI and matching logic.
- Activation resolution should not bind repo cards to managed worktree tmux panes; use worktree-aware matching first.

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

**Status update:**
- Worktree lifecycle UX completed on 2026-02-05; follow-up naming/activation matching fixes landed same day.

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
| Persist separate active/idle manual order lists (`activeProjectOrder` / `idleProjectOrder`) | Persist one global `projectOrder` and derive active/idle projections from that single sequence | 2026-02-12 |
| Clear session state immediately on first empty daemon `get_project_states` snapshot | Hold first empty snapshot as transient; clear after consecutive empties | 2026-02-12 |
| Use `tmux switch-client -t <session>` when a client TTY is known | Resolve `#{client_tty}` and use `tmux switch-client -c <client_tty> -t <session>` | 2026-02-11 |
| Key project-card rows by global `sessionStateRevision` or state-dependent row IDs | Keep row identity stable by `project.path` / `ProjectOrdering.cardIdentityKey(...)` | 2026-02-12 |
| Force card refresh by remounting card roots (`.id(ProjectOrdering.cardContentStateFingerprint(...))`) | Keep card shell mounted; animate only status/effect sublayers in place | 2026-02-12 |
| Force status text identity resets (`.id(state)`) to show transitions | Keep stable status identity and use SwiftUI `.contentTransition(... .numericText())` | 2026-02-12 |
| Skip Stop events because `last_activity_at > stop.recorded_at` | Keep stop gating limited to hook/subagent semantics; rely on stale-order guard for truly stale events | 2026-02-11 |
| Use `TimelineView(.animation)` near material blur | Use `@State` + `withAnimation(.repeatForever)` (Core Animation, no view re-eval) | 2026-02-09 |
| Use `Color.hudAccent` for brand-touch UI | Use `Color.brand` (Display P3 green) | 2026-02-09 |
| Use `#if ALPHA` compile-time feature gating | Use runtime `AppConfig` + `FeatureFlags` (env/Info.plist/config) | 2026-02-08 |
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

Current near-term focus (2026-02-12):

1. **Manual validation on fresh sessions** — keep validating `Working -> Ready` transitions after Stop in real runtime flows (not only reducer/unit tests), with daemon log/DB correlation.
2. **Transparent UI as first debugger** — continue routing activation/session investigations through telemetry + agent briefing endpoints before ad-hoc log spelunking.
3. **Transition polish on locked invariants** — improve perceived smoothness of status/effect transitions without changing row identity boundaries or list pipeline shape.
4. **Alpha stability hardening** — continue reducing state drift and activation edge-case regressions while preserving deterministic tests.

Overall trajectory:

The project has shifted from broad architecture migration into reliability hardening loops: reproduce incidents, lock behavior with regression tests, and then patch reducer/resolver/runtime code paths with minimal blast radius. Current direction favors correctness and observability over feature expansion until alpha session-state and terminal activation behavior are consistently predictable.
