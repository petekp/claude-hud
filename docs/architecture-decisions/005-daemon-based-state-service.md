# ADR-005: Adopt Daemon-Based State Service (Single Writer + SQLite)

**Status:** Accepted

**Date:** 2026-01-30

**Context:** Pre-alpha reliability hardening and audit findings (multi-writer JSON races, inconsistent liveness checks, silent state wipes).

## Why this ADR exists

Recent audits identified structural fragility in the current file-based state pipeline:

- Multiple processes perform **read-modify-write** on shared JSON files (`sessions.json`, `file-activity.json`).
- PID liveness is verified inconsistently across subsystems (cleanup vs lock logic).
- Corrupt or partially-written state files can lead to **silent resets**.
- Non-atomic lock metadata writes can create inconsistent lock directories.

These are **architectural** risks, not just bugs. Incremental fixes reduce but do not eliminate systemic race conditions.

## Decision drivers

We will prioritize an architecture that:

- **Eliminates multi-writer shared mutable state**.
- **Provides transactional persistence** and crash recovery.
- **Centralizes liveness checks** in one place.
- **Preserves current CLI workflows** (`claude`, `codex`, hooks) without user-visible changes.
- **Supports staged migration** with safe fallback.
- **Maintains sidecar boundaries** (read from `~/.claude/`, write to `~/.capacitor/`).

## Considered options

### Option A: Harden existing JSON files

- Add file locks, merge logic, and backup/quarantine on parse failure.
- Pros: low implementation overhead, minimal new components.
- Cons: still multi-writer, hard to fully remove race conditions, difficult to reason about.

### Option B: Per-session event logs (ADR-004)

- Replace global files with per-session directories and append-only logs.
- Pros: reduces shared state; simpler recovery; deterministic session boundaries.
- Cons: still multi-writer at the event-log level; no centralized liveness or transactional query layer.

### Option C: Local daemon + transactional store (SQLite WAL)

- A local daemon becomes the **single writer** and query authority.
- Hooks and the app become **clients** via IPC (Unix socket).
- State persists in SQLite; event log is append-only for replay.
- Pros: single writer, atomic persistence, centralized liveness, easier testing.
- Cons: added operational complexity (daemon lifecycle), needs launchd integration.

## Decision

Adopt **Option C**: build a local **daemon-based state service** with **SQLite WAL** as the primary store. Hooks and the app will send events or queries via IPC. The daemon is the sole writer of state.

## Rationale

This is the only option that **structurally removes** multi-writer races while preserving the existing user workflow. It also creates a clear boundary where correctness and liveness logic can be centralized, which is critical for pre-alpha reliability.

## Consequences

### Positive

- **Single-writer architecture** eliminates file-write races.
- **Transactional persistence** prevents state wipes on corruption.
- **Centralized liveness** logic reduces PID reuse and cleanup inconsistencies.
- **Easier recovery** (replay events to rebuild state).
- **Simpler mental model** for future contributors.

### Negative

- Requires a **background daemon** (launchd + health checks).
- Introduces **IPC failure modes** (daemon unavailable or hung).
- Requires **migration tooling** and new test surface.

### Risks & mitigations

- **Daemon unavailable**: hooks/app fall back to file-based mode during migration.
- **Crash loops**: launchd backoff + health UI.
- **Schema evolution**: versioned IPC + database migrations.

## Implementation notes

- **Transport:** Unix domain socket (e.g., `~/.capacitor/daemon.sock`).
- **Storage:** SQLite WAL + append-only `events` table for replay.
- **Identity:** session records keyed by `session_id + pid`.
- **Fallback:** hooks write JSON only when daemon is unreachable (until deprecation phase).
- **Launch:** install LaunchAgent to auto-start at login.
- **Visibility:** Setup/Diagnostics should show daemon status and version.

## Migration plan

See `docs/plans/2026-01-30-daemon-architecture-migration-plan.md` for the staged, end-to-end plan.

## Related decisions

- ADR-003: Sidecar Architecture Pattern
- ADR-004: Simplify State Storage (Superseded by this ADR)

