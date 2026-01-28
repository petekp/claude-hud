# Debugging Guide

Procedures for debugging Claude HUD components.

## General Debugging

```bash
# Inspect cache files
cat ~/.capacitor/stats-cache.json | jq .

# Enable Rust debug logging
RUST_LOG=debug swift run

# Test regex patterns
echo '{"input_tokens":1234}' | rg 'input_tokens":(\d+)'
```

## Hook State Tracking

The hook binary (`~/.local/bin/hud-hook`) handles Claude Code hook events and tracks session state.

Quick commands:
```bash
tail -f ~/.capacitor/hud-hook-debug.log        # Watch events
cat ~/.capacitor/sessions.json | jq .          # View states
ls ~/.capacitor/sessions/                      # Check active locks
```

## Common Issues

### UniFFI Checksum Mismatch

If you see `UniFFI API checksum mismatch: try cleaning and rebuilding your project`:

1. Check for stale Bridge file: `apps/swift/Sources/ClaudeHUD/Bridge/hud_core.swift`
2. Remove stale app bundle: `rm -rf apps/swift/ClaudeHUD.app`
3. Remove stale .build cache: `rm -rf apps/swift/.build`
4. Verify dylib is fresh: `ls -la target/release/libhud_core.dylib`

See `.claude/docs/development-workflows.md` for the full regeneration procedure.

### Stats Not Updating

1. Check if cache is stale: `cat ~/.capacitor/stats-cache.json | jq '.entries | keys'`
2. Delete cache to force recomputation: `rm ~/.capacitor/stats-cache.json`
3. Verify session files exist: `ls ~/.claude/projects/`

### State Stuck on Working/Waiting (Session Actually Ended)

**Symptoms:** Project shows Working or Waiting but Claude session has ended.

**Root cause:** Lock holder didn't clean up (crashed, force-killed, or PID mismatch).

**Debug:**
```bash
# Check if lock exists
ls ~/.capacitor/sessions/

# Check if lock holder PID is alive
cat ~/.capacitor/sessions/*.lock/pid | xargs -I {} ps -p {}

# If PID is dead, app cleanup should remove it on next launch
# Force cleanup by restarting the app
```

**Fix:** App runs `runStartupCleanup()` on launch which removes locks with dead PIDs.

### Stale or Legacy Locks (Wrong Project State)

**Symptoms:** Project shows wrong state (e.g., Ready when should be Idle), multiple projects show same state, or clicking different projects opens the same session.

**Root cause:** Legacy path-based locks (v3) or stale session-based locks polluting the lock directory.

**Diagnosis:**
```bash
# List all locks with their format
for lock in ~/.capacitor/sessions/*.lock; do
  name=$(basename "$lock" .lock)
  if [[ "$name" =~ ^[a-f0-9]{32}$ ]]; then
    echo "LEGACY (delete): $name"
  else
    echo "SESSION-BASED: $name"
  fi
  cat "$lock/meta.json" 2>/dev/null | jq -c '{path, pid, session_id}'
done

# Check if lock PIDs are alive
for lock in ~/.capacitor/sessions/*.lock; do
  pid=$(cat "$lock/pid" 2>/dev/null)
  name=$(basename "$lock")
  if ps -p "$pid" > /dev/null 2>&1; then
    echo "$name: PID $pid ALIVE"
  else
    echo "$name: PID $pid DEAD (stale)"
  fi
done
```

**Fix:**
1. Delete legacy locks (32-char hex names like `abc123...def.lock`)
2. Delete session-based locks where PID is dead
3. Verify `hud-hook` symlink points to current build (see below)

### hud-hook Binary Out of Date

**Symptoms:** New lock/state features not working, old lock format still being created, hooks not firing correctly.

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

**Root cause (historical bug, now fixed):** The resolver applied `is_active_state_stale()` checks even when a lock existed. During tool-free text generation, no hook events fire to refresh `updated_at`, so after 30 seconds the state would fall back to Ready despite the lock proving Claude was still running.

**Current behavior:** When a lock exists, the resolver trusts the recorded state unconditionally. The lock holder monitors Claude's PID and will release when Claude actually exits, so lock existence is authoritative.

**Key insight:** Lock presence = Claude running. Trust the lock over timestamp freshness.

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

**CRITICAL FIRST STEP:** Before debugging code, check `.claude/docs/terminal-switching-matrix.md`:

| Terminal | Tab Selection | Notes |
|----------|--------------|-------|
| iTerm2 | ✅ Full | AppleScript API |
| Terminal.app | ✅ Full | AppleScript API |
| kitty | ✅ Full | Requires `allow_remote_control yes` |
| **Ghostty** | **❌ None** | No external API |
| **Warp** | **❌ None** | No AppleScript/CLI API |
| Alacritty | N/A | No tabs, windows only |

If the user is using Ghostty or Warp with multiple windows, **this is a known limitation, not a bug**. The system cannot select a specific window—only activate the app.

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

**If still failing:** Check `~/.capacitor/shell-cwd.json` to see what `tmux_client_tty` value the hook recorded:
```bash
cat ~/.capacitor/shell-cwd.json | jq '.shells | to_entries[] | select(.value.tmux_session != null) | {pid: .key, session: .value.tmux_session, tty: .value.tmux_client_tty}'
```

### Ghostty Activated When Tmux Client Is in iTerm

**Symptoms:** Clicking a project with tmux activates Ghostty even though the tmux client is attached in iTerm.

**Root cause:** The old activation strategy checked "is Ghostty running?" before attempting TTY-based terminal discovery. If Ghostty was running for any reason, it would use Ghostty-specific logic even when the actual tmux client was elsewhere.

**Diagnosis:**
```bash
# Check which terminal actually has the tmux client attached
tmux display-message -p "#{client_tty}"
# Then match this TTY to a terminal process

# Check what's in shell-cwd.json
cat ~/.capacitor/shell-cwd.json | jq '.shells' | head -50
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
# Check shell-cwd.json for shells at a path
cat ~/.capacitor/shell-cwd.json | jq '.shells | to_entries[] | select(.value.cwd | contains("/your/project"))'

# For each PID, check if it's alive
kill -0 <pid> && echo "alive" || echo "dead"
```

**The fix (already applied):** Rust now receives an `is_live` flag from Swift and prefers live shells:
- Live shell always beats dead shell at same path
- Among shells with same liveness, most recently updated wins

**If still failing:** Check that:
1. UniFFI bindings are regenerated (Swift sends `isLive` to Rust)
2. Shell entries in JSON have recent `updated_at` timestamps
3. The expected shell PID is actually alive

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
