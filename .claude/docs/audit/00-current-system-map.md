# Current System Map (Ground Truth)

This document is the **canonical map** of Capacitor’s state detection + activation systems **as implemented today**.

It is written to prevent regressions caused by “fixing the visible symptom” in one subsystem while violating assumptions in another.

## What this covers

- **Session state detection** (daemon + fallback locks/records/activity)
- **Active project selection** (manual override vs Claude vs shell CWD)
- **Terminal activation** (tmux + TTY matching + app activation)
- **Cleanup & self-healing** (startup cleanup, tombstones, heartbeat)
- **Side effects** (filesystem/processes/signals) and the invariants they imply

## Canonical file paths (Capacitor namespace)

All files below are in Capacitor’s namespace (`~/.capacitor/`) and are safe to reset.

| Path | Producer(s) | Consumer(s) | Purpose |
|------|-------------|-------------|---------|
| `~/.capacitor/daemon.sock` | `capacitor-daemon` (LaunchAgent) | `hud-hook`, Swift app, `hud-core` | IPC channel (primary state reads/writes) |
| `~/.capacitor/daemon/state.db` | `capacitor-daemon` | `capacitor-daemon` | SQLite WAL store (authoritative state) |
| `~/.capacitor/daemon/daemon.stdout.log` | LaunchAgent | User | Daemon stdout log |
| `~/.capacitor/daemon/daemon.stderr.log` | LaunchAgent | User | Daemon stderr log |
| `~/.capacitor/sessions.json` | `hud-hook handle` (fallback), `hud-core cleanup` | `hud-core` (fallback only) | Session record store (fallback; stale when daemon is healthy) |
| `~/.capacitor/sessions/{session_id}-{pid}.lock/` | `hud-hook handle` (fallback), `hud-hook lock-holder` | `hud-core` lock/resolver/cleanup (fallback only) | Liveness proof for an active Claude process at an **exact path** |
| `~/.capacitor/ended-sessions/{session_id}` | `hud-hook handle` | `hud-hook handle` | Tombstone to prevent late events resurrecting ended sessions |
| `~/.capacitor/file-activity.json` | `hud-hook handle` (fallback) | `hud-core ActivityStore` (fallback only) | Secondary signal for Working (native format; legacy migrated) |
| `~/.capacitor/shell-cwd.json` | `hud-hook cwd` (fallback) | `ShellStateStore.swift` (fallback only) | Ambient shell CWD tracking for activation + highlight fallback |
| `~/.capacitor/shell-history.jsonl` | `hud-hook cwd` | `ShellHistoryStore.swift` (debug) | Append-only shell navigation history |
| `~/.capacitor/hud-hook-heartbeat` | `hud-hook handle` | Swift setup/health UI | “Hooks are firing” proof-of-life |

## Canonical external paths (non-Capacitor namespaces)

| Path | Owner | Producer(s) | Consumer(s) | Notes |
|------|-------|-------------|-------------|------|
| `~/.claude/settings.json` | Claude | Capacitor modifies **hooks only** | Claude + Capacitor | Must preserve non-hook config (`serde(flatten)` in `setup.rs`) |
| `~/.local/bin/hud-hook` | User bin | Capacitor installer | Claude hooks | **Symlink** strategy is required (copy can trigger Gatekeeper SIGKILL in dev) |

## High-level data flow (daemon-first, fallback on failure)

