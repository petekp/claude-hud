# Terminal Activation Manual Testing Guide (Canonical)

This is the **single canonical manual QA guide** for terminal activation behavior.

- Canonical path: `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md`
- Canonical UX contract: `docs/TERMINAL_ACTIVATION_UX_SPEC.md`
- Scope: project-card click activation behavior in Capacitor alpha
- Status: active
- Last updated: 2026-02-15

Legacy matrix docs under `.claude/docs/` are compatibility pointers only and should not be updated with test steps.

## Why This Exists

Terminal activation has strong automated coverage, but user-facing correctness still depends on real terminal/window behavior:

- app/window focus behavior
- tmux client attach/switch behavior under real usage
- rapid and overlapping click feel (deterministic, no window fan-out unless required)

## Ground Rules

1. **Reuse existing terminal context first.**
2. **New terminal windows are exceptional fallback behavior.**
3. **Rapid overlapping clicks are latest-click-wins.**
4. **Daemon routing snapshot is source of truth** for status/target decisions.

## UX Success Criteria

Manual QA is not only “did the command execute,” but also “did this feel reliable to a real user.”

1. **One-click confidence:** A click should feel acknowledged immediately and produce a predictable result.
2. **Context continuity:** Users should stay oriented in the same terminal context whenever possible.
3. **No surprise fan-out:** New terminal windows should only appear when reuse paths are genuinely unavailable.
4. **Last intent wins under speed:** During rapid clicks, final visible state must match the most recent click.
5. **No post-action drift:** Focus should not jump again after the final intended state is reached.

## Supported Alpha Surface

Manual QA release gate applies to:

- Ghostty
- iTerm2
- Terminal.app

Other terminals/IDE-integrated terminals are out-of-scope for alpha release gating.

## Preflight Setup

1. Build and run Capacitor in alpha mode.

```bash
./scripts/dev/restart-app.sh --channel alpha
```

2. Ensure daemon is healthy.

```bash
launchctl print gui/$(id -u)/com.capacitor.daemon | rg "state =|pid ="
ls -la ~/.capacitor/daemon.sock
```

3. Ensure target projects are pinned in the app (at least two projects, e.g. `project-a`, `project-b`).

4. Prepare tmux sessions for those projects.

```bash
tmux new-session -d -s project-a -c /absolute/path/to/project-a
tmux new-session -d -s project-b -c /absolute/path/to/project-b
```

5. (Optional but recommended) start Transparent UI for telemetry visibility.

```bash
scripts/run-transparent-ui.sh
```

6. **Host Hygiene Gate (required for P1 assertions)**

Before running P1 scenarios, enforce a controlled host baseline to avoid cross-terminal contamination:

```bash
# Count visible windows by terminal app
osascript <<'APPLESCRIPT'
tell application "System Events"
  set ghosttyCount to 0
  set itermCount to 0
  set terminalCount to 0
  if exists process "Ghostty" then set ghosttyCount to count of windows of process "Ghostty"
  if exists process "iTerm2" then set itermCount to count of windows of process "iTerm2"
  if exists process "Terminal" then set terminalCount to count of windows of process "Terminal"
  log ("Ghostty=" & ghosttyCount)
  log ("iTerm2=" & itermCount)
  log ("Terminal=" & terminalCount)
  log ("Total=" & (ghosttyCount + itermCount + terminalCount))
end tell
APPLESCRIPT

# Count terminal host processes (window/process fan-out confounder)
ps aux | rg -i '/Applications/Ghostty.app/Contents/MacOS/ghostty|/Applications/iTerm.app/Contents/MacOS/iTerm2|/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal' | rg -v 'rg -i'
```

Pass/fail rule for valid P1 evidence:

- Preferred: exactly one intended host app/window.
- Acceptable: additional windows only if scenario explicitly requires them (P1-6/7/8).
- Invalid run: uncontrolled terminal density (many unrelated host windows/processes) with no isolation strategy.

