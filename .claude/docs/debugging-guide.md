# Debugging Guide

Procedures for debugging Capacitor components (daemon, hooks, app).

For quick-reference gotchas (problem → fix patterns), see [gotchas.md](gotchas.md).
For canonical coding-agent observability workflow and copy/paste commands, see [agent-observability-runbook.md](agent-observability-runbook.md).

Single entry point:

```bash
./scripts/dev/agent-observe.sh help
```

## General Debugging

```bash
# Daemon health + logs (authoritative)
launchctl print gui/$(id -u)/com.capacitor.daemon
tail -f ~/.capacitor/daemon/daemon.stderr.log
tail -f ~/.capacitor/daemon/app-debug.log

# Daemon IPC snapshots
printf '{"protocol_version":1,"method":"get_health","id":"health","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_sessions","id":"sessions","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_project_states","id":"projects","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_shell_state","id":"shell","params":null}\n' | nc -U ~/.capacitor/daemon.sock

# Inspect cache files
cat ~/.capacitor/stats-cache.json | jq .

# Test regex patterns
echo '{"input_tokens":1234}' | rg 'input_tokens":(\d+)'
```

## Hook State Tracking

The hook binary (`~/.local/bin/hud-hook`) handles Claude Code hook events and forwards them to the daemon (single-writer state).

> **Daemon-only note (2026-02):** Shell/session debugging should use daemon IPC. Legacy files are non-authoritative; if they exist from old installs, they can be deleted.

Quick commands (daemon-first):
```bash
tail -f ~/.capacitor/daemon/daemon.stderr.log  # Daemon logs
printf '{"protocol_version":1,"method":"get_health","id":"health","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_sessions","id":"sessions","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_shell_state","id":"shell","params":null}\n' | nc -U ~/.capacitor/daemon.sock
```

## Common Issues

### UniFFI Checksum Mismatch

If you see `UniFFI API checksum mismatch: try cleaning and rebuilding your project`:

1. Check for stale Bridge file: `apps/swift/Sources/Capacitor/Bridge/hud_core.swift`
2. Remove stale app bundles: `rm -rf apps/swift/CapacitorDebug.app apps/swift/Capacitor.app`
3. Remove stale .build cache: `rm -rf apps/swift/.build`
4. Verify dylib is fresh: `ls -la target/release/libhud_core.dylib`

### Stats Not Updating

1. Check if cache is stale: `cat ~/.capacitor/stats-cache.json | jq '.entries | keys'`
2. Delete cache to force recomputation: `rm ~/.capacitor/stats-cache.json`
3. Verify session files exist: `ls ~/.claude/projects/`

### State Stuck on Working/Waiting (Session Actually Ended)

**Symptoms:** Project shows Working or Waiting but Claude session has ended.

**Root cause:** Daemon heuristics or stale events.

**Debug (daemon-first):**
```bash
printf '{"protocol_version":1,"method":"get_sessions","id":"sessions","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_project_states","id":"projects","params":null}\n' | nc -U ~/.capacitor/daemon.sock
```


### hud-hook Binary Out of Date

**Symptoms:** New hook/state features not working, hook events missing, or daemon state not updating after changes.

**Root cause:** The `~/.local/bin/hud-hook` symlink points to old binary (app bundle instead of dev build).

**Diagnosis:**
```bash
# Check symlink target
ls -la ~/.local/bin/hud-hook

# Compare timestamps
ls -la ~/.local/bin/hud-hook
ls -la /Users/$USER/Code/capacitor/target/release/hud-hook
```

**Fix:**
```bash
# Update symlink to dev build
rm ~/.local/bin/hud-hook
ln -s /path/to/capacitor/target/release/hud-hook ~/.local/bin/hud-hook

# Rebuild if needed
cargo build -p hud-hook --release
```

**Prevention:** After any Rust changes to `hud-hook`, rebuild and verify symlink points to `target/release/hud-hook`.

### State Transitions to Ready Prematurely (Session Still Active)

**Symptoms:** Project shows Ready but Claude is still generating a response. Typically happens ~30 seconds into a long generation without tool use.

**Root cause (historical bug, now fixed):** Pre-daemon logic could treat stale timestamps as inactivity even when Claude was still running.