```mermaid
flowchart TD
    ClaudeHooks[ClaudeHooks] --> HudHookHandle[HudHook_handle.rs]
    ShellPrecmd[ShellPrecmdHook] --> HudHookCwd[HudHook_cwd.rs]

    HudHookHandle --> DaemonSock["~/.capacitor/daemon.sock"]
    HudHookCwd --> DaemonSock

    DaemonSock --> DaemonState["~/.capacitor/daemon/state.db"]

    HudHookHandle -.fallback.-> SessionsJson["~/.capacitor/sessions.json"]
    HudHookHandle -.fallback.-> Locks["~/.capacitor/sessions/{session_id}-{pid}.lock/"]
    HudHookHandle -.fallback.-> Tombstones["~/.capacitor/ended-sessions/{session_id}"]
    HudHookHandle -.fallback.-> FileActivity["~/.capacitor/file-activity.json"]
    HudHookHandle --> Heartbeat["~/.capacitor/hud-hook-heartbeat"]

    HudHookCwd -.fallback.-> ShellCwd["~/.capacitor/shell-cwd.json"]
    HudHookCwd -.fallback.-> ShellHistory["~/.capacitor/shell-history.jsonl"]

    AppLaunch[CapacitorAppLaunch] --> StartupCleanup[cleanup.rs]
    StartupCleanup -.fallback.-> Locks
    StartupCleanup -.fallback.-> SessionsJson
    StartupCleanup -.fallback.-> Tombstones

    SwiftUI[SwiftUI] --> HudEngine[HudEngine]
    HudEngine --> DaemonSock
    HudEngine -.fallback.-> Resolver[resolver.rs]
    Resolver -.fallback.-> Locks
    Resolver -.fallback.-> SessionsJson

    HudEngine -.fallback.-> ActivityStore[activity.rs]
    ActivityStore -.fallback.-> FileActivity

    SwiftUI --> ShellStateStore[ShellStateStore.swift]
    ShellStateStore --> DaemonSock
    ShellStateStore -.fallback.-> ShellCwd

    SwiftUI --> ActiveResolver[ActiveProjectResolver.swift]
    ActiveResolver --> HudEngine
    ActiveResolver --> ShellStateStore

    SwiftUI --> TerminalLauncher[TerminalLauncher.swift]
    TerminalLauncher --> ShellCwd
```

## Session lifecycle (daemon-first, fallback on failure)

```mermaid
sequenceDiagram
    participant Claude as ClaudeProcess
    participant Hook as hudHook_handle
    participant Daemon as daemon.sock
    participant Store as sessionsJson
    participant Lock as lockDir
    participant Tomb as tombstonesDir
    participant Act as fileActivity

    Claude->>Hook: HookEvent(SessionStart/UserPromptSubmit)
    Hook->>Hook: touch_heartbeat()
    Hook->>Daemon: send Event
    Hook-->>Claude: exit

    Claude->>Hook: HookEvent(PostToolUse/PreToolUse/etc)
    Hook->>Hook: has_tombstone? if yes, skip
    Hook->>Daemon: send Event
    Hook-->>Claude: exit

    Claude->>Hook: HookEvent(SessionEnd)
    Hook->>Daemon: send Event
    Hook-->>Claude: exit

    Note over Hook,Store: Fallback when daemon send fails
    Hook->>Lock: create_session_lock()
    Hook->>Store: StateStore.update()+save()
    Hook->>Act: record_file_activity()
    Hook->>Tomb: create_tombstone(session_id)
```

## Project session state resolution (Rust)

This is the logic behind each project card’s state (`Idle/Ready/Working/Waiting/Compacting`) and `is_locked` when daemon snapshots are unavailable.

```mermaid
flowchart TD
    Query[ProjectPathQuery] --> DaemonCheck{DaemonSnapshotAvailable?}
    DaemonCheck -->|Yes| DaemonState[Use daemon sessions/activity]
    DaemonCheck -->|No| Load[LoadStateStore(sessions.json)]
    Load --> Resolve[resolve_state_with_details]

    Resolve --> LocksExist{AnyActiveLockForExactPath?}
    LocksExist -->|Yes| PickLock[PickMatchingLock]
    PickLock --> RecordForLock[FindRecordForLockPath]
    RecordForLock --> FromLock[ReturnState(is_from_lock=true)]

    LocksExist -->|No| FreshRecord{FreshExactMatchRecord?}
    FreshRecord -->|Yes| ActiveStale{ActiveStateStale?}
    ActiveStale -->|Yes| ReadyFallback[ReturnReady(is_from_lock=false)]
    ActiveStale -->|No| RecordState[ReturnRecordState(is_from_lock=false)]

    FreshRecord -->|No| ActivityCheck{RecentActivityInPath?}
    ActivityCheck -->|Yes| WorkingByActivity[ReturnWorking(is_locked=false)]
    ActivityCheck -->|No| Idle[ReturnIdle]
```

Important derived behavior implemented in `sessions.rs`:
- **Ready → Idle** after 15 minutes **only when not from lock** (no liveness proof).

## Active project selection (Swift)

