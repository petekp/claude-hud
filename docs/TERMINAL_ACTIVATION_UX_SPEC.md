# Terminal Activation UX Spec (Canonical Contract)

- Canonical path: `docs/TERMINAL_ACTIVATION_UX_SPEC.md`
- Companion manual QA protocol: `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md`
- Status: active
- Last updated: 2026-02-15

## 1. Purpose

This document defines the canonical UX contract for project-card terminal activation.

The contract is normative and testable:

- Runtime behavior MUST match these rules.
- Automated tests MUST map to these rules.
- Manual release-gate QA MUST evaluate against these rules.

## 2. Source-of-Truth Boundary

1. Daemon routing snapshot is the only routing authority consumed by launcher logic.
2. Swift shell-derived fallback architecture is out of scope and MUST NOT be reintroduced.
3. Launching a new terminal window is exceptional fallback behavior, not a primary UX path.

## 3. Hard UX Invariants

### P0 Invariants (release-blocking)

- `UX-I1` One intentful outcome per click: each accepted click produces exactly one final outcome path (`primary` success, or `primary` fail then single fallback).
- `UX-I2` Latest-click-wins: overlapping clicks MUST suppress stale requests; final visible state MUST reflect the latest click.
- `UX-I3` No surprise fan-out: reuse-eligible paths MUST NOT launch new terminal windows.
- `UX-I4` No cross-project bleed: routing evidence from unrelated projects or parent directories MUST NOT select tmux/shell targets for another project.
- `UX-I5` Snapshot-driven determinism: action selection is a pure function of routing snapshot fields plus overlap cancellation state.

### P1 Invariants (must be triaged before release)

- `UX-I6` Ownership continuity: when host ownership is discoverable (TTY/app evidence), activation should focus the owning host terminal context.
- `UX-I7` Graceful fallback: if primary action fails, fallback launch should occur once and remain understandable.
- `UX-I8` Host-hygiene validity: P1 manual evidence is valid only under controlled host baseline (`Ghostty=0, iTerm2=0, Terminal=0`) unless the scenario explicitly requires multiple hosts/windows.

## 4. Decision Tables

### 4.1 Daemon Resolver Scope Contract (cross-project safety)

| Contract ID | Candidate | Accept when | Reject when | Result |
|---|---|---|---|---|
| `R1` | tmux client candidate | Workspace-scoped OR project-path-scoped OR session name exactly equals project slug | None of those scopes are true | If accepted and best-ranked: `status=attached`, `target=tmux_session` |
| `R2` | tmux session candidate | Workspace-scoped OR project-path-scoped OR session name exactly equals project slug | Parent-directory-only or unrelated-path evidence without workspace/session exact match | If accepted and best-ranked: `status=detached`, `target=tmux_session` |
| `R3` | shell fallback candidate | Scope quality > global AND (workspace-scoped OR project-path-scoped child/exact) | Global/unrelated/parent-only shell CWD | If accepted and best-ranked: `status=detached`, `target=terminal_app` or `tmux_session` |
| `R4` | no trusted candidates | No accepted candidates remain | N/A | `status=unavailable`, `target=none`, `reason_code=NO_TRUSTED_EVIDENCE` |

### 4.2 Launcher Snapshot -> Primary Action Contract

| Contract ID | Snapshot condition | Primary action |
|---|---|---|
| `L1` | `target.kind=tmux_session` and `evidence` includes non-empty `tmux_client` | `activateHostThenSwitchTmux(hostTty, sessionName)` |
| `L2` | `target.kind=tmux_session`, no `tmux_client` evidence, `status=attached` | `switchTmuxSession(sessionName)` |
| `L3` | `target.kind=tmux_session`, no `tmux_client` evidence, `status=detached` | `ensureTmuxSession(sessionName, projectPath)` |
| `L4` | `target.kind=terminal_app` and `status in {attached, detached}` | `activateApp(appName)` |
| `L5` | Any other snapshot shape | `launchNewTerminal(projectPath, projectName)` |

### 4.3 Primary Failure -> Fallback Contract

| Contract ID | Condition | Required behavior |
|---|---|---|
| `F1` | Primary action succeeds | Emit success outcome, no fallback launch |
| `F2` | Primary action fails and primary action is not `launchNewTerminal` | Execute exactly one fallback: `launchNewTerminal(projectPath, projectName)` |
| `F3` | Primary action is already `launchNewTerminal` | Do not chain additional fallback |
| `F4` | Snapshot fetch fails and request is still latest | Return to legacy emergency path: launch new terminal once |

