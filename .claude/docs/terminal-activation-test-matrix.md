# Terminal Activation Test Matrix

This document defines ALL scenarios that must work correctly for terminal activation. Every change to `activation.rs` or `TerminalLauncher.swift` must be validated against this matrix.

## The Problem We're Solving

Terminal activation has two layers:
1. **Rust Decision Layer** (`activation.rs`) — Pure logic, well-tested (50+ unit tests)
2. **Swift Execution Layer** (`TerminalLauncher.swift`) — Side effects + adapters; unit tests cover helpers/executor, but end-to-end activation is still manual

Decisions are based on the daemon shell snapshot (`get_shell_state`) plus tmux context; legacy files are non-authoritative.

Every bug in the past week has been in the Swift layer or in the interface between layers. We keep making fixes that break other scenarios because we don't have systematic test coverage.

## Test Matrix Structure

Each scenario defines:
- **Preconditions**: System state before clicking
- **Action**: Click project X in Capacitor
- **Expected Outcome**: What should happen
- **Rust Decision**: What `resolve_activation()` should return
- **Swift Execution**: What `executeActivationAction()` should do

---

## Scenario Categories

### Category A: Single Ghostty Window with Tmux

| ID | Precondition | Action | Expected Outcome | Status |
|----|--------------|--------|------------------|--------|
| A1 | 1 Ghostty window, tmux attached, viewing `capacitor` session | Click `capacitor` | Ghostty activates, stays on capacitor | ✅ |
| A2 | 1 Ghostty window, tmux attached, viewing `hapax` session | Click `capacitor` | Ghostty activates, tmux switches to capacitor | ✅ |
| A3 | 1 Ghostty window, tmux attached, viewing `capacitor` session | Click `hapax` | Ghostty activates, tmux switches to hapax | ✅ |
| A4 | 1 Ghostty window, tmux attached, viewing `hapax` session | Click `hapax` | Ghostty activates, stays on hapax | ✅ |

### Category B: Multiple Ghostty Windows with Tmux

| ID | Precondition | Action | Expected Outcome | Status |
|----|--------------|--------|------------------|--------|
| B1 | 2 Ghostty windows, tmux in window 1, viewing `capacitor` | Click `capacitor` | Launch new Ghostty window (tmux attach) to avoid wrong window | ⬜ |
| B2 | 2 Ghostty windows, tmux in window 1, viewing `hapax` | Click `capacitor` | Launch new Ghostty window (tmux attach) to avoid wrong window | ⬜ |
| B3 | 2 Ghostty windows, tmux in window 1, viewing `capacitor` | Click `hapax` | Launch new Ghostty window (tmux attach) to avoid wrong window | ⬜ |

**Known Limitation**: Ghostty has no API to focus a specific window. With multiple windows, tmux activation may launch a new window to guarantee the right session; direct-shell activation may still require manual window switching.

### Category C: No Ghostty Windows / No Terminal

| ID | Precondition | Action | Expected Outcome | Status |
|----|--------------|--------|------------------|--------|
| C1 | Ghostty not running, tmux session `capacitor` exists | Click `capacitor` | New Ghostty window opens, attaches to capacitor | ✅ |
| C2 | No terminal running, no tmux | Click `capacitor` | New terminal opens at capacitor path | ⬜ |
| C3 | Ghostty running but 0 windows (edge case) | Click `capacitor` | New Ghostty window opens | ⬜ |

### Category D: Tmux Client State Transitions

| ID | Precondition | Action | Expected Outcome | Status |
|----|--------------|--------|------------------|--------|
| D1 | Tmux client attached (any session), click project | Click different project | Tmux switches session; no new window unless Ghostty multi-window fallback triggers new window | ⬜ |
| D2 | Tmux client was attached, then detached | Click project | New terminal window opens to attach | ✅ |
| D3 | Tmux server running, no clients attached | Click project with session | New terminal window opens to attach | ✅ |

### Category E: Multiple Shells at Same Path

