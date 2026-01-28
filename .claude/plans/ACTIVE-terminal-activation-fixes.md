# Terminal Activation System Fixes

**Status:** ACTIVE
**Created:** 2026-01-27
**Source:** 5-model code review synthesis

## Overview

Five independent AI code reviews converged on critical issues in the terminal activation system. This plan addresses them in priority order.

---

## Phase 1: Critical Fixes (Security & Reliability)

### 1.1 Shell Injection Prevention
**Risk:** Security vulnerability
**Files:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Problem:** Session names interpolated directly into bash strings without escaping.
```swift
// VULNERABLE:
runBashScript("tmux switch-client -t '\(sessionName)' 2>/dev/null")
```

**Fix:** Add shell escaping utility and apply everywhere:

```swift
// Add to TerminalLauncher.swift (near top, with other utilities):
private func shellEscape(_ s: String) -> String {
    // Replace single quotes with '\'' (end quote, escaped quote, start quote)
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

**Locations to update:**
- [x] Line ~205: `.switchTmuxSession` case
- [x] Line ~217: `.activateHostThenSwitchTmux` case (Ghostty path)
- [x] Line ~247: `.activateHostThenSwitchTmux` case (TTY path)
- [x] Line ~316: `launchTerminalWithTmuxSession` function

**Test:** Create session named `test'; echo pwned; '` and verify no injection.

---

### 1.2 Tmux Switch-Client Return Value
**Risk:** Silent failures defeat fallback mechanism
**Files:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Problem:** `switch-client` always returns `true`, even on failure.

**Fix:** Check exit code and return `false` on failure:

```swift
case let .switchTmuxSession(sessionName):
    let result = await runBashScriptWithResultAsync(
        "tmux switch-client -t \(shellEscape(sessionName)) 2>&1"
    )
    if result.exitCode != 0 {
        logger.warning("tmux switch-client failed (exit \(result.exitCode)): \(result.output ?? "")")
        return false  // Triggers fallback
    }
    return true
```

**Locations to update:**
- [x] Line ~205: `.switchTmuxSession` case
- [x] Line ~217: `.activateHostThenSwitchTmux` Ghostty path
- [x] Line ~247: `.activateHostThenSwitchTmux` TTY path

**Test:** Detach tmux client, click project, verify fallback executes.

---

### 1.3 IDE CLI Error Handling
**Risk:** User-facing bug (IDE focuses but wrong window)
**Files:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Problem:** `try? process.run()` swallows errors, function returns `true` regardless.

**Fix:** Wait for process and check exit code:

```swift
private func activateIDEWindowInternal(app: ParentApp, projectPath: String) -> Bool {
    guard let runningApp = findRunningIDE(app),
          let cliBinary = app.cliBinary
    else { return false }

    runningApp.activate()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [cliBinary, projectPath]

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = Constants.homebrewPaths + ":" + (env["PATH"] ?? "")
    process.environment = env

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            logger.warning("IDE CLI '\(cliBinary)' exited with status \(process.terminationStatus)")
            return false
        }
        return true
    } catch {
        logger.error("Failed to launch IDE CLI '\(cliBinary)': \(error.localizedDescription)")
        return false
    }
}
```

**Also update caller:**
```swift
private func activateIdeWindowAction(ideType: IdeType, projectPath: String) -> Bool {
    // ... existing code ...
    return activateIDEWindowInternal(app: parentApp, projectPath: projectPath)  // Propagate result
}
```

**Test:** Remove `cursor` from PATH, click Cursor project, verify fallback.

---

### 1.4 Multi-Client Tmux Hook Fix
**Risk:** Wrong terminal activated
**Files:** `core/hud-hook/src/cwd.rs`

**Problem:** Hook uses `list-clients` first line, wrong with multiple clients.

**Fix:** Use `display-message` for current client's TTY:

```rust
fn detect_tmux_context() -> Option<(String, String)> {
    let session_name = run_tmux_command(&["display-message", "-p", "#S"])?;
    if session_name.is_empty() {
        return None;
    }

    // Use display-message for CURRENT client's TTY (not list-clients first line)
    let client_tty = run_tmux_command(&["display-message", "-p", "#{client_tty}"])?;
    if client_tty.is_empty() {
        return None;
    }

    Some((session_name, client_tty))
}
```

**Test:** Open 2 terminals attached to same tmux, verify correct one activates.

---

## Phase 2: Important Fixes (Reliability)

### 2.1 Tmux Client Re-verification
**Files:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Problem:** `has_attached_client` can become stale between query and execution.

**Fix:** Re-check before executing tmux switch:

```swift
case let .activateHostThenSwitchTmux(hostTty, sessionName):
    // Re-verify client is still attached
    let stillAttached = await hasTmuxClientAttached()
    if !stillAttached {
        logger.info("Tmux client detached, falling back to launch")
        launchTerminalWithTmuxSession(sessionName)
        return true
    }
    // ... rest of existing logic
