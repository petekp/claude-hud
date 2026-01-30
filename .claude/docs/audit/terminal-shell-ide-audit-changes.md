# Terminal/Shell/IDE Detection & Integration - Change Report (2026-01-30)

## Summary
This report documents code changes made after the terminal/shell/IDE audit to address activation fallbacks, tmux command safety, path match specificity, and GUI shell detection reliability. Changes align with existing design intent (parent/child shell matching for projects) while tightening selection order and failure handling.

## Findings Addressed
1. **IDE activation can fail with no fallback** (High) → Added `LaunchNewTerminal` fallback for IDE shells without tmux.
2. **tmux session quoting error in launch script** (High) → Removed literal quote injection, use direct `$SESSION` and `$PROJECT_PATH`.
3. **Symmetric path matching can select parent directories** (Medium) → Preserved parent/child matching but enforced specificity order: exact > child > parent.
4. **Regex-based tmux session lookup** (Low) → Replaced regex grep with literal `awk` comparison.
5. **GUI shell detection can be wrong** (Low) → Added login shell lookup via `getpwuid` when `$SHELL` is unavailable.
6. **Case-sensitive path matching on macOS** (Low) → Normalize path casing during matching to avoid missing valid shells/tmux sessions.

## Code Changes

### 1) IDE activation fallback (Rust resolver)
**File:** `core/hud-core/src/activation.rs`
- When `parent_app.is_ide()` and there is **no tmux session**, the resolver now returns a `LaunchNewTerminal` fallback.
- Tests updated to assert fallback for IDE shells without tmux.

**Behavioral impact:**
- If IDE isn’t running, activation now falls back to launching a terminal instead of failing silently.

### 2) tmux launch script quoting + literal session discovery
**File:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- `findOrCreateSession` now uses `awk` to **literal-match** pane paths instead of regex `grep`.
- `switchToExistingSession` now calls `tmux` with unquoted `$SESSION` and `$PROJECT_PATH`, avoiding literal quote injection.

**Behavioral impact:**
- tmux session lookup no longer breaks on regex metacharacters in paths.
- tmux session switching no longer fails due to mismatched quoted session names.

### 3) Path match specificity (shell/tmux selection)
**Files:**
- `core/hud-core/src/activation.rs`
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Change:**
- Matching still allows parent/child relationships but now prefers:
  1) exact match
  2) child match (shell inside project)
  3) parent match (shell at project parent)
- Rust resolver uses a `PathMatch` rank to break ties before timestamps.
- Swift tmux selection uses the same ranking and HOME exclusion.

**Behavioral impact:**
- A shell at `/monorepo/app` now beats a shell at `/monorepo` even if the parent shell is more recent.
- Monorepo parent/child support remains intact.

### 4) GUI shell detection reliability
**File:** `apps/swift/Sources/Capacitor/Models/ShellSetupInstructions.swift`
- `ShellType.current` now falls back to the login shell from `getpwuid` when `$SHELL` is missing.

**Behavioral impact:**
- GUI-launched app shows correct shell integration instructions more often.

### 5) Case-insensitive path matching (macOS)
**Files:**
- `core/hud-core/src/activation.rs`
- `core/hud-core/src/state/path_utils.rs`
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Change:**
- Matching now normalizes path casing on macOS before comparing (no filesystem access for activation matching).
- Swift tmux session selection lowercases paths for consistent matching.

**Behavioral impact:**
- Shells and tmux panes no longer fail to match when path casing differs (common with mixed-case CLI output).

## Tests
- `cargo test -p hud-core activation`

## Manual Verification Suggested
From `terminal-activation-test-matrix.md`:
- **IDE closed, shell tracked** → should launch new terminal
- **Parent/child monorepo path** → exact/child match should win over parent
- **tmux session switching** with session names containing punctuation

## Files Touched
- `core/hud-core/src/activation.rs`
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- `apps/swift/Sources/Capacitor/Models/ShellSetupInstructions.swift`
