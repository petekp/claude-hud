# Feedback Synthesis: Terminal Activation System Code Review

**Created:** 2026-01-27
**Sources:** 5 independent AI model reviews
**Implementation Plan:** `.claude/plans/ACTIVE-terminal-activation-fixes.md`

## Executive Summary

Five independent code reviews converged on critical issues in the terminal activation system: **silent failures masking errors** (especially tmux and IDE CLI), **shell injection vulnerabilities** in session name handling, and **race conditions** between state queries and action execution. All models agree the architecture is sound but error handling is too permissive, defeating the fallback mechanism design.

## Consensus Items (Multiple Models Agree)

| Item | Models | Priority | Status |
|------|--------|----------|--------|
| **Tmux `switch-client` silently fails and always returns `true`** | 1, 2, 3, 4, 5 | Critical | ⬜ |
| **IDE CLI activation fails silently (`try? process.run()`)** | 1, 2, 4, 5 | Critical | ⬜ |
| **Shell injection risk in session name interpolation** | 3, 5 | Critical | ⬜ |
| **Tmux client race: `has_attached_client` can become stale** | 1, 2, 3, 5 | High | ⬜ |
| **Ghostty window count race: check-then-act pattern fragile** | 1, 2, 4, 5 | High | ⬜ |
| **Timestamp comparison uses string comparison (fragile)** | 1, 2, 3, 5 | Medium | ⬜ |
| **AppleScript calls are fire-and-forget (no error checking)** | 1, 2, 3, 5 | Medium | ⬜ |
| **Path matching doesn't handle symlinks** | 2, 5 | Medium | ⬜ |
| **Dead process filtering happens before Rust sees data** | 1, 2, 3 | Medium | ⬜ |
| **`findTmuxSessionForPath` uses exact match, not subdirectory** | 2, 3, 5 | Medium | ⬜ |

## Model-Specific Insights

### Unique from Model 1
- [ ] Process liveness race (`kill(pid, 0)`) can misclassify if process exits between check and activation
- [ ] Missing tests for corrupted/missing shell state files
- [ ] State freshness guarantees: consider adding validity timestamps to queries

### Unique from Model 2
- [ ] Path matching false positive: `/project-foo/src` incorrectly matches `/project` due to symmetric prefix logic
- [ ] `paths_match` returns `true` for parent→child AND child→parent (can pick wrong project with nested paths)

### Unique from Model 3
- [ ] **`tmux_client_tty` captured by hook can be wrong with multiple clients** — uses `list-clients` first line instead of `display-message -p "#{client_tty}"`
- [ ] **Ghostty strategy activates Ghostty even when tmux client is in iTerm** — gates on "Ghostty running" not "host TTY belongs to Ghostty"
- [ ] Double fallback execution: TTY discovery failure triggers local fallback AND Rust fallback (UI flashing)
- [ ] IDE activation uses `shell.cwd` (subdir) instead of clicked project path
- [ ] Debug "matrix" UI describes strategies Rust resolver no longer uses (documentation hazard)

### Unique from Model 4
- [ ] `LaunchTerminalWithTmux` ignores `project_path` — only attempts attach, no create-if-missing
- [ ] Rename `LaunchTerminalWithTmux` to `EnsureTmuxSession` for clarity

### Unique from Model 5
- [ ] `tmux_client_tty` can be stale after client reconnects from different terminal
- [ ] Ghostty session cache could leak memory (unbounded `recentlyLaunchedGhosttySessions`)
- [ ] Missing test for case-insensitive filesystem behavior
- [ ] Missing test for paths with `..` segments or double slashes

## Conflicts & Divergences

| Topic | Model 4 Says | Models 1, 2, 3, 5 Say | Resolution |
|-------|--------------|----------------------|------------|
| **Dead process filtering location** | Filtering in Swift is "correct" — keeps Rust pure | Pass `is_live` flag to Rust for better decisions | **Pass flag to Rust** — allows smarter fallback logic |
| **Timestamp comparison reliability** | "Reliable" if producers use consistent formatting | "Fragile" — format drift, timezone issues possible | **Parse to DateTime** — defensive approach is safer |
| **Process liveness check** | "Sufficient" — PID+path collision negligible | Race condition exists; handle `EPERM` as alive | **Add debug logging** — low priority, fallback handles it |

## Implementation Checklist

### Critical (Address First)
- [ ] **Fix tmux `switch-client` return value** — check exit code, return `false` on failure — Source: All models
- [ ] **Fix IDE CLI activation** — wait for process, check `terminationStatus` — Source: 1, 2, 4, 5
- [ ] **Shell-escape or validate session names** — prevent injection via `'` characters — Source: 3, 5
- [ ] **Fix multi-client tmux hook** — use `display-message -p "#{client_tty}"` not `list-clients` first line — Source: 3

### Important (Address Soon)
- [ ] **Re-verify tmux client before switching** — check `hasTmuxClientAttached()` in executor — Source: 1, 2, 5
- [ ] **Make AppleScript calls return success/failure** — capture exit status and stderr — Source: 1, 2, 3, 5
- [ ] **Use subdirectory matching in `findTmuxSessionForPath`** — align with Rust `paths_match` — Source: 2, 3, 5
- [ ] **Pass `is_live` flag in `ShellEntryFfi`** — let Rust make smarter decisions — Source: 1, 2, 3
- [ ] **Determine host terminal before choosing Ghostty strategy** — don't assume Ghostty if it's just running — Source: 3
- [ ] **Fix `LaunchTerminalWithTmux` to use `project_path`** — create session if missing — Source: 4

### Nice to Have
- [ ] Parse timestamps to `DateTime<Utc>` in Rust — Source: 2, 5
- [ ] Resolve symlinks before path comparison — Source: 2, 5
- [ ] Add confidence level to `ActivationDecision` — Source: 2, 5
- [ ] Cap `recentlyLaunchedGhosttySessions` cache size — Source: 5
- [ ] Expose Rust `paths_match` via UniFFI for Swift — Source: 2
- [ ] Add `TmuxSessionInfo` struct with per-session client info — Source: 5
- [ ] Consider `ActivationResult` enum instead of `Bool` — Source: 1, 2, 5

## Testing Gaps to Address

| Test Category | Models | Priority |
|--------------|--------|----------|
| Shell injection (malicious session names) | 5 | Critical |
| Tmux client detachment race | 1, 2, 3 | High |
| Multiple tmux clients | 3 | High |
| Symlink handling | 2, 5 | High |
| Stale `tmux_client_tty` after reconnect | 3, 5 | High |
| Multiple Ghostty windows at different paths | 1, 5 | High |
| IDE CLI not in PATH / failure | 1, 2 | Medium |
| AppleScript failure modes (permissions, timeouts) | 1, 2, 5 | Medium |
| Timestamp format variance (fractional seconds, timezones) | 1, 2, 5 | Medium |
| Path edge cases (`..`, double slashes, case sensitivity) | 2, 5 | Medium |
| Integration: Swift → Rust → Swift roundtrip | 1, 5 | Medium |

## Questions to Resolve

- [ ] **Should Rust see all shells (with `is_live` flag) or only live ones?** — Models split; recommend passing all with flag
- [ ] **Is symmetric `paths_match` intentional?** — `/repo` matching `/repo/app` both ways can pick wrong terminal
- [ ] **Should IDE activation use clicked project path or `shell.cwd`?** — Model 3 notes this can focus wrong window
- [ ] **What to do when multiple Ghostty windows exist?** — Launch new? Prompt user? Document limitation?
- [ ] **Should the debug "matrix" UI be removed or synced with actual Rust logic?** — Model 3 notes it's out of date