**Current behavior (daemon-only):** UI state should reflect daemon session snapshots (single-writer). If a project flips to Ready while a session is still running, inspect daemon records and hook health rather than legacy artifacts.

**Debug (daemon-first):**
```bash
# Check daemon session + project state
printf '{"protocol_version":1,"method":"get_sessions","id":"sessions","params":null}\n' | nc -U ~/.capacitor/daemon.sock
printf '{"protocol_version":1,"method":"get_project_states","id":"projects","params":null}\n' | nc -U ~/.capacitor/daemon.sock

# Check hook heartbeat (should be fresh if events are flowing)
ls -la ~/.capacitor/hud-hook-heartbeat
```

**Key insight:** In daemon-only mode, trust daemon session snapshots + hook health. Legacy artifacts are not authoritative.

### SwiftUI Layout Broken (Gaps, Components Not Filling Space)

**Symptoms:** Large gaps between header and content, tab bar floating in middle of window.

**Root cause:** Window drag spacers using `Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)` in HStacks. The `maxHeight: .infinity` causes the HStack to expand vertically.

**Solution:** For horizontal spacers that need to be draggable:
```swift
// Simple spacer - preferred
Spacer()

// Or fixed height if needed for hit testing
Color.clear
    .frame(maxWidth: .infinity)
    .frame(height: 28)
    .contentShape(Rectangle())
    .windowDraggable()
```

### Terminal Activation Not Working (Wrong Window Focused)

**Symptoms:** Clicking a project card focuses the wrong terminal window, or activates the app without selecting the correct tab.

**CRITICAL FIRST STEP:** Before debugging code, check the terminal switching matrix:

| Terminal | Tab Selection | Notes |
|----------|--------------|-------|
| iTerm2 | ✅ Full | AppleScript API |
| Terminal.app | ✅ Full | AppleScript API |
| kitty | ⚠️ Non-alpha | Historical path; not in public alpha support scope |
| **Ghostty** | **⚠️ Partial** | No external tab API; tmux path should focus via client-TTY ownership |
| **Warp** | **❌ None** | No AppleScript/CLI API |
| Alacritty | N/A | No tabs, windows only |

If the user is using Warp with multiple windows, this remains a known limitation. For Ghostty, tmux flows should usually foreground the owning window via client TTY; persistent misfocus is a debugging signal.

**Debugging methodology (layered systems):**

The terminal activation system has two layers:
1. **Decision layer** (Rust): `activation.rs` decides WHAT to do
2. **Execution layer** (Swift): `TerminalLauncher.swift` does it

Always trace BOTH layers:
```bash
# Check what decision Rust makes (add logging to launchTerminalWithRustResolver)
# Check what Swift actually executes (add logging to executeActivationAction)
```

**Common misstep:** Assuming the decision layer is wrong when the execution layer has fundamental limitations. Ask "CAN the execution layer do what we're deciding?" before modifying decision logic.

**Trace the full path:**
```
Click → AppState.launchTerminal
      → TerminalLauncher.launchTerminalAsync
      → resolveActivation (Rust decision)
      → executeActivationAction (Swift execution)
      → activateTerminalByTTYDiscovery / activateAppByName
```

If `activateAppByName` is called for a terminal without tab selection API, you've hit a fundamental limitation.

### Terminal Activation No-Op (Ghostty Closed / Unknown Parent)

**Problem:** Clicking an idle project does nothing when Ghostty is closed (some projects still open).

**Cause:** The daemon shell snapshot can include entries with `parent_app=Unknown` (missing `TERM_PROGRAM`).
The resolver picks `ActivateByTty` → TTY discovery fails → fallback was `ActivatePriorityFallback`.
When Ghostty isn’t running (or has zero windows), that fallback returns `false`, so no launch happens.

**Solution/Prevention:**
- For `Unknown` parent shells, fall back to a launch path:
  - `LaunchTerminalWithTmux` when a tmux session exists
  - `EnsureTmuxSession` when a tmux client is attached
  - `LaunchNewTerminal` otherwise
- In Swift, `activatePriorityFallback` should return `false` when Ghostty is installed but not running
  (or running with 0 windows) so launch fallbacks can fire.

