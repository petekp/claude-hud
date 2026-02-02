<!-- @task:daemon-migration @load:migration -->
# Daemon Migration (Status + Invariants)

## Invariants (Do Not Break)
- Daemon-only: no file fallbacks for state
- Single writer: daemon owns state
- Exact-path session correctness (no parent inheritance)
- Activity is secondary (never override explicit session state)
- Lock deprecation is safe (don’t delete existing locks blindly)

## Current Status (High Level)
- Daemon is authoritative for sessions/shell/activity/liveness
- Hooks + Swift are IPC clients
- Legacy JSON + locks are deprecated and should not be used as source of truth

## Remaining Work (Typical)
- Harden session heuristics for stuck Working/Ready
- Reduce UI polling/jank
- Remove or disable any remaining legacy cleanup paths
- Stabilize debug build launch workflow

## Canonical Plan
- `docs/plans/2026-01-30-daemon-architecture-migration-plan.md`
- `docs/architecture-decisions/005-daemon-based-state-service.md`

