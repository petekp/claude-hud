#!/bin/bash
# reset-for-testing.sh
#
# Resets Claude HUD to a completely clean state for manual testing.
# Use this when you need to test onboarding, first-run experience,
# or verify behavior from a fresh install.
#
# What gets cleared:
#   - App UserDefaults (setupComplete, layout preferences, etc.)
#   - ~/.capacitor/ (session state, locks, file activity)
#   - HUD hook script (~/.claude/scripts/hud-state-tracker.sh)
#   - HUD hook registrations in ~/.claude/settings.json
#
# What stays intact:
#   - Other ~/.claude/ config (Claude Code's own settings, other hooks)
#   - Source code and git state
#
# Usage: ./scripts/dev/reset-for-testing.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Claude HUD - Complete Reset for Testing            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Stop the app
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Stopping ClaudeHUD if running..."
pkill -f "ClaudeHUD" 2>/dev/null && echo "  ✓ Killed running instance" || echo "  ✓ No instance running"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Clear UserDefaults
#
# IMPORTANT: macOS caches UserDefaults via cfprefsd. Using `defaults delete`
# alone doesn't work reliably—the cached values persist until the daemon
# refreshes. We must:
#   1. Delete the actual plist files from ~/Library/Preferences/
#   2. Kill cfprefsd to flush the cache (it auto-restarts)
#
# Different plist files exist depending on how the app was launched:
#   - ClaudeHUD.plist         → `swift run` (uses executable name)
#   - com.claudehud.app.plist → Release build (uses bundle identifier)
#   - com.claudehud.app.debug.plist → Debug build
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Clearing app UserDefaults..."
rm -f ~/Library/Preferences/ClaudeHUD.plist && echo "  ✓ Removed ClaudeHUD.plist (swift run)" || true
rm -f ~/Library/Preferences/com.claudehud.app.plist && echo "  ✓ Removed com.claudehud.app.plist (release)" || true
rm -f ~/Library/Preferences/com.claudehud.app.debug.plist && echo "  ✓ Removed com.claudehud.app.debug.plist (debug)" || true
rm -f ~/Library/Preferences/claude-hud.plist && echo "  ✓ Removed claude-hud.plist (legacy)" || true

# Force cfprefsd to drop its cache. Without this, deleted prefs may reappear.
killall cfprefsd 2>/dev/null && echo "  ✓ Refreshed preferences cache" || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Clear HUD state directory
#
# ~/.capacitor/ is our namespace (sidecar architecture - we never write to
# ~/.claude/). Contains:
#   - sessions.json: Session state records from hooks
#   - sessions/: Lock directories for active sessions
#   - file-activity.json: Recent file edits for monorepo tracking
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Clearing ~/.capacitor/ (HUD state)..."
if [[ -d "$HOME/.capacitor" ]]; then
    rm -rf "$HOME/.capacitor"
    echo "  ✓ Removed ~/.capacitor/"
else
    echo "  ✓ ~/.capacitor/ already clean"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Remove HUD hooks completely
#
# For a true fresh-install test, we remove:
#   1. The hook script from ~/.claude/scripts/
#   2. HUD's hook registrations from ~/.claude/settings.json
#
# We do NOT reinstall here—the app's onboarding flow should handle that.
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Removing HUD hook script..."
if [[ -f "$HOME/.claude/scripts/hud-state-tracker.sh" ]]; then
    rm -f "$HOME/.claude/scripts/hud-state-tracker.sh"
    echo "  ✓ Removed hook script"
else
    echo "  ✓ No hook script to remove"
fi

echo "→ Removing HUD hook registrations from settings.json..."
SETTINGS_FILE="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
    # Use jq to filter out hook configs containing "hud-state-tracker.sh"
    # For each event in hooks, keep only configs that don't reference our script
    if command -v jq &>/dev/null; then
        # Filter out hook configs that contain "hud-state-tracker.sh" in any command
        # Then remove any hook events that become empty arrays
        jq '
            if .hooks then
                .hooks |= with_entries(
                    .value |= map(
                        select(
                            .hooks == null or
                            (.hooks | map(.command // "" | contains("hud-state-tracker.sh")) | any | not)
                        )
                    ) |
                    select(.value | length > 0)
                )
            else
                .
            end
        ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        echo "  ✓ Removed HUD hook registrations"
    else
        echo "  ⚠ jq not available, skipping settings.json cleanup"
        echo "    (HUD hooks will remain registered but script is gone)"
    fi
else
    echo "  ✓ No settings.json to clean"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Install hud-hook binary
#
# The Rust hook handler binary must be installed for hooks to work.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "→ Installing hud-hook binary..."
"$REPO_ROOT/scripts/sync-hooks.sh" 2>&1 | grep -E "^(  ✓|  Building)" | head -5
echo "  ✓ Hook binary installed"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Rebuild Swift app
#
# Ensures we're testing the current code, not a stale build.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "→ Building Swift app..."
cd "$REPO_ROOT/apps/swift"
swift build 2>&1 | tail -3
echo "  ✓ Swift build complete"

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Launch the app
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Reset Complete!                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Launching ClaudeHUD..."
echo ""

cd "$REPO_ROOT/apps/swift"
swift run