If environment is noisy, isolate with a temporary unique fixture project path and rerun.

## Log Capture Protocol (Required)

For every manual run, capture a clean log slice from `~/.capacitor/daemon/app-debug.log`.

1. Insert a start marker before test actions.

```bash
printf "\n[MANUAL-TEST][START] terminal-activation %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ~/.capacitor/daemon/app-debug.log
```

2. Execute test scenarios.

3. Insert an end marker.

```bash
printf "[MANUAL-TEST][END] terminal-activation %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ~/.capacitor/daemon/app-debug.log
```

4. Extract and review relevant events.

```bash
rg -n "MANUAL-TEST|TerminalLauncher\]|activateHostThenSwitchTmux|switchTmuxSession|ensureTmuxSession|launchNewTerminal|ARE snapshot request canceled/stale|ARE snapshot ignored for stale request|launchTerminalAsync ignored stale request|executeActivationAction" ~/.capacitor/daemon/app-debug.log
```

## Test Matrix

Use this matrix in order. Every P0 scenario must pass before merge/release.

### P0: Deterministic Core Behavior

| ID | Scenario | Setup | Action | Expected UI/Behavior | Expected Log Signals | Forbidden Signals |
|---|---|---|---|---|---|---|
| P0-1 | Attached client, same session | One terminal window with tmux client attached to `project-a` | Click `project-a` card | Existing window stays focused; no extra window | `activateHostThenSwitchTmux` or `switchTmuxSession` | `launchNewTerminal` |
| P0-2 | Attached client, switch session | Same window, currently viewing `project-a` | Click `project-b` card | In-place tmux switch to `project-b`; no fan-out | `activateHostThenSwitchTmux ... session=project-b` | `launchNewTerminal` |
| P0-3 | Sequential clicks | Attached client; one terminal window | Click `project-a`, then after ~0.5s click `project-b` | Deterministic switch each click, no extra windows | Two activation actions, ordered by click | Any unexpected launch |
| P0-4 | Rapid overlapping clicks (latest wins) | Attached client; one terminal window | Click `project-a` then very quickly `project-b` (<200ms) | Final state lands on `project-b`; older request does not override | Any stale suppression marker for the older click: `ARE snapshot request canceled/stale` or `ARE snapshot ignored for stale request` or `launchTerminalAsync ignored stale request` | Older click re-executes after newer click |
| P0-5 | Rapid burst (A→B→A) | Attached client; one terminal window | Three fast clicks in succession | Final state matches last click (`A`) | Stale/canceled logs for superseded clicks | `launchNewTerminal` |

### P1: Fallback and Detached Cases

| ID | Scenario | Setup | Action | Expected UI/Behavior | Expected Log Signals | Forbidden Signals |
|---|---|---|---|---|---|---|
| P1-1 | No tmux client, Ghostty running | Ghostty running with existing tmux session, no attached client | Click project card | Reuse Ghostty context (`activate + switch`), no new window | `activateHostThenSwitchTmux` + switch success | `launchTerminalWithTmux` unless switch impossible |
| P1-2 | No tmux client, no terminal running | No Ghostty/iTerm/Terminal window active | Click project with tmux session | New terminal launch is acceptable fallback | `launchTerminalWithTmux` or `launchNewTerminal` | None |
| P1-3 | Detached snapshot with client evidence | Routing snapshot indicates `detached`, evidence includes `tmux_client` | Click project card | Host-terminal activation + tmux switch path | `activateHostThenSwitchTmux` | Direct `launchNewTerminal` without failed primary |
| P1-4 | Detached snapshot without client evidence | No attached clients/evidence | Click project card | Ensure/create+switch session path, fallback only if needed | `ensureTmuxSession` | Immediate launch without attempting ensure path |
| P1-5 | Snapshot unavailable | Simulate daemon/routing fetch failure | Click project card | Fallback launch path works without hang | `are_snapshot_fetch_failed` then launch fallback | Crash, dead click |

