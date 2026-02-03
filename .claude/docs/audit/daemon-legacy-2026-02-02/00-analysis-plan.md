# Daemon Legacy/Dead Code Audit Plan (2026-02-02)

## Scope
Audit for legacy, dead, or irrelevant code after daemon-only migration (no back-compat). Focus is on residual file-based state, lock compatibility, and stale docs/tests.

## Pre-analysis sweep
- **TODO/FIXME/HACK search:** No runtime TODO/FIXME/HACK entries found outside docs; nothing flagged as intentional debt in core modules.
- **Recent commits (context):**
  - `e2fea10` Fix tmux activation and terminal focus
  - `de50ca6` Prefer activating existing terminal before launching new
  - `cfd15da` Remove duplicate daemon status card
  - `97eed0c` Merge daemon-migration-phase-1 into main
  - `f1766b0` Daemon: keep Ready state; POSIX IPC only
  - `2a2ae36` Sync daemon binary in debug restart script
  - `9af1952` Use updated_at for ready staleness
- **Doc sweep:** `CLAUDE.md` + `README.md` still describe JSON/lock fallbacks and lock-based resolution despite daemon-only posture.

## Subsystem table

| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Daemon Core + Protocol | `core/daemon/**`, `core/daemon-protocol/**` | IPC, SQLite, process liveness | High |
| 2 | Hook Ingestion | `core/hud-hook/**` | IPC, filesystem heartbeat | High |
| 3 | Hud Core State/Activation | `core/hud-core/**` | IPC, cleanup of legacy processes | High |
| 4 | Swift App State/Activation | `apps/swift/Sources/Capacitor/**` | App UX, activation behavior | High |
| 5 | Tests (legacy harnesses) | `core/hud-core/tests/**`, `tests/hud-hook/**` | CI/test correctness | Medium |
| 6 | Scripts + Top-level Docs | `scripts/**`, `README.md`, `CLAUDE.md` | Developer guidance | Medium |

## Method
- Analyze each subsystem in priority order.
- Identify legacy/dead paths and stale docs tied to file-based state or lock compatibility.
- Provide evidence, impact, and recommended action.