**Debugging:**
```bash
rg -n "TerminalLauncher" ~/.capacitor/daemon/app-debug.log | tail -n 200
```
Look for `Found shell (pid=...) with unknown parent` and confirm the fallback action.

**NSRunningApplication.activate() vs AppleScript:**

`NSRunningApplication.activate()` can return `true` while silently failing to actually bring the app to front. This happens when:
- SwiftUI windows aggressively re-activate themselves
- There's a race condition with window ordering

**Diagnosis:** Add logging to check if `activate()` returns true but the app doesn't come to front.

**Fix:** Use AppleScript `tell application "AppName" to activate` instead. It goes through Apple Events which is more reliable for inter-app activation from SwiftUI apps.

### Tmux Multi-Client Activation (Wrong Terminal Focused)

**Symptoms:** With multiple terminals attached to the same tmux session, clicking a project activates the wrong terminal window.

**Root cause:** `tmux list-clients` returns clients in arbitrary order (not most-recent). If the hook used the first line to determine the client TTY, it would often pick the wrong one.

**Diagnosis:**
```bash
# Check how many clients are attached
tmux list-clients

# Check what the CURRENT client's TTY is (this is correct)
tmux display-message -p "#{client_tty}"

# Check what session the current client is viewing
tmux display-message -p "#S"
```

**The fix (already applied):** The hook now uses `display-message -p "#S\t#{client_tty}"` which returns the TTY of the client that invoked the command, not an arbitrary client from the list.

**Additional guardrail (2026-02):** Even with correct tmux session switching, foreground can still be wrong in Ghostty multi-window setups.

**Required execution pattern:**
1. Resolve current client TTY:
```bash
tmux display-message -p '#{client_tty}'
```
2. Switch that specific client:
```bash
tmux switch-client -c <client_tty> -t <session>
```
3. Foreground the terminal process that owns `<client_tty>` (not generic `activate app`).

If step 3 uses generic app activation, tmux can switch in one window while a different Ghostty window is brought to front.

**If still failing:** Check the daemon shell snapshot for the recorded `tmux_client_tty`:
```bash
printf '{"protocol_version":1,"method":"get_shell_state","id":"shell","params":null}\n' | nc -U ~/.capacitor/daemon.sock | jq '.data.shells | to_entries[] | select(.value.tmux_session != null) | {pid: .key, session: .value.tmux_session, tty: .value.tmux_client_tty}'
```

### Stale Client TTY After Tmux Reconnect

**Symptoms:** TTY discovery fails, falls through to Ghostty window-count check, sees 0 windows (user is in Terminal.app/iTerm), spawns new terminal instead of switching.

**Root cause:** Daemon shell records include `tmux_client_tty` captured at hook time. This TTY becomes stale when users reconnect to tmux—they get assigned new TTY devices (e.g., `/dev/ttys012` instead of `/dev/ttys000`).

**Fix:** Query fresh TTY at activation time instead of relying on recorded value:
```swift
private func getCurrentTmuxClientTty() async -> String? {
    let result = await runBashScriptWithResultAsync("tmux display-message -p '#{client_tty}'")
    guard result.exitCode == 0, let output = result.output else { return nil }
    let tty = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return tty.isEmpty ? nil : tty
}
```

**Where:** `TerminalLauncher.swift:activateHostThenSwitchTmux` — use `getCurrentTmuxClientTty() ?? hostTty` before TTY discovery.

### Ghostty Activated When Tmux Client Is in iTerm

**Symptoms:** Clicking a project with tmux activates Ghostty even though the tmux client is attached in iTerm.

**Root cause:** The old activation strategy checked "is Ghostty running?" before attempting TTY-based terminal discovery. If Ghostty was running for any reason, it would use Ghostty-specific logic even when the actual tmux client was elsewhere.

**Diagnosis:**
```bash
# Check which terminal actually has the tmux client attached
tmux display-message -p "#{client_tty}"
# Then match this TTY to a terminal process

# Inspect daemon shell snapshot
printf '{"protocol_version":1,"method":"get_shell_state","id":"shell","params":null}\n' | nc -U ~/.capacitor/daemon.sock | jq '.data.shells | to_entries | .[0:5]'
```

