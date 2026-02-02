<!-- @task:terminal-activation @load:terminal -->
# Terminal Activation (Quick Reference)

## Limits (Non-negotiable)
- Ghostty: no external API for window/tab focus
- Warp: no AppleScript/CLI window control
- Result: best-effort app activation only

## tmux Rules
- If **any** tmux client exists, prefer switching client over spawning new window
- Prefer tmux shells when multiple shells exist at same path
- Query fresh client TTY at activation time (avoid stale record)

## Matching Rules
- Exact > child > parent (HOME excluded from parent matching)
- Case-insensitive comparisons on macOS (normalize paths)

## Validation
- Use `.claude/docs/terminal-activation-test-matrix.md` for manual tests