```

- [ ] Update `.activateHostThenSwitchTmux` case

---

### 2.2 AppleScript Error Checking
**Files:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Problem:** `runAppleScript()` is fire-and-forget.

**Fix:** Add result-checking variant for critical paths:

```swift
private func runAppleScriptChecked(_ script: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    let errorPipe = Pipe()
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown"
            logger.warning("AppleScript failed (exit \(process.terminationStatus)): \(errorMsg)")
            return false
        }
        return true
    } catch {
        logger.error("AppleScript launch failed: \(error.localizedDescription)")
        return false
    }
}
```

- [ ] Add `runAppleScriptChecked` function
- [ ] Update critical AppleScript calls to use it

---

### 2.3 Subdirectory Matching in `findTmuxSessionForPath`
**Files:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Problem:** Only exact path matches, not subdirectories.

**Fix:** Use prefix matching (align with Rust):

```swift
private func findTmuxSessionForPath(_ projectPath: String) async -> String? {
    let result = await runBashScriptWithResultAsync(
        "tmux list-windows -a -F '#{session_name}\t#{pane_current_path}' 2>/dev/null"
    )
    guard result.exitCode == 0, let output = result.output else { return nil }

    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let sessionName = String(parts[0])
        let panePath = String(parts[1])

        // Match exact OR subdirectory (align with Rust paths_match)
        if panePath == projectPath ||
           panePath.hasPrefix(projectPath + "/") ||
           projectPath.hasPrefix(panePath + "/") {
            return sessionName
        }
    }
    return nil
}
```

- [ ] Update `findTmuxSessionForPath`

---

### 2.4 Pass `is_live` Flag to Rust
**Files:**
- `core/hud-core/src/activation.rs`
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Problem:** Rust can't make informed decisions about dead shells.

**Fix (Rust):**
```rust
pub struct ShellEntryFfi {
    // ... existing fields
    pub is_live: bool,
}
```

**Fix (Swift):**
```swift
// In convertToFfi, don't filter - mark liveness instead
for (pidString, entry) in shells {
    guard let pid = Int32(pidString) else { continue }
    let isLive = kill(pid, 0) == 0 || errno == EPERM

    ffiShells[pidString] = ShellEntryFfi(
        // ... existing fields
        isLive: isLive
    )
}
```

- [ ] Add `is_live` to `ShellEntryFfi` in Rust
- [ ] Update Swift FFI conversion
- [ ] Update Rust to prefer live shells

---

### 2.5 Fix Ghostty Host Detection
**Files:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Problem:** Activates Ghostty when it's running, even if tmux client is in iTerm.

**Fix:** Try TTY discovery first, only use Ghostty strategy if TTY not found:

```swift
case let .activateHostThenSwitchTmux(hostTty, sessionName):
    // Try TTY discovery first (works for iTerm, Terminal.app)
    let ttyActivated = await activateTerminalByTTYDiscovery(tty: hostTty)

    if ttyActivated {
        // TTY found - switch tmux in that terminal
        let switchResult = await runBashScriptWithResultAsync(
            "tmux switch-client -t \(shellEscape(sessionName)) 2>&1"
        )
        return switchResult.exitCode == 0
    }

    // TTY not found - fall back to Ghostty strategy if running
    if isGhosttyRunning() {
        cleanupExpiredGhosttyCache()
        // ... existing Ghostty logic
    }

    return false  // Trigger fallback