**The fix (already applied):** The activation strategy now tries TTY discovery FIRST. Only if TTY discovery fails AND Ghostty is running does it fall back to Ghostty-specific window counting.

**Order of operations:**
1. Try `activateTerminalByTTYDiscovery()` using the recorded TTY
2. If TTY found → switch tmux in that terminal, done
3. If TTY not found AND Ghostty running → use Ghostty window-count strategy
4. Otherwise → trigger fallback (launch new terminal)

### Shell Injection Testing

When testing terminal activation manually, be aware that session names with special characters could cause issues:

**Test session names to verify escaping:**
```bash
# Create session with single quote (most dangerous)
tmux new-session -d -s "test'session"

# Create session with shell metacharacters
tmux new-session -d -s 'test$(whoami)'

# Click the project in Capacitor and verify:
# 1. No command injection occurs
# 2. The correct session is switched to
```

**Escape functions in use:**
- `shellEscape()` - Single-quote escaping for shell arguments
- `bashDoubleQuoteEscape()` - Escapes `\`, `"`, `$`, `` ` `` for double-quoted strings

### Dead Shells Being Preferred Over Live Ones

**Symptoms:** Terminal activation targets a shell that has exited instead of the live shell in the same directory.

**Diagnosis:**
```bash
# Check daemon shell snapshot for shells at a path
printf '{"protocol_version":1,"method":"get_shell_state","id":"shell","params":null}\n' | nc -U ~/.capacitor/daemon.sock | jq --arg path "/Users/you/Code/project" '.data.shells | to_entries[] | select(.value.cwd | contains($path)) | {pid: .key, cwd: .value.cwd, tty: .value.tty, tmux: .value.tmux_session, updated: .value.updated_at}'

# For each PID, check if it's alive
kill -0 <pid> && echo "alive" || echo "dead"
```

**The fix (already applied):** Rust now receives an `is_live` flag from Swift and prefers live shells:
- Live shell always beats dead shell at same path
- Among shells with same liveness, most recently updated wins

**If still failing:** Check that:
1. UniFFI bindings are regenerated (Swift sends `isLive` to Rust)
2. Shell entries in the daemon shell snapshot have recent `updated_at` timestamps
3. The expected shell PID is actually alive

## Terminal Activation Telemetry Strategy

Terminal activation bugs are notoriously difficult to debug because they span two layers (Rust decision, Swift execution), interact with external state (daemon shell snapshot via `get_shell_state`, tmux), and depend on ephemeral conditions (which windows exist, which processes are live).

### The Two-Layer Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  User clicks project card                                   │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  RUST DECISION LAYER (activation.rs)                        │
│  • Reads daemon shell snapshot (`get_shell_state`) via Swift        │
│  • Queries tmux context via Swift                          │
│  • find_shell_at_path() selects best shell                 │
│  • Returns ActivationAction enum                            │
│                                                             │
│  Key decision points:                                       │
│  • Which shell to use? (live/dead, tmux/non-tmux, recency) │
│  • What action? (ActivateByTty, ActivateHostThenSwitchTmux,│
│    LaunchTerminalWithTmux, ActivatePriorityFallback, etc.) │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  SWIFT EXECUTION LAYER (TerminalLauncher.swift)            │
│  • executeActivationAction() dispatches on action type     │
│  • Calls AppleScript, bash commands, or NSRunningApplication│
│  • May have fallbacks if primary fails                     │
│                                                             │
│  Key execution points:                                      │
│  • TTY discovery (which terminal owns this TTY?)           │
│  • tmux switch-client (does it succeed?)                   │
│  • App activation (does the right window come forward?)    │
└─────────────────────────────────────────────────────────────┘
```

### Telemetry Log Markers

The telemetry uses structured markers for easy filtering:

**Rust layer (activation.rs):**
- Decision logic is pure—add `tracing::info!` or `eprintln!` if needed
- Test coverage is the primary debugging tool (50+ tests)

**Swift layer (TerminalLauncher.swift):**
```
[TerminalLauncher] launchTerminalAsync for: <path>     # Entry point
  ▸ Rust decision: <action type>                       # What Rust decided
  ▸ reason: <why Rust chose this>                      # Rust's explanation
  ▸ Executing action: <action>                         # Swift dispatching

