# Subsystem 6: Shell CWD Hook

**Files analyzed:**
- `core/hud-hook/src/cwd.rs`

## Summary

The shell CWD hook updates `shell-cwd.json` atomically, appends to `shell-history.jsonl` on changes, and occasionally compacts history with retention windows. Parent app detection uses macOS `proc_pidinfo`/`proc_name` and handles tmux context via `tmux display-message`. The design aligns with the <15ms performance target and avoids blocking the shell.

## Findings

No issues found in this subsystem.

