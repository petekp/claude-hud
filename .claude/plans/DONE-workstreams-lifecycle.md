# Workstreams Lifecycle (Done)

**Status:** DONE
**Completed:** 2026-02-05
**Source:** `docs/brainstorms/2026-01-25-parallel-workstreams-brainstorm.md`

## Outcome

Workstreams lifecycle support is now shipped in Capacitor for managed git worktrees under:

- `{repo}/.capacitor/worktrees/{name}/`

Users can now:

1. Create managed worktrees from project detail.
2. List and open managed worktrees.
3. Destroy managed worktrees with safety guardrails.

## Shipped Work

### Phase 1: Service Core

- Added `WorktreeService`:
  - porcelain parser for `git worktree list --porcelain`
  - managed-root filtering
  - create/remove command execution
- Added deterministic unit tests in `WorktreeServiceTests`.

### Phase 2: Safety Guardrails

- Added destroy guardrails in `WorktreeService`:
  - `git worktree prune` preflight before list/remove
  - dirty check (`git status --porcelain`) block by default
  - active-session path guardrail block
  - locked-worktree error mapping for explicit UI messaging
- Added test coverage for each guardrail path.

### Phase 3: UI + State Model

- Added `WorkstreamsManager` for UI-facing lifecycle state:
  - load/create/open/destroy actions
  - action-level loading/error state
  - deterministic next-name generation (`workstream-N`)
- Added `WorkstreamsPanel` and integrated it into `ProjectDetailView`.
- Wired open action through existing `TerminalLauncher`.

### Phase 4: Integration + Docs

- Added integration coverage in `WorkstreamsLifecycleIntegrationTests`:
  - create managed worktree
  - resolve active project attribution from worktree shell path
  - verify destroy guardrail blocks active worktree removal
- Updated project docs to reflect lifecycle completion and remaining non-goals.

## Validation

- `cd apps/swift && swift test` (green)
- `cargo test -p capacitor-daemon` (green)

## Remaining Non-Goals

- PR creation/merge automation
- Cross-machine worktree sync
- Worktree templates/presets
- Global multi-repo workstreams dashboard
- Workstream display-name persistence
