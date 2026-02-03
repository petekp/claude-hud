# Legacy / Dead Code Audit Plan (Daemon Phase 7)

## Scope
Audit for legacy, dead, or irrelevant code paths now that the daemon is the only source of truth.
Focus on daemon state aggregation, hud-core state derivation, Swift client consumption, and docs.

## Pre-Analysis Hypotheses
- hud-core still applies local staleness rules on top of daemon state.
- Tests reference removed process-liveness payload types.
- Naming like `is_locked` reflects old lock-file architecture.
- Docs/ADRs mention lock-holder or file-based session state as current.

## Subsystems
| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Daemon core state/aggregation | core/daemon/src/{state.rs,reducer.rs,session_store.rs} | DB writes, IPC | High |
| 2 | hud-core state derivation | core/hud-core/src/{sessions.rs,state/daemon.rs,state/types.rs} | IPC calls, local state | High |
| 3 | Swift app consumption | apps/swift/Sources/Capacitor/Models/{SessionStateManager.swift,DaemonClient.swift} | IPC, UI | Medium |
| 4 | Docs/ADRs | docs/architecture-decisions/*.md, docs/plans/*.md, AGENT_CHANGELOG.md | Documentation | Medium |

## Method
- Read each subsystem in full and identify dead/legacy logic or stale docs.
- Classify findings by severity and provide concrete fix recommendations.
- Summarize actionable cleanup and document updates needed before Phase 7.