| ID | Precondition | Action | Expected Outcome | Status |
|----|--------------|--------|------------------|--------|
| E1 | 3 shells for `capacitor`: 1 tmux, 2 direct; tmux client attached | Click `capacitor` | Uses tmux shell, switches session | ✅ |
| E2 | 3 shells for `capacitor`: 1 tmux, 2 direct; no tmux client | Click `capacitor` | Launches new terminal (or uses most recent?) | ⬜ |
| E3 | 2 shells: recent non-tmux, old tmux; tmux client attached | Click project | Uses tmux shell (despite being older) | ✅ |

### Category F: Non-Ghostty Terminals

| ID | Precondition | Action | Expected Outcome | Status |
|----|--------------|--------|------------------|--------|
| F1 | iTerm with tmux attached | Click project | TTY discovery → activate iTerm tab, switch tmux | ⬜ |
| F2 | Terminal.app with tmux attached | Click project | TTY discovery → activate Terminal tab, switch tmux | ⬜ |
| F3 | Ghostty AND iTerm running, tmux in iTerm | Click project | TTY discovery finds iTerm, NOT Ghostty | ⬜ |

---

## How to Run Manual Tests

### Setup for Testing

```bash
# Create test tmux sessions
tmux new-session -d -s capacitor -c ~/Code/capacitor
tmux new-session -d -s hapax -c ~/Code/hapax

# Attach to one session
tmux attach -t capacitor
```

### Test Procedure

For each scenario:
1. Set up preconditions
2. Click the project card in Capacitor
3. Record actual outcome
4. Compare to expected outcome
5. Mark status: ✅ (pass), ❌ (fail), ⬜ (not tested)

### Recording Results

After testing, update this document with:
- Status column
- Any notes about unexpected behavior
- Commit hash when tested

---

## Critical Invariants

These must ALWAYS be true:

1. **Avoid spawning new windows when a tmux client is attached somewhere**
   - Exceptions: the client detached between decision and execution, or Ghostty has multiple windows and TTY discovery fails (launch new to avoid wrong window)

2. **Tmux session switching must work regardless of which session is currently viewed**
   - Clicking `capacitor` while viewing `hapax` MUST switch to capacitor

3. **TTY discovery takes precedence over Ghostty heuristics**
   - If we can identify the terminal via TTY, use that—even if Ghostty is also running

4. **Shell selection prefers tmux shells when tmux client is attached**
   - Ensures `ActivateHostThenSwitchTmux` is chosen over `ActivateByTty`

---

## Regression Checklist

Before merging any terminal activation change:

- [x] A1-A4 pass (single Ghostty window scenarios) — v0.1.25
- [ ] B1-B3 pass (multiple Ghostty windows) — re-test after Ghostty multi-window fallback change
- [ ] D1 passes (no new window when TTY activation succeeds) — re-test after Ghostty multi-window fallback change
- [x] E3 passes (tmux shell preferred when client attached) — v0.1.25
- [ ] F3 passes (TTY discovery over Ghostty heuristics) — requires iTerm

---

## Test Automation Plan

### Phase 1: Mock Infrastructure
- ✅ Extracted system queries into protocols (`ActivationActionDependencies`, `TmuxClient`, `TerminalDiscovery`)
- ✅ Added adapter-based injection in `TerminalLauncher`

### Phase 2: Scenario Tests
- ✅ Added unit tests for `ActivationActionExecutor` routing + Ghostty window decision
- ⬜ Expand to cover the full matrix (tmux + IDE + kitty + fallback paths)

### Phase 3: Integration Tests
- ⬜ AppleScript-driven end-to-end tests (still manual)

---

## History

| Date | Change | Tested Scenarios | Result |
|------|--------|------------------|--------|
| 2026-01-28 | Initial matrix creation | — | — |
| 2026-01-28 | v0.1.25: shell selection + client detection fixes | A1-A4, B1-B3, C1, D1-D3, E1, E3 | All pass ✅ |

Note: Results above predate the Ghostty multi-window fallback change; re-test B1-B3 and D1 under current behavior.
