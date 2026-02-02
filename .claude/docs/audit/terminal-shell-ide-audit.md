# Terminal/Shell/IDE Detection & Integration Audit

> **Daemon-only note (2026-02):** This audit describes pre-daemon file/lock behavior. In daemon-only mode, these paths are legacy and should not be authoritative.
## Scope
- Shell CWD tracking and parent-app detection (Rust hook).
- Activation decision logic (Rust resolver).
- Activation execution paths + IDE CLI integration (Swift TerminalLauncher).
- Shell integration setup detection (Swift setup helpers).

## Change Report
- 2026-01-30: See `terminal-shell-ide-audit-changes.md` for implementation details and test coverage.

## Pre-analysis Notes
- Reviewed `CLAUDE.md` and `README.md` for known limitations and terminal/IDE behaviors.
- Checked `terminal-activation-review-synthesis.md` and terminal test matrices for prior findings.
- No TODO/FIXME markers found in the scoped files.
- Recent git history contains no terminal/IDE-specific changes.

## Subsystem Decomposition

| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Shell CWD tracking + parent app detection | `core/hud-hook/src/cwd.rs` | FS: `~/.capacitor/shell-cwd.json`, `~/.capacitor/shell-history.jsonl`; tmux CLI | High |
| 2 | Activation decision (Rust) | `core/hud-core/src/activation.rs` | None (pure logic) | High |
| 3 | Activation execution (Swift) | `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` | AppleScript, tmux CLI, IDE CLI, app activation | High |
| 4 | Shell setup detection | `apps/swift/Sources/Capacitor/Models/ShellSetupInstructions.swift` | FS: user shell config writes | Medium |

## Findings

### [Activation/IDE] Finding 1: IDE shells can dead-end with no fallback

**Severity:** High
**Type:** Bug
**Location:** `core/hud-core/src/activation.rs:394-414`, `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:578-611`

**Problem:**
When an IDE-integrated shell is recorded in `shell-cwd.json` but the IDE is no longer running, activation can fail silently with no fallback. The Rust resolver always returns `ActivateIdeWindow` for IDE parent apps, and only provides a fallback when a tmux session exists. In Swift, `activateIdeWindowAction` returns `false` if the IDE isn’t running, and the activation pipeline stops because there is no fallback action. This contradicts the test matrix scenario “IDE closed, shell tracked → launch new terminal.”

**Evidence:**
- Rust chooses IDE activation unconditionally for IDE parent apps and sets `fallback = None` when `has_tmux` is false. (`activation.rs:394-414`)
- Swift returns `false` if the IDE isn’t running and does not trigger any other action. (`TerminalLauncher.swift:578-611`)

**Recommendation:**
Add a fallback for IDE activation when no tmux session is present. Options:
- In Rust, set `fallback` to `LaunchNewTerminal { project_path, project_name }` when `parent_app.is_ide()` and `has_tmux == false`.
- Alternatively, in Swift, if `activateIdeWindowAction` fails, call `launchNewTerminal(forPath:name:)` using the clicked project path.
- Consider skipping IDE shells when `is_live == false` to allow tmux/session checks or new terminal launch to take over.

---

### [Terminal Scripts] Finding 2: tmux session quoting is incorrect in launch script

**Severity:** High
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:1031-1040`

**Problem:**
The tmux commands in `switchToExistingSession` wrap an already-escaped session name in literal quotes inside double-quoted strings. This passes quotes into tmux as part of the session name, causing `tmux has-session` to miss real sessions and potentially creating sessions with quoted names. This path is used for new terminal launches when tmux is installed, so it can cause duplicate sessions or incorrect session switching.

**Evidence:**
`tmux has-session -t "'$SESSION_ESC'"` and `tmux switch-client -t "'$SESSION_ESC'"` pass literal quotes to tmux. (`TerminalLauncher.swift:1036-1040`)

**Recommendation:**
Remove the extra quotes and use safe shell expansion directly:
- `tmux has-session -t "$SESSION"` and `tmux switch-client -t "$SESSION"`
- Keep `SESSION_ESC` only for contexts that are evaluated later by another shell (e.g., `TMUX_CMD` passed to `sh -c`).

---

### [Path Matching] Finding 3: Symmetric path matching can select parent directories

**Severity:** Medium
**Type:** Design flaw / Bug
**Location:** `core/hud-core/src/activation.rs:363-381`, `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:551-565`

**Problem:**
Both the Rust resolver and Swift tmux query treat either path as a parent/child match. This means a shell in `/Users/pete/Code` can match a project `/Users/pete/Code/myproject`, even though the shell is at the parent directory rather than inside the project. This can incorrectly activate the wrong shell/session instead of launching a new terminal or selecting a more specific shell.

**Evidence:**
- `paths_match_excluding_home` accepts either path as parent. (`activation.rs:363-381`)
- `findTmuxSessionForPath` uses the same bidirectional prefix check. (`TerminalLauncher.swift:551-565`)

**Recommendation:**
Make matching directional and stricter:
- Only treat a shell/tmux pane as a match if it is **inside** the clicked project path or exactly equal.
- Consider incorporating project boundary markers (from `boundaries.rs`) to avoid matching generic parent directories.

---

### [Terminal Scripts] Finding 4: Regex-based tmux session lookup can mis-match paths

**Severity:** Low
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:1019-1022`

**Problem:**
The tmux session lookup uses `grep ":$PROJECT_PATH$"`, which treats `$PROJECT_PATH` as a regex. Paths containing regex metacharacters (`[](){}.*+?^$|`) can cause false matches or missed matches.

**Evidence:**
- `grep ":$PROJECT_PATH$"` in `findOrCreateSession` uses regex matching. (`TerminalLauncher.swift:1019-1022`)

**Recommendation:**
Use literal matching:
- Replace with `grep -F` or parse with `awk -F '\t'` and compare strings exactly.

---

### [Shell Setup] Finding 5: Shell type detection can be wrong in GUI launches

**Severity:** Low
**Type:** Design flaw
**Location:** `apps/swift/Sources/Capacitor/Models/ShellSetupInstructions.swift:63-71`

**Problem:**
`ShellType.current` relies on `ProcessInfo.processInfo.environment["SHELL"]`, which is often missing or defaulted when a GUI app is launched outside a terminal. This can mis-detect the user’s actual login shell (e.g., fish users receiving zsh instructions), reducing the reliability of setup guidance.

**Evidence:**
- Shell detection uses only `$SHELL` with a zsh fallback. (`ShellSetupInstructions.swift:63-71`)

**Recommendation:**
Determine the user’s login shell via system APIs (e.g., `getpwuid`) or `/etc/passwd` lookup, falling back to `$SHELL` only if present.

---

## Summary

**Findings by severity:**
- High: 2
- Medium: 1
- Low: 2

**Top 5 issues (in fix order):**
1. IDE activation can fail with no fallback when IDE is closed. (High)
2. tmux session switching in the launch script uses incorrect quoting. (High)
3. Parent/child path matching can select shells in parent directories. (Medium)
4. Regex-based tmux session lookup can mis-match paths. (Low)
5. GUI shell detection may show incorrect setup instructions. (Low)

**Recommended fix order:**
1. Add fallback behavior for IDE activation failures.
2. Fix tmux quoting in `TerminalScripts.switchToExistingSession`.
3. Tighten path matching rules in Rust resolver + Swift tmux search.
4. Switch tmux session lookup to literal string matching.
5. Improve GUI shell detection via login shell lookup.
