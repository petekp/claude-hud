# Terminal Activation Audit Summary

## Findings Count
- **High:** 3
- **Medium:** 4
- **Low:** 3

## Top 5 Issues (Fix First)
1. **TMUX env masks host app** → tmux-in-IDE sessions cannot activate IDE windows. (`core/hud-hook/src/cwd.rs:129-143`) ✅ Fixed
2. **AppleScript failures treated as success** → activation silently fails without fallback. (`TerminalLauncher.swift:478-488, 784-796`) ✅ Fixed
3. **LaunchNewTerminal still runs tmux logic** → action semantics violated, hard to reason about. (`activation.rs:122-125`, `TerminalLauncher.swift:1095-1127`) ✅ Fixed
4. **IDE fallback ignores attached-client state** → SwitchTmuxSession chosen when no clients exist. (`activation.rs:485-513`) ✅ Fixed
5. **Terminal.app not detected in fallback** → Terminal skipped in priority activation. (`ActivationConfig.swift:28-33`, `TerminalLauncher.swift:928-937`) ✅ Fixed

## Recommended Fix Order
1. ✅ **Data capture fix:** Preserve host terminal/IDE even when TMUX is set (host app preserved; tmux context still captured).
2. ✅ **Execution correctness:** TTY activation now returns real success/failure via checked AppleScript results.
3. ✅ **Action semantics cleanup:** `LaunchNewTerminal` uses a no-tmux script; tmux launch is explicit.
4. ✅ **Resolver adjustments:** IDE fallback gated on attached-client; tmux preference is a tie-breaker, not a filter.
5. ✅ **Fallback reliability:** Terminal.app matching corrected; docs updated.

## Cross-Cutting Observations
- The activation pipeline is conceptually clean in Rust but gets entangled in Swift by mixing decision and execution logic (tmux checks in “no-tmux” launches, AppleScript execution without feedback).
- Debug/config logic (`ActivationConfigStore`) is not connected to the live activation path, which increases the risk of drift.

## Next Step (if refactor proceeds)
- ✅ Introduced **ActivationActionExecutor** with injected dependencies and dedicated tests; TerminalLauncher now delegates action execution.
- ✅ Enforced action semantics in Swift (no-tmux LaunchNewTerminal) and added tests.
- ✅ Split tmux/terminal discovery/launcher adapters into standalone types for finer-grained testing and slimmer TerminalLauncher.