### P1: Ambiguous and Multi-window Behavior

| ID | Scenario | Setup | Action | Expected UI/Behavior | Expected Log Signals | Forbidden Signals |
|---|---|---|---|---|---|---|
| P1-6 | Ghostty multi-window + attached tmux client | 2+ Ghostty windows, attached tmux client exists | Click project card | No uncontrolled fan-out; activation + switch behavior remains deterministic | Host/switch path, no repeated fallback loop | Repeated `launchNewTerminal` fan-out on each click |
| P1-7 | iTerm ownership precedence | iTerm + Ghostty running; tmux client hosted in iTerm | Click project card | iTerm gets focus and session switches | TTY discovery + switch logs | Ghostty takeover while iTerm owns client |
| P1-8 | Terminal.app ownership precedence | Terminal.app + Ghostty running; tmux client hosted in Terminal.app | Click project card | Terminal.app focus + session switch | TTY discovery + switch logs | Ghostty takeover while Terminal.app owns client |

`P1-3` is conditional. If detached snapshots do not retain `tmux_client` evidence in the run, evaluate that click under `P1-4` (`ensureTmuxSession` path) rather than recording a failure.

### P2: Edge and Failure Hardening (recommended)

P2 scenarios are high-value hardening checks. Failures should be triaged before release, even if they are not default release blockers.

| ID | Scenario | Setup | Action | Expected UI/Behavior | Expected Log Signals | Forbidden Signals |
|---|---|---|---|---|---|---|
| P2-1 | Primary non-launch failure then fallback | Force primary action failure in controlled test | Click project card | Exactly one fallback launch, one coherent final result | One primary failure + one `launchNewTerminal` | Multiple fallback launches for single click |
| P2-2 | Primary launch fails | Force `launchNewTerminal` failure path | Click project card | Single failure surfaced; no retry loop/fan-out | Failed launch + error surface marker | Repeated launch attempts |
| P2-3 | Snapshot fetch failure during overlap | Delay/fail earlier click snapshot fetch; trigger newer click | Rapid `A -> B` | Only latest click may launch/finalize | Stale suppression marker on older click | Older click fallback-launch after newer click |
| P2-4 | Repeated same-card in-flight clicks | Same project clicked repeatedly while first in-flight | Triple-click same card rapidly | No churn/fan-out; stable final state | Coalesced/stale markers | Multiple launches/actions that change outcome |
| P2-5 | Ghostty running, zero windows | Ghostty process exists but no windows | Click project card | No dead click; recover or single fallback | Recovery attempt or fallback launch | Silent no-op |
| P2-6 | Ambiguous resolver candidates | Create equal-strength conflicting candidates | Click same card repeatedly | Deterministic same winner each run | Stable target/reason across runs | Flip-flop target across runs |
| P2-7 | Path alias normalization edge | Use path variants (slash/case/symlink) in fixtures | Click mapped cards | Consistent per-project routing | Consistent target across aliases | Cross-project bleed |
| P2-8 | OS-level launch failure | Simulate AppleScript/open failure | Click project card | Actionable user-visible failure, no hang | Launch error diagnostics | Dead click, silent failure |

## UX Lens By Scenario

Use this language while evaluating each scenario:

