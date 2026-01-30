# Meta-Analysis: Pre-Alpha Audit Context (Synthesized)

This document is a **meta-analysis** synthesizing multiple model outputs, verified against the current codebase. It is not a new audit; it consolidates and validates prior agent findings.

## Summary
- Verified recent hook + activation audit fixes directly in code; most model claims are accurate.
- Confirmed eight remaining risks in state persistence, cleanup liveness, activity logging, lock metadata, and settings updates.
- Two claims were incorrect; several others are runtime-only and need test verification.

## Verified Fixes (Code-Confirmed)
| Fix | Evidence | Models |
|---|---|---|
| Heartbeat only touched after valid event + session_id + tombstone gate | `core/hud-hook/src/handle.rs` (`handle_hook_input_with_home`/`touch_heartbeat`) | 2,4,5,6 |
| Hook test no longer writes live `sessions.json`; uses isolated temp file + regression test | `core/hud-core/src/engine.rs` (`test_state_file_io`) + test | 2,4,6 |
| Session lock PID-reuse guard refreshes metadata using `proc_started` | `core/hud-core/src/state/lock.rs` (`create_session_lock`) | 2,4,6 |
| Hook writes native `activity` and migrates legacy `files` on write | `core/hud-hook/src/handle.rs` (`record_file_activity`); `core/hud-core/src/activity.rs` | 2,4,5,6 |
| IDE activation has fallback and Swift executes it on failure | `core/hud-core/src/activation.rs` (`resolve_for_existing_shell`); `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` | 2,4,5,6 |
| tmux lookup is literal (`awk`) and tmux commands use `$SESSION` without extra quoting | `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` | 2,4,5,6 |
| GUI shell detection falls back to login shell | `apps/swift/Sources/Capacitor/Models/ShellSetupInstructions.swift` | 2,4,5,6 |
| macOS path normalization lowercases for matching | `core/hud-core/src/state/path_utils.rs` | 2,4,5,6 |

## Confirmed Issues / Risks (Still Present)
| Issue | Severity | Evidence | Models |
|---|---|---|---|
| Parse/unsupported `sessions.json` returns empty store (silent state wipe) | High | `core/hud-core/src/state/store.rs` (`StateStore::load`) | 1 |
| Single `SessionRecord` per `session_id` is last-writer-wins (multi-shell flapping risk) | Medium | `core/hud-core/src/state/store.rs` (`StateStore::update`) + shared session_id in `core/hud-core/src/state/lock.rs` | 1 |
| Cleanup liveness uses PID-only (ignores `proc_started`) | Medium | `core/hud-core/src/state/cleanup.rs` (`cleanup_stale_locks`, `collect_active_session_ids`) | 1 |
| Activity file is RMW without cross-process lock (lost entries) | Medium | `core/hud-hook/src/handle.rs` (`record_file_activity`) | 1 |
| Lock metadata writes are non-atomic | Medium | `core/hud-core/src/state/lock.rs` (`write_lock_metadata`) | 1 |
| `is_pid_alive_verified` trusts PID if start time lookup fails | Low | `core/hud-core/src/state/lock.rs` (`is_pid_alive_verified`) | 1 |
| Lock-holder exits after 24h without releasing lock | Low | `core/hud-hook/src/lock_holder.rs` (`MAX_LIFETIME_SECS`) | 1 |
| settings.json update is atomic but TOCTOU RMW window remains | Low | `core/hud-core/src/setup.rs` (`register_hooks_in_settings`) | 2,4 |

## Refuted Claims
| Claim | Source | Reality |
|---|---|---|
| Shell CWD history compaction never invoked | 2 | `core/hud-hook/src/cwd.rs` calls `maybe_cleanup_history` every run with 1% probability |
| IDE fallback with tmux creates a new tmux session | 2 | Fallback is `SwitchTmuxSession` when a tmux session exists; otherwise `LaunchNewTerminal` (`core/hud-core/src/activation.rs`) |

## Unverifiable Claims (Need Runtime/Tests)
- “Targeted Rust tests pass” (6) — not run in this synthesis.
- “Systems are production/alpha-ready” (3,5) — subjective; needs QA.
- “AppleScript failures only logged (no user surface)” (2) — requires UI verification.
- “Cleanup race is app-launch only / self-heals” (4) — needs trace-level validation.

## Conflicts Resolved
| Topic | Model A | Model B | Verdict | Evidence |
|---|---|---|---|---|
| “Lock == liveness (PID+proc_started) everywhere” | 2/4/6 (implied) | 1 | Not globally enforced; cleanup still PID-only | `core/hud-core/src/state/cleanup.rs` vs `core/hud-core/src/state/lock.rs` |
| “Shell history cleanup never runs” | 2 | code | False; runs probabilistically | `core/hud-hook/src/cwd.rs` |

## Consensus Recommendations (Verified + Multi-Model)
- Add corruption handling for `sessions.json` (backup/quarantine + restore path). Evidence `core/hud-core/src/state/store.rs`. Models 1,2,4,6.
- Use `is_pid_alive_verified` in cleanup to avoid PID-reuse false positives. Evidence `core/hud-core/src/state/cleanup.rs`. Models 1,2,4,6.
- Add concurrency-safe activity logging (file lock or append-only). Evidence `core/hud-hook/src/handle.rs`. Models 1,2,4,6.
- Make lock metadata writes atomic. Evidence `core/hud-core/src/state/lock.rs`. Models 1,2.
- Strengthen Swift activation regression testing (protocol-backed mocks). Evidence `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`. Models 2,4,6.

## Unique Insights Worth Considering
- Swift UI state reconciliation for simultaneous `sessions.json` + `shell-cwd.json` updates (5).
- FFI error propagation to user-visible toasts (5).
- Docs drift cleanup for audit maps (6).

## Action Items

### Critical
- [ ] Add `sessions.json` corruption handling to avoid silent wipes. Evidence `core/hud-core/src/state/store.rs`.
- [ ] Align cleanup liveness with `is_pid_alive_verified`. Evidence `core/hud-core/src/state/cleanup.rs`.

### Important
- [ ] Add concurrency-safe activity logging (lock or append-only). Evidence `core/hud-hook/src/handle.rs`.
- [ ] Make lock metadata writes atomic (temp file + rename or ordered fsync). Evidence `core/hud-core/src/state/lock.rs`.
- [ ] Decide lock-holder timeout mitigation (handoff or cleanup scheduling). Evidence `core/hud-hook/src/lock_holder.rs`.
- [ ] Add mtime/hash retry to settings update to reduce TOCTOU. Evidence `core/hud-core/src/setup.rs`.
- [ ] Build minimal Swift activation test harness for fallback + tmux paths. Evidence `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`.

### Suggested
- [ ] Review UI state flicker under concurrent updates (5).
- [ ] Surface AppleScript failures to users (2).
- [ ] Consolidate invariants into a single runtime-invariants doc (2).