```mermaid
flowchart TD
    Tick[ResolveActiveProject] --> Override{ManualOverrideSet?}
    Override -->|Yes| ShellProject{ShellOnDifferentProjectWithActiveSession?}
    ShellProject -->|Yes| ClearOverride[manualOverride=nil]
    ShellProject -->|No| UseOverride[ReturnOverride]

    Override -->|No| ClaudeActive{AnyActiveClaudeSession?}
    ClaudeActive -->|Yes| PickClaude[PickBestClaudeSession]
    PickClaude --> ActiveProject[ReturnActiveProjectSourceClaude]

    ClaudeActive -->|No| ShellFallback{MostRecentNonStaleShell?}
    ShellFallback -->|Yes| ShellToProject[MapShellCwdToProjectContaining]
    ShellToProject --> ActiveShell[ReturnActiveProjectSourceShell]
    ShellFallback -->|No| None[ReturnNone]
```

Key asymmetry (intentional):
- **Locks/records** use **exact-match-only** (monorepo isolation).
- **Shell CWD → project** uses **child-path matching** (`/project/src` highlights `/project`) because it’s user navigation, not session isolation.

## Terminal activation (Swift)

Terminal activation is a best-effort UX feature; it should **never** affect session correctness.

```mermaid
flowchart TD
    Launch[launchTerminal(forProject)] --> QueryTmux{DirectTmuxSessionForPath?}
    QueryTmux -->|Yes| TmuxClient{tmuxClientAttached?}
    TmuxClient -->|Yes| SwitchClient[tmux switch-client]
    TmuxClient -->|No| LaunchTmux[LaunchTerminalWithTmuxSession]

    QueryTmux -->|No| FindShell{ExactMatchShellInShellCwd?}
    FindShell -->|Yes| Strategy[RunActivationStrategy]
    FindShell -->|No| LaunchNew[LaunchNewTerminal]

    Strategy --> ActivateTTY{TerminalSupportsTTYSelection?}
    ActivateTTY -->|Yes| AppleScriptSelect[AppleScriptSelectByTTY]
    ActivateTTY -->|No| ActivateApp[ActivateAppOnly]
```

## Startup cleanup (Rust, daemon-aware)

This runs once per app launch to remove cruft and reduce stale-state confusion. When the daemon is healthy, file-based cleanup is skipped to avoid mutating stale fallback data.

```mermaid
flowchart TD
    Start[run_startup_cleanup] --> KillOrphans[cleanup_orphaned_lock_holders]
    KillOrphans --> LegacyLocks[cleanup_legacy_locks]
    LegacyLocks --> StaleLocks[cleanup_stale_locks]
    StaleLocks --> OrphanSessions[cleanup_orphaned_sessions]
    OrphanSessions --> OldSessions[cleanup_old_sessions]
    OldSessions --> OldTombstones[cleanup_old_tombstones]
    OldTombstones --> Done[ReturnCleanupStats]
    Note right of Start: OrphanSessions/OldSessions/Activity cleanup skipped when daemon healthy
```

## Cross-cutting invariants (assumptions you must not violate)

These are the “contract points” between subsystems. Breaking them tends to create cascading regressions.

- **Invariant_LockMeansLiveness**: A lock directory is trusted as liveness proof **only if PID verification passes**.
  - If any subsystem can remove locks while the PID is alive, state will flicker to idle/ready incorrectly.
  - (Known violation today: lock-holder 24h timeout bug, see audit 02.)
- **Invariant_DaemonAuthoritative**: When daemon health is OK, daemon snapshots are the source of truth and file artifacts are fallback-only.
  - File cleanup should not mutate fallback data while daemon is healthy.
- **Invariant_ExactMatchOnlyForSessions**: Session state resolution does **not** inherit parent/child paths.
  - Child sessions do not affect parent cards, and vice versa.
- **Invariant_CapacitorOwnsCapacitorNamespace**: Anything in `~/.capacitor/` must be safe to delete/reset.
  - Every user-facing “Repair/Reset” flow depends on this.
- **Invariant_ClaudeNamespaceIsReadMostly**: We only modify `~/.claude/settings.json` hooks entries and preserve everything else.
- **Invariant_ActivationIsBestEffort**: Terminal activation failures must not change session detection state.

## Drift ledger (docs that have been historically misleading)

These are common sources of agent regressions:
- `.claude/docs/side-effects-map.md` historically referenced outdated paths (legacy lock format, activity path).
- `docs/architecture-decisions/001-state-tracking-approach.md` contains legacy lock examples.

This document (and the audits in `.claude/docs/audit/`) should be treated as the canonical reference for current behavior.
