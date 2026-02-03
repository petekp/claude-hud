# Subsystem 3: Swift Activation Executor (TerminalLauncher)

## Findings

### [Swift Execution] Finding 1: AppleScript Failures Are Treated as Success

**Severity:** High
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:478-488, 784-796`

**Problem:**
For TTY-based activation (`iTerm` and `Terminal.app`), the code invokes AppleScript and then unconditionally returns `true`. If AppleScript fails (e.g., accessibility permissions missing, script error), the activation path reports success and prevents fallbacks from running.

**Evidence:**
```
case .iTerm:
    activateITermSession(tty: tty)
    return true
case .terminalApp:
    activateTerminalAppSession(tty: tty)
    return true
```
(`TerminalLauncher.swift:478-488`)

And for TTY discovery:
```
case .iTerm:
    activateITermSession(tty: tty)
case .terminal:
    activateTerminalAppSession(tty: tty)
return true
```
(`TerminalLauncher.swift:784-796`)

**Recommendation:**
Convert `activateITermSession` / `activateTerminalAppSession` to return a Bool using `runAppleScriptChecked`, and propagate failure so fallbacks can run. This aligns “activation succeeded” with actual OS state.

---

### [Swift Execution] Finding 2: Terminal.app Not Detected in Fallbacks

**Severity:** Medium
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/ActivationConfig.swift:28-33`, `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:928-937`

**Problem:**
Fallback activation uses `ParentApp.displayName` for substring matching against `NSRunningApplication.localizedName`. For Terminal.app, `displayName` is "Terminal.app" while `localizedName` is typically "Terminal". This mismatch prevents Terminal.app from being matched in `findRunningApp` and `isTerminalApp`, causing fallback activation to skip a running Terminal.app instance.

**Evidence:**
```
case .terminal: return "Terminal.app"
```
(`ActivationConfig.swift:28-33`)

```
let name = terminal.displayName.lowercased()
...
$0.localizedName?.lowercased().contains(name) == true
```
(`TerminalLauncher.swift:928-932`)

```
ParentApp.terminalPriorityOrder.contains { name.contains($0.displayName) }
```
(`TerminalLauncher.swift:935-937`)

**Recommendation:**
Match by bundle identifier (`com.apple.Terminal`) or use a dedicated process-name map for terminal apps. At minimum, set Terminal’s display name to "Terminal" so substring matching works.

---

### [Swift Execution] Finding 3: LaunchNewTerminal Action Still Runs Tmux Logic

**Severity:** High
**Type:** Design flaw
**Location:** `core/hud-core/src/activation.rs:122-125`, `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:1095-1127`

**Problem:**
`ActivationAction::LaunchNewTerminal` is documented as “no tmux,” but the Swift implementation uses `TerminalScripts.launch`, which *always* checks for tmux and may switch/attach to sessions. This violates the action semantics and couples launch behavior to tmux even when the resolver explicitly chose a non-tmux launch.

**Evidence:**
```
/// Launch new terminal at project path (no tmux)
LaunchNewTerminal { ... }
```
(`activation.rs:122-125`)

```
HAS_ATTACHED_CLIENT=$(tmux list-clients ...)
if [ -n "$HAS_ATTACHED_CLIENT" ]; then
    ... tmux switch-client ...
else
    TMUX_CMD="tmux new-session -A ..."
    ... launch terminal with tmux ...
fi
```
(`TerminalLauncher.swift:1116-1127`)

**Recommendation:**
Split launch scripts into explicit “no-tmux” and “tmux attach” variants. Ensure `LaunchNewTerminal` never uses tmux, and reserve tmux behavior for `LaunchTerminalWithTmux`.

---

### [Swift Execution] Finding 4: IDE CLI Activation Blocks Main Thread

**Severity:** Medium
**Type:** Design flaw
**Location:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:709-727`

**Problem:**
`activateIDEWindowInternal` runs the CLI and then calls `process.waitUntilExit()` on the main actor. If the CLI is slow or hangs, the UI can freeze during activation.

**Evidence:**
```
try process.run()
process.waitUntilExit()
```
(`TerminalLauncher.swift:724-726`)

**Recommendation:**
Run IDE CLI activation off the main actor (e.g., `Task.detached` or a background queue) and report completion asynchronously.

---

### [Swift Execution] Finding 5: Ghostty Strategy Comment Is Stale

**Severity:** Low
**Type:** Stale docs
**Location:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:740-742, 536-552`

**Problem:**
The inline comment claims “If 0 or multiple windows, launch new terminal,” but the implementation activates Ghostty when `windowCount > 1`. This mismatch makes the code harder to reason about and undermines confidence in the heuristics.

**Evidence:**
```
// Strategy: If exactly 1 window, activate app. If 0 or multiple, launch new terminal.
```
(`TerminalLauncher.swift:740-742`)

```
} else {
    ... multiple windows ...
    runAppleScript("tell application \"Ghostty\" to activate")
    return true
}
```
(`TerminalLauncher.swift:550-553`)

**Recommendation:**
Update the comment to match current behavior or adjust the implementation to align with the documented strategy.
