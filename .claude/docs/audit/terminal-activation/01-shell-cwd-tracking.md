# Subsystem 1: Shell CWD Tracking & Daemon Input

## Findings

### [Shell CWD Tracking] Finding 1: TMUX Env Masks Host App (Breaks IDE Activation)

**Severity:** High
**Type:** Design flaw
**Location:** `core/hud-hook/src/cwd.rs:129-143`

**Problem:**
`detect_parent_app` returns `ParentApp::Tmux` immediately when `TMUX` is set, discarding the actual host application (Terminal.app, iTerm, Cursor, VS Code, etc.). That means shells running inside tmux *within an IDE* are indistinguishable from tmux in native terminals. Downstream activation can only attempt host focus by TTY discovery (iTerm/Terminal AppleScript), which fails for IDEs. Result: tmux-in-IDE sessions cannot be re-focused correctly, and activation falls back to priority order or Ghostty heuristics.

**Evidence:**
```
fn detect_parent_app(_pid: u32) -> ParentApp {
    if std::env::var("TMUX").is_ok() {
        return ParentApp::Tmux;
    }
    if let Ok(term_program) = std::env::var("TERM_PROGRAM") { ... }
}
```
(`core/hud-hook/src/cwd.rs:129-143`)

**Recommendation:**
Capture both the *terminal/IDE host* and the *tmux* context. For example, add `host_app: ParentApp` (or `terminal_app`) to the shell state, populated from `TERM_PROGRAM` even when `TMUX` is set. Then let activation prefer IDE activation when `host_app.is_ide()` and tmux client is attached, instead of relying on TTY discovery alone.