### 4.4 Overlap/Concurrency Contract

| Contract ID | Condition | Required behavior | Required stale evidence |
|---|---|---|---|
| `O1` | New click arrives while prior request is in-flight | Prior request becomes stale and must not execute final action/outcome | One of: `ARE snapshot ignored for stale request`, `ARE snapshot request canceled/stale`, `launchTerminalAsync ignored stale request` |
| `O2` | Rapid burst `A -> B -> A` | Only last click (`A`) may execute action/outcome | Stale markers for superseded clicks; no late override by older clicks |
| `O3` | Sequential non-overlap clicks | Each click executes in order | No stale markers required |

### 4.5 Host Ownership and Reuse Contract (`activateHostThenSwitchTmux`)

| Contract ID | Runtime state | Required behavior |
|---|---|---|
| `H1` | tmux client attached + TTY discovery succeeds | Activate owning terminal by TTY, then switch tmux client |
| `H2` | tmux client attached + TTY discovery fails + Ghostty running | Activate Ghostty and switch tmux client (reuse first, no forced launch) |
| `H3` | no tmux client attached + Ghostty running | Activate Ghostty and switch with nil client TTY (reuse first) |
| `H4` | no tmux client attached + Ghostty not running | Launch terminal with tmux |
| `H5` | no discoverable host and no Ghostty fallback | Return failure; upstream `F2` may launch once |

## 5. P0/P1 Scenario Mapping

| Manual scenario | Contract IDs |
|---|---|
| `P0-1` | `L1/L2`, `H1/H2`, `UX-I1`, `UX-I3` |
| `P0-2` | `L1/L2`, `H1/H2`, `UX-I3` |
| `P0-3` | `O3`, `UX-I1`, `UX-I5` |
| `P0-4` | `O1`, `UX-I2` |
| `P0-5` | `O2`, `UX-I2` |
| `P1-1` | `L4` or `L1/L3` + `H3`, `UX-I6` |
| `P1-2` | `L5`, `F1`, `UX-I7` |
| `P1-3` | `L1` when `tmux_client` evidence exists in detached snapshot |
| `P1-4` | `L3`, `F2`, `UX-I7` |
| `P1-5` | `F4`, `UX-I7` |
| `P1-6` | `H2/H3`, `UX-I3`, `UX-I6` |
| `P1-7` | `H1`, `UX-I6` |
| `P1-8` | `H1`, `UX-I6` |

## 5.1 Gap Scenarios To Close

These are additional scenarios that should be explicitly covered to prevent blind spots during refactors.

| Gap ID | Scenario | Intended outcome |
|---|---|---|
| `G1` | Primary non-launch action fails | Exactly one fallback `launchNewTerminal` executes; no duplicate launch path |
| `G2` | Primary action is already `launchNewTerminal` and fails | No retry loop; fail once and surface actionable error |
| `G3` | Snapshot fetch fails during overlapping requests | Only latest request may fallback-launch; stale request must not launch |
| `G4` | Repeated clicks on same card while request in-flight | No churn/fan-out; one coherent final state for that project |
| `G5` | Ghostty process running with zero visible windows | No dead click; recover if possible, else single fallback launch |
| `G6` | Multiple attached tmux clients across different host apps | Select host from winning project-scoped evidence, not arbitrary app choice |
| `G7` | Resolver reports ambiguity/conflict (`ROUTING_CONFLICT_DETECTED`) | Deterministic winner across repeated clicks; no random flip-flop |
| `G8` | Unsupported/unknown terminal owner in evidence | Clean degrade path to supported activation or single fallback; never silent no-op |
| `G9` | Path aliasing edge cases (symlink/case/trailing slash variants) | Stable project identity; no cross-project bleed from normalization mismatch |
| `G10` | Cold-start with empty evidence registries | Timely, understandable fallback outcome; no stall |
| `G11` | OS-level launch failure (permission/script/app missing) | Explicit user-visible failure with actionable guidance |
| `G12` | Delayed host events after final click | No post-action drift; final focus remains aligned with latest click intent |

## 6. P1-3 Mismatch Resolution (Decision)

Current contract decision is **(a) update expectation**:

1. Detached snapshots are not required to retain `tmux_client` evidence.
2. `P1-3` is valid only when detached snapshot actually carries `tmux_client` evidence (`L1`).
3. If detached snapshot has no `tmux_client` evidence, expected behavior is `L3` (`ensureTmuxSession`), not a failure.

