# Workstreams Lifecycle Implementation Plan

**Status:** ACTIVE
**Created:** 2026-02-05
**Last Updated:** 2026-02-05
**Source:** `docs/brainstorms/2026-01-25-parallel-workstreams-brainstorm.md`
**Related Context:** `AGENT_CHANGELOG.md` (2026-02-04 worktree foundation entry)

## Goal

Ship user-visible Workstreams lifecycle support in Capacitor:

1. Create managed worktrees from the app
2. List and open existing managed worktrees
3. Safely destroy managed worktrees with guardrails

Identity and mapping foundations are already complete (project/workspace IDs, worktree-aware attribution). This plan covers lifecycle UX and operations.

## Scope

### In Scope

- Managed worktree operations under `{repo}/.capacitor/worktrees/`
- One-click create/list/open/destroy from Capacitor UI
- Safety checks for destroy flows
- TDD-first implementation and regression tests
- Documentation updates at each completed phase

### Out of Scope

- PR creation/merge automation
- Cross-machine worktree sync
- Worktree templates/presets
- Multi-repo global workstreams dashboard

## Progress Tracking

| Phase | Status | Owner | Notes |
|------|--------|-------|-------|
| Phase 1: Worktree Service Core | Not Started | Codex | Git operations + parsing + unit tests |
| Phase 2: Safety Guardrails | Not Started | Codex | Dirty/active/locked protections |
| Phase 3: Workstreams UI | Not Started | Codex | Panel + actions + state wiring |
| Phase 4: Integration + Docs | Not Started | Codex | End-to-end tests + doc completion |

## TDD Protocol (Required)

For every scoped change:

1. Add or update tests that fail first for the intended behavior.
2. Implement the minimal fix to make tests pass.
3. Refactor safely with tests green.
4. Record progress in this file (checkbox + phase status table).

## Phase 1: Worktree Service Core

### Deliverables

- New Swift service for managed worktree lifecycle operations
- Stable parsing for `git worktree list --porcelain`
- Managed-root policy (`.capacitor/worktrees/`) in one place

### Candidate Files

- `apps/swift/Sources/Capacitor/Helpers/WorktreeService.swift` (new)
- `apps/swift/Tests/CapacitorTests/WorktreeServiceTests.swift` (new)
- `apps/swift/Sources/Capacitor/Models/AppState.swift` (wiring as needed)

### Tasks

- [ ] Add failing tests for porcelain parsing into a typed model.
- [ ] Add failing tests for list behavior (managed-only filtering).
- [ ] Add failing tests for create behavior (`git worktree add ...` command construction).
- [ ] Implement list/create primitives to satisfy tests.
- [ ] Add failing tests for remove behavior command construction and error handling.
- [ ] Implement remove primitive to satisfy tests.

### Acceptance Criteria

- [ ] Service can list/create/remove managed worktrees in deterministic unit tests.
- [ ] Non-managed worktrees are excluded from managed list views.

## Phase 2: Safety Guardrails

### Deliverables

- Safe destroy preflight checks and explicit user-facing failure states
- Recovery path for stale worktree metadata

### Candidate Files

- `apps/swift/Sources/Capacitor/Helpers/WorktreeService.swift`
- `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift` (active-session checks)
- `apps/swift/Tests/CapacitorTests/WorktreeServiceTests.swift`

### Tasks

- [ ] Add failing tests for dirty detection (`git status --porcelain` non-empty => blocked).
- [ ] Add failing tests for active-session guard (block or force-confirm path).
- [ ] Add failing tests for locked-worktree removal behavior.
- [ ] Add failing tests for stale metadata handling (`prune` path before listing/removing).
- [ ] Implement guardrail behavior to satisfy tests.

### Acceptance Criteria

- [ ] Default destroy path blocks unsafe deletion (dirty or active worktree).
- [ ] Guardrail errors are explicit enough to surface in UI without string parsing hacks.

## Phase 3: Workstreams UI

### Deliverables

- Dedicated Workstreams panel in project detail
- Create/open/destroy actions wired to service
- Loading/error/empty states

### Candidate Files

- `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/WorkstreamsPanel.swift` (new)
- `apps/swift/Sources/Capacitor/Models/ProjectDetailsManager.swift` (or new VM)
- `apps/swift/Tests/CapacitorTests/` (view model tests)

### Tasks

- [ ] Add failing tests for panel state model (list loading, errors, action states).
- [ ] Implement panel view model and service integration.
- [ ] Implement create/open actions with optimistic refresh.
- [ ] Add failing tests for destroy flow state transitions.
- [ ] Implement destroy action with guardrail messaging.

### Acceptance Criteria

- [ ] User can create and open a managed worktree from project detail.
- [ ] Destroy flow clearly blocks unsafe deletion and offers actionable next step.

## Phase 4: Integration + Docs

### Deliverables

- End-to-end attribution confidence across lifecycle actions
- Updated planning + changelog + architecture references

### Candidate Files

- `apps/swift/Tests/CapacitorTests/ActiveProjectResolverTests.swift`
- `apps/swift/Tests/CapacitorTests/SessionStateManagerTests.swift`
- `AGENT_CHANGELOG.md`
- `docs/brainstorms/2026-01-25-parallel-workstreams-brainstorm.md`
- `.claude/plans/ACTIVE-workstreams-lifecycle.md` (this file)

### Tasks

- [ ] Add failing integration tests: create worktree -> run attribution path -> destroy guardrail path.
- [ ] Validate no regressions in existing worktree identity tests.
- [ ] Update docs to reflect completed lifecycle support and remaining non-goals.
- [ ] Mark this plan `DONE-` when all acceptance criteria are met.

### Acceptance Criteria

- [ ] Swift + daemon test suites are green.
- [ ] Plan tracker table updated with final statuses and completion date.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Git edge cases produce brittle parsing | High | Keep parser test-heavy with real porcelain fixtures |
| Destroy UX could allow accidental loss | High | Default block + explicit force pathways + clear warnings |
| UI complexity creeps beyond lifecycle scope | Medium | Keep scope to create/list/open/destroy only |

## Definition of Done

- [ ] All four phases marked Done in progress table.
- [ ] All phase acceptance criteria checked.
- [ ] `AGENT_CHANGELOG.md` updated with lifecycle completion entry.
- [ ] Plan file renamed to `DONE-workstreams-lifecycle.md` with compact summary.
