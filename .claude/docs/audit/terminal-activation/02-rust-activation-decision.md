# Subsystem 2: Rust Activation Decision (core/hud-core)

## Findings

### [Activation Decision] Finding 1: IDE Fallback Ignores Attached-Client State

**Severity:** Medium
**Type:** Bug
**Location:** `core/hud-core/src/activation.rs:485-513`

**Problem:**
When a shell is detected inside an IDE and also has a `tmux_session`, the fallback action is always `SwitchTmuxSession` regardless of whether any tmux client is attached. If no client is attached, `SwitchTmuxSession` will fail (no client to switch), and there is no fallback to `LaunchTerminalWithTmux` in this path.

**Evidence:**
```
let fallback = if has_tmux {
    shell.tmux_session.as_ref().map(|s| ActivationAction::SwitchTmuxSession { ... })
} else {
    Some(ActivationAction::LaunchNewTerminal { ... })
};
```
(`core/hud-core/src/activation.rs:485-505`)

**Recommendation:**
Gate the tmux fallback on `tmux_context.has_attached_client`. If false, set fallback to `LaunchTerminalWithTmux` (mirroring the non-IDE tmux path). This keeps behavior consistent when no tmux clients exist.

---

### [Activation Decision] Finding 2: Global Tmux Attachment Masks Direct Shells

**Severity:** Medium
**Type:** Design flaw
**Location:** `core/hud-core/src/activation.rs:206-216`

**Problem:**
When *any* tmux client is attached, `require_tmux_or_ide` filters out non-tmux shells in `find_shell_at_path`. This forces tmux activation even when a direct (non-tmux) terminal for the target project is already open. Users with tmux attached in an unrelated project can no longer focus their direct terminal for the clicked project.

**Evidence:**
```
let require_tmux_or_ide = tmux_context.has_attached_client;
if let Some((pid, shell)) = find_shell_at_path(..., require_tmux_or_ide) { ... }
```
(`core/hud-core/src/activation.rs:206-216`)

**Recommendation:**
Treat tmux as a tie-breaker preference rather than a hard filter. For example, keep all candidate shells but weight tmux shells higher *only when they match the target path*; or make the filter conditional on the candidate shell being tmux-related instead of global.