This prevents false negatives from evidence lifecycle timing while preserving `L1` behavior when evidence is present.

## 6.1 Counter-Intuitive Outcomes Worth Reconsidering

These are areas where current behavior is technically consistent but may feel surprising to users:

1. `session_name_exact` can outrank path evidence.
   - Risk: a stale but name-matching tmux session may feel like a wrong-context jump.
2. Lexicographic tie-break is deterministic but semantically weak.
   - Risk: deterministic yet unintuitive winner selection under equal candidates.
3. Ghostty fallback with multiple windows activates app-level context without window targeting.
   - Risk: user may still need manual window hunting after click.
4. No-client Ghostty reuse can switch tmux without explicit host TTY.
   - Risk: in dense multi-client environments, result may feel under-specified.
5. Snapshot-unavailable fallback launches a new terminal by design.
   - Risk: under repeated transient daemon errors, this can feel like window churn.

Treat these as product-policy checkpoints before locking stricter release gates.

## 6.2 Adopted Policy Decisions (Current Direction)

These decisions are now the intended product behavior. If implementation diverges, treat as a bug or an intentional policy change requiring spec update.

1. Session-name fallback is constrained.
   - Rule: `session_name_exact` fallback SHOULD be used only when project-scoped path evidence is unavailable and candidate evidence is fresh.
   - UX intent: avoid stale same-name jumps that feel like wrong-project activation.
2. Ambiguity tie-break must be semantically explainable.
   - Rule: resolver SHOULD prefer semantic ranking (freshness/activity/scope quality) before lexical fallback; lexical ordering is last-resort determinism only.
   - UX intent: deterministic outcomes that are also user-legible.
3. Ghostty multi-window behavior remains reuse-first, but must be explicit.
   - Rule: when precise window targeting is unavailable, activation MAY be app-level; this must not trigger new-window fan-out by default.
   - UX intent: predictable reuse over noisy spawning, even when window disambiguation is imperfect.
4. No-client Ghostty reuse should minimize client ambiguity.
   - Rule: when switching without explicit host TTY, implementation SHOULD use the best available client-selection heuristic instead of arbitrary selection.
   - UX intent: reduce “right app, wrong pane/client” outcomes in dense environments.
5. Snapshot-failure fallback should be churn-resistant.
   - Rule: repeated snapshot failures SHOULD be damped (short debounce/circuit-break) to prevent repeated window launches under rapid clicks.
   - UX intent: graceful degradation without launch storms.

## 7. Executable Test Matrix (contract -> tests)

### Resolver tests (daemon)

| Contract IDs | Existing tests |
|---|---|
| `R1/R2` | `resolver_does_not_apply_tmux_session_from_parent_directory`, `resolver_prefers_tmux_session_with_project_name_match` in `core/daemon/src/are/resolver.rs` |
| `D1/D2` | `resolver_does_not_use_stale_session_name_exact_fallback`, `resolver_prefers_project_path_scoped_tmux_session_over_session_name_fallback` in `core/daemon/src/are/resolver.rs` |
| `R3` | `resolver_does_not_apply_shell_fallback_from_unrelated_project_path`, `resolver_does_not_apply_shell_fallback_from_parent_directory`, `resolver_applies_shell_fallback_for_child_directory_of_project` in `core/daemon/src/are/resolver.rs` |
| Ranking determinism (`UX-I5`) | `resolver_prefers_workspace_binding_preferred_session_over_other_candidates`, `resolver_prefers_tmux_signal_over_shell_fallback`, `resolver_uses_lexicographic_tiebreak_for_equal_candidates` in `core/daemon/src/are/resolver.rs` |
| `G7` | `resolver_ambiguity_is_stable_across_repeated_runs` in `core/daemon/src/are/resolver.rs` |
| `G9` | `resolver_treats_trailing_slash_paths_as_exact_match`, `resolver_does_not_assume_case_or_symlink_path_equivalence` in `core/daemon/src/are/resolver.rs` |

### Launcher mapping and overlap tests (Swift)