- `P0-1`: “Nothing surprising happened.” User stays in the same terminal/session and trusts the click was safe.
- `P0-2`: “Smooth handoff.” User sees a direct in-place switch, not a window hunt.
- `P0-3`: “Each click mattered.” Sequential clicks produce sequential outcomes with no dropped intent.
- `P0-4`: “Latest intent wins.” User never gets snapped back by an older click.
- `P0-5`: “Burst-safe.” Even under fast tapping, user lands exactly where last click indicated.
- `P1-1`: “Reuse first, quietly.” System reuses existing terminal app instead of spawning more UI noise.
- `P1-2`: “Fallback is understandable.” If launch is required, it feels like a clear recovery, not random behavior.
- `P1-3`: “Detached but recoverable.” Host terminal is recovered cleanly when client evidence exists.
- `P1-4`: “Try smart paths first.” Ensure/create path is attempted before giving up to launch fallback.
- `P1-5`: “No dead click.” Even when snapshot fetch fails, user still gets a visible, timely outcome.
- `P1-6`: “No fan-out storm.” Multi-window ambiguity does not create repeated extra windows per click.
- `P1-7`: “Correct ownership.” iTerm-hosted client stays in iTerm flow.
- `P1-8`: “Correct ownership.” Terminal.app-hosted client stays in Terminal.app flow.
- `P2-1`: “Fallback is controlled.” One failed primary leads to exactly one fallback.
- `P2-2`: “Failure is honest.” Launch failure is surfaced once, without a retry storm.
- `P2-3`: “Stale means stale.” Older overlap request cannot launch after a newer click.
- `P2-4`: “Same-click burst is calm.” Repeated clicks do not create churn.
- `P2-5`: “No dead click on empty host.” User still sees a clear outcome.
- `P2-6`: “Ambiguity is stable.” Same inputs produce same chosen target.
- `P2-7`: “Path identity is reliable.” Alias variations do not break routing boundaries.
- `P2-8`: “Errors are actionable.” Failures explain themselves and do not disappear.

## Required Manual UX Checks

For each P0/P1 scenario:

1. Card click feels immediate and deterministic.
2. No confusing focus jumps after the final click.
3. No visible “window fan-out” unless scenario explicitly permits fallback launch.
4. If activation fails, error toast appears and is actionable.

For each P2 scenario run:

1. Confirm behavior is understandable to a non-expert user.
2. Confirm no repeated launch/retry loops.
3. Confirm error paths are visible and actionable.

## Telemetry/Diagnostics Cross-check (Recommended)

If Transparent UI is running:

1. Open `docs/transparent-ui/capacitor-interfaces-explorer.html`
2. In Live mode, verify activation events stream during tests:
   - `activation_decision`
   - `activation_outcome`
3. Confirm routing target/status aligns with observed behavior.

## Pass/Fail Criteria

A run is **PASS** only when:

- All P0 scenarios pass
- No forbidden P0 log signals occur
- No uncontrolled window fan-out during reuse scenarios
- Any P1 failure is triaged and documented before release
- P1 evidence is captured under a valid host-hygiene baseline (or clearly marked invalid due to contamination)
- P2 failures are either fixed or explicitly accepted with rationale in the QA artifact

## Reporting Template

Copy this section into PRs/issues for manual QA evidence:

```md
### Terminal Activation Manual QA

- Date (UTC):
- Tester:
- Build/Commit:
- Environment: macOS version, terminal(s), tmux version

#### Scenario Results
- P0-1:
- P0-2:
- P0-3:
- P0-4:
- P0-5:
- P1-1:
- P1-2:
- P1-3:
- P1-4:
- P1-5:
- P1-6:
- P1-7:
- P1-8:
- P2-1:
- P2-2:
- P2-3:
- P2-4:
- P2-5:
- P2-6:
- P2-7:
- P2-8:

#### Log Evidence
- App debug log slice path/reference:
- `launchNewTerminal` occurrences in reuse scenarios:
- `ARE snapshot request canceled/stale` occurrences during overlap tests:

#### Notes
- UX observations:
- UX quality rubric:
  - Responsiveness feel (`immediate` | `slight delay` | `laggy`):
  - Focus stability (`stable` | `minor hop` | `disorienting`):
  - Window behavior (`reused context` | `single fallback launch` | `fan-out`):
  - Rapid-click confidence (`high` | `medium` | `low`):
- Regressions found:
- Follow-up issues filed:
```

## Change Policy

When terminal activation behavior changes:

1. Update this file first.
2. Keep scenario IDs stable whenever possible.
3. Do not add full test instructions to legacy matrix docs.
4. Run relevant automated tests before manual QA.
