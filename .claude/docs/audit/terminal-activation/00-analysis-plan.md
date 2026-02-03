# Terminal Activation System Audit Plan

## Scope
Terminal activation from shell hook → daemon shell state → Rust resolver → Swift execution (AppleScript/tmux/CLI) plus related config/debug docs.

## Subsystems
| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Shell CWD Tracking & Daemon Input | `core/hud-hook/src/cwd.rs` | Env reads, `tmux`/`tty` subprocess, daemon IPC | High |
| 2 | Rust Activation Decision | `core/hud-core/src/activation.rs`, `core/hud-core/src/engine.rs` | None (pure) | High |
| 3 | Swift Activation Executor | `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` | AppleScript, tmux subprocess, NSWorkspace, Process | High |
| 4 | Config/Debug + Docs | `apps/swift/Sources/Capacitor/Models/ActivationConfig.swift`, `apps/swift/Sources/Capacitor/Views/Debug/ShellMatrixPanel/*`, `.claude/docs/terminal-switching-matrix.md` | UserDefaults, docs | Medium |

## Known Issues Sweep (from docs)
- Terminal switching matrix documents multiple scenarios and marks IDE activation as broken; needs validation against current Swift/Rust paths.
- Ghostty strategy in the matrix appears inconsistent with current heuristics.

## Methodology
- Read every line in the activation path across hook → resolver → executor.
- Classify issues by severity (Critical/High/Medium/Low) with concrete line references.
- Separate subsystem findings; consolidate cross-cutting issues in summary.