| Contract IDs | Existing tests |
|---|---|
| `L1` | `testAERoutingActionMappingAttachedTmuxUsesHostThenSwitchWhenClientEvidencePresent`, `testAERoutingActionMappingDetachedTmuxWithClientEvidenceUsesHostThenSwitch` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |
| `L3` | `testAERoutingActionMappingDetachedTmuxEnsuresSession` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |
| `L4` | `testAERoutingActionMappingDetachedTerminalAppActivatesApp` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |
| `L5` | `testAERoutingActionMappingUnavailableLaunchesNewTerminal` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |
| `O1/O2` + `UX-I2` | `testLaunchTerminalOverlappingRequestsOnlyExecutesLatestClick`, `testLaunchTerminalOverlappingRequestsLogsStaleSnapshotMarker` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |
| `O3` | `testLaunchTerminalSequentialRequestsExecuteInOrder` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |
| `F2/F3/F4/D5` | `testLaunchTerminalPrimaryFailureExecutesSingleFallbackLaunch`, `testLaunchTerminalPrimaryLaunchFailureDoesNotChainSecondFallback`, `testLaunchTerminalSnapshotFetchFailureLaunchesFallbackWithSuccessOutcome`, `testLaunchTerminalSnapshotFailureFallbackIsDebouncedAcrossRapidRepeatedClicks` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |
| `UX-I1/G4` | `testLaunchTerminalLatestClickEmitsSingleFinalOutcomeSequence`, `testLaunchTerminalRepeatedSameCardRapidClicksCoalesceToSingleOutcome` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |
| `G8` | `testAERoutingActionMappingDetachedUnknownTerminalAppLaunchesNewTerminal` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |
| `G12` | `testLaunchTerminalStalePrimaryFailureDoesNotLaunchFallbackAfterNewerClick` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |
| `G11` | `testLaunchTerminalSnapshotFailureFallbackLaunchFailureReturnsUnsuccessfulResult` in `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` |

### Host ownership and reuse tests (Swift executor)

| Contract IDs | Existing tests |
|---|---|
| `H1` | `testActivateHostThenSwitchTmuxUsesTtyDiscoveryThenSwitches` in `apps/swift/Tests/CapacitorTests/ActivationActionExecutorTests.swift` |
| `H2` | `testActivateHostThenSwitchTmuxGhosttyFallbackActivatesAppWhenSingleWindow`, `testActivateHostThenSwitchTmuxGhosttyFallbackActivatesAppWhenMultipleWindows` in `apps/swift/Tests/CapacitorTests/ActivationActionExecutorTests.swift` |
| `H3` | `testActivateHostThenSwitchTmuxNoClientAttachedButGhosttyRunningDoesNotSpawnNewWindow`, `testActivateHostThenSwitchTmuxSequentialRequestsReuseExistingGhosttyContext` in `apps/swift/Tests/CapacitorTests/ActivationActionExecutorTests.swift` |
| `H4` | `testActivateHostThenSwitchTmuxLaunchesWhenNoClientAttached` in `apps/swift/Tests/CapacitorTests/ActivationActionExecutorTests.swift` |
| `H5` | `testActivateHostThenSwitchTmuxReturnsFalseWhenNoTtyAndNoGhostty` in `apps/swift/Tests/CapacitorTests/ActivationActionExecutorTests.swift` |
| `D3/D4` | `testActivateHostThenSwitchTmuxGhosttyFallbackActivatesAppWhenMultipleWindows`, `testActivateHostThenSwitchTmuxNoClientAttachedUsesHostTtyHeuristicWhenAvailable` in `apps/swift/Tests/CapacitorTests/ActivationActionExecutorTests.swift` |

### Required additions (currently missing)

None currently from the `D*`, `F*`, and `G*` items tracked in this spec revision.

## 8. Logging Contract for Assertions

Tests and manual evidence should key off these markers in `~/.capacitor/daemon/app-debug.log`:

- Action execution: `[TerminalLauncher] executeActivationAction action=...`
- Host switch path: `[TerminalLauncher] activateHostThenSwitchTmux ...`
- Ensure path: `[TerminalLauncher] ensureTmuxSession ...`
- Launch fallback: `[TerminalLauncher] launchNewTerminal ...`
- Stale suppression: `[TerminalLauncher] ARE snapshot request canceled/stale ...` and/or `[TerminalLauncher] ARE snapshot ignored for stale request ...`

## 9. Change Policy

When behavior changes:

1. Update this spec first.
2. Update/add automated tests to satisfy affected contract IDs.
3. Re-run canonical manual QA protocol and attach evidence artifact.
4. Update `docs/PRE_RELEASE_CHECKLIST.md` if release-gate criteria changed.