# For ActivateHostThenSwitchTmux:
  activateHostThenSwitchTmux: hostTty=<tty>, session=<name>
    Ghostty window count: <n>
  ▸ Single Ghostty window → activating and switching tmux
  ▸ tmux switch-client result: exit <code>

# For ActivateByTty:
    activateByTtyAction: tty=<tty>, terminalType=<type>
    activateGhosttyWithHeuristic: tty=<tty>, windowCount=<n>
```

### Telemetry Hub (Transparent UI)

The transparent UI server is the fastest way to capture live behavior and provide a single payload for agents.

**Start the hub:**
```bash
./scripts/run-transparent-ui.sh
```
or headless:
```bash
node scripts/transparent-ui-server.mjs
```

**Key endpoints (http://localhost:9133):**
- `GET /agent-briefing?limit=200&shells=recent&shell_limit=25` — compact agent payload (summary + recent shells + telemetry)
- `GET /agent-briefing?shells=all` — full shell inventory when needed
- `GET /daemon-snapshot` — authoritative daemon state snapshot
- `GET /telemetry?limit=200` — recent in-memory telemetry events
- `GET /telemetry-stream` — live telemetry stream (SSE)
- `GET /activation-trace` — live activation trace stream (SSE)

**Notes:**
- Telemetry is in-memory only; restarting the server clears events.
- Swift app telemetry posts to `/telemetry` automatically (see `docs/transparent-ui/README.md`).

**Step 1: Reproduce and capture logs**
```bash
# App debug log (Swift DebugLog)
tail -f ~/.capacitor/daemon/app-debug.log

# Daemon stderr
tail -f ~/.capacitor/daemon/daemon.stderr.log

# OSLog (signed builds only)
log stream --predicate 'subsystem == "com.capacitor.app"' --level debug
```

**Step 2: Identify which layer failed**

| Symptom | Likely Layer | What to Check |
|---------|--------------|---------------|
| Wrong action chosen | Rust | daemon shell snapshot (`get_shell_state`), tmux context |
| Right action, wrong result | Swift | AppleScript, bash commands |
| Shell selection wrong | Rust | `find_shell_at_path()` priority logic |
| Tmux doesn't switch | Swift | `tmux switch-client` exit code |
| Wrong window activated | Swift | TTY discovery, Ghostty heuristics |

**Step 3: Inspect daemon shell snapshot (get_shell_state)**
```bash
# See all shells at a path
printf '{"protocol_version":1,"method":"get_shell_state","id":"shell","params":null}\n' | nc -U ~/.capacitor/daemon.sock | jq --arg path "/Users/you/Code/project" '
  .data.shells | to_entries[] |
  select(.value.cwd | contains($path)) |
  {pid: .key, cwd: .value.cwd, tty: .value.tty, tmux: .value.tmux_session, client_tty: .value.tmux_client_tty, parent: .value.parent_app, updated: .value.updated_at}
'

# Check for multiple shells (the source of many bugs)
printf '{"protocol_version":1,"method":"get_shell_state","id":"shell","params":null}\n' | nc -U ~/.capacitor/daemon.sock | jq '
  .data.shells | to_entries |
  group_by(.value.cwd) |
  map(select(length > 1)) |
  .[] | {path: .[0].value.cwd, count: length, shells: [.[] | {pid: .key, tmux: .value.tmux_session}]}
'
```

**Step 4: Verify tmux context**
```bash
# What sessions exist?
tmux list-sessions

# Is any client attached?
tmux list-clients

# For a specific session, are there clients?
tmux list-clients -t <session-name>

# What's the current client's TTY? (from inside tmux)
tmux display-message -p "#{client_tty}"
```

### Debug Logs for Debug Builds

**Important:** Swift's `Logger` (OSLog) doesn't output to `log show`/`log stream` for unsigned debug builds. Use the file-based `DebugLog` instead.

**Capture during testing:**
```bash
# Primary location
tail -f ~/.capacitor/daemon/app-debug.log