```

- [ ] Restructure `.activateHostThenSwitchTmux` to try TTY first

---

## Phase 3: Nice to Have

### 3.1 Parse Timestamps Properly
**Files:** `core/hud-core/src/activation.rs`

```rust
use chrono::{DateTime, Utc};

fn parse_timestamp(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}
```

- [ ] Add chrono dependency
- [ ] Update timestamp comparison in `find_shell_at_path`

---

### 3.2 Ghostty Cache Size Limit
**Files:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

```swift
private func cleanupExpiredGhosttyCache() {
    let now = Date()
    Self.recentlyLaunchedGhosttySessions = Self.recentlyLaunchedGhosttySessions
        .filter { now.timeIntervalSince($0.value) < Constants.ghosttySessionCacheDuration }

    // Safety: cap at 100 entries
    if Self.recentlyLaunchedGhosttySessions.count > 100 {
        let oldest = Self.recentlyLaunchedGhosttySessions.sorted { $0.value < $1.value }
        Self.recentlyLaunchedGhosttySessions = Dictionary(uniqueKeysWithValues: oldest.suffix(50))
    }
}
```

- [ ] Add size limit to cache cleanup

---

### 3.3 Expose `paths_match` via UniFFI
**Files:** `core/hud-core/src/activation.rs`

```rust
#[uniffi::export]
pub fn paths_match(a: &str, b: &str) -> bool {
    // ... existing implementation
}
```

- [ ] Add `#[uniffi::export]` to `paths_match`
- [ ] Regenerate bindings

---

## Testing Checklist

### Manual Tests
- [ ] Shell injection: Create tmux session with `'` in name
- [ ] Tmux detach race: Click project immediately after detaching
- [ ] IDE CLI missing: Remove `cursor` from PATH, click Cursor project
- [ ] Multi-client tmux: Two terminals attached, verify correct one activates
- [ ] Ghostty + iTerm: Both running, tmux in iTerm, verify iTerm activates

### Unit Tests to Add
- [ ] `paths_match` with symlinks (if feasible)
- [ ] `paths_match` with `..` segments
- [ ] Timestamp comparison with varying formats
- [ ] Shell entry with `is_live: false`

---

## Questions Requiring Decision

1. **Path matching symmetry:** Should `/repo` match `/repo/app` both ways? (Currently yes)
2. **IDE activation path:** Use clicked project path or `shell.cwd`?
3. **Multiple Ghostty windows:** Launch new, prompt user, or document limitation?

---

## Progress Tracking

| Phase | Item | Status |
|-------|------|--------|
| 1.1 | Shell injection prevention | ✅ |
| 1.2 | Tmux switch-client return value | ✅ |
| 1.3 | IDE CLI error handling | ✅ |
| 1.4 | Multi-client tmux hook fix | ✅ |
| 2.1 | Tmux client re-verification | ✅ |
| 2.2 | AppleScript error checking | ✅ |
| 2.3 | Subdirectory matching in findTmuxSessionForPath | ✅ |
| 2.4 | Pass is_live flag to Rust | ✅ |
| 2.5 | Fix Ghostty host detection | ✅ |
| 3.1 | Parse timestamps properly | ⬜ |
| 3.2 | Ghostty cache size limit | ⬜ |
| 3.3 | Expose paths_match via UniFFI | ⬜ |