# Fallback if the daemon directory isn't writable
tail -f /tmp/capacitor-app-debug.log
```

If you need extra ad-hoc telemetry, prefer `DebugLog.write(...)` so it lands in these files.

### Common Telemetry Patterns

**Pattern 1: Wrong shell selected**
```
Log shows: Rust decision: ActivateByTty (not ActivateHostThenSwitchTmux)
```
→ Check if multiple shells exist at path
→ Verify `is_live` flags are correct
→ Check if tmux shell has `tmux_session` set

**Pattern 2: Right decision, tmux doesn't switch**
```
Log shows: tmux switch-client result: exit 1
```
→ Resolve client TTY: `tmux display-message -p '#{client_tty}'`
→ Run `tmux switch-client -c <client_tty> -t <session>` manually
→ Check if session name has special characters
→ Verify client is attached

**Pattern 3: Ghostty activates wrong window**
```
Log shows: tmux switch succeeded, but foreground app/window is not the client TTY owner
```
→ Verify execution used client-tty switch form (`switch-client -c <tty>`)
→ Verify TTY-owner activation path ran (look for TTY discovery + Ghostty owner PID logs)
→ If resolver/execution followed both and still misfocused, treat as bug and capture telemetry snapshot

### Adding New Telemetry

When debugging a new issue:

1. **Add entry/exit logging** to suspect functions:
```swift
logger.info("  functionName: param1=\(param1), param2=\(param2)")
// ... function body ...
logger.info("  functionName: result=\(result)")
```

2. **Log decision points** with context:
```swift
if someCondition {
    logger.info("  ▸ Taking path A because: \(reason)")
} else {
    logger.info("  ▸ Taking path B because: \(otherReason)")
}
```

3. **Log external command results**:
```swift
let result = await runBashScriptWithResultAsync(command)
logger.info("  \(commandName) exit=\(result.exitCode), output=\(result.output ?? "nil")")
```

4. **Use consistent indentation** to show call hierarchy (2 spaces per level)

### Telemetry Checklist for New Terminal Bugs

Before modifying code:
- [ ] Captured logs from app-debug.log and daemon.stderr.log (OSLog only if signed)
- [ ] Identified which layer (Rust/Swift) made the wrong decision
- [ ] Inspected daemon shell snapshot (`get_shell_state`) for the relevant path
- [ ] Checked tmux context (sessions, clients, TTYs)
- [ ] Verified terminal app capabilities (see "Terminal Activation Not Working" section above)
- [ ] Added hypothesis to explain the misbehavior

After fixing:
- [ ] Added test case to `activation.rs` if Rust logic changed
- [ ] Verified fix works with user's specific terminal setup
- [ ] Documented gotcha in `.claude/docs/gotchas.md` if non-obvious

## UniFFI Debugging

### "Extra argument in call" or "Missing argument" Errors

**Symptoms:** Swift build fails with errors like `extra argument 'fieldName' in call` or `missing argument for parameter 'fieldName'`.

**Root cause:** Rust FFI struct changed but UniFFI bindings weren't regenerated.

**Fix:**
```bash
# Must build release first (bindings come from dylib)
cargo build -p hud-core --release

# Regenerate Swift bindings
cargo run --bin uniffi-bindgen generate \
    --library target/release/libhud_core.dylib \
    --language swift --out-dir apps/swift/bindings

# Copy to Bridge directory
cp apps/swift/bindings/hud_core.swift apps/swift/Sources/Capacitor/Bridge/

# Rebuild Swift
cd apps/swift && swift build
```

**Prevention:** After any change to FFI types in Rust (structs with `#[derive(uniffi::Record)]`), always run the regeneration sequence.

### Rust Changes Not Reflected in Swift

**Symptoms:** Added new field to FFI struct, Rust tests pass, but Swift doesn't see the new field.

**Checklist:**
1. Is the field in a `#[derive(uniffi::Record)]` struct? (Required for FFI)
2. Did you rebuild the release dylib? (`cargo build -p hud-core --release`)
3. Did you regenerate bindings? (See command above)
4. Did you copy the new `hud_core.swift` to the Bridge directory?
5. Did you clean Swift build cache? (`rm -rf apps/swift/.build`)
