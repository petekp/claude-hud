#!/bin/bash
# Sync hook scripts from repo to installed location
# Prevents version mismatches between repo and installed hooks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_HOOK="$SCRIPT_DIR/hud-state-tracker.sh"
INSTALLED_HOOK="$HOME/.claude/scripts/hud-state-tracker.sh"

get_version() {
    grep -m1 "^# Claude HUD State Tracker Hook v" "$1" 2>/dev/null | sed 's/.*v//' || echo "unknown"
}

if [[ ! -f "$REPO_HOOK" ]]; then
    echo "Error: Repo hook not found at $REPO_HOOK"
    exit 1
fi

REPO_VERSION=$(get_version "$REPO_HOOK")

if [[ ! -f "$INSTALLED_HOOK" ]]; then
    echo "Installing hook v$REPO_VERSION..."
    mkdir -p "$(dirname "$INSTALLED_HOOK")"
    cp "$REPO_HOOK" "$INSTALLED_HOOK"
    chmod +x "$INSTALLED_HOOK"
    echo "✓ Hook installed"
    exit 0
fi

INSTALLED_VERSION=$(get_version "$INSTALLED_HOOK")

if [[ "$REPO_VERSION" == "$INSTALLED_VERSION" ]]; then
    # Same version, but check content hash for uncommitted changes
    REPO_HASH=$(shasum -a 256 "$REPO_HOOK" | cut -d' ' -f1)
    INSTALLED_HASH=$(shasum -a 256 "$INSTALLED_HOOK" | cut -d' ' -f1)

    if [[ "$REPO_HASH" == "$INSTALLED_HASH" ]]; then
        echo "✓ Hook v$REPO_VERSION is current"
        exit 0
    else
        echo "⚠ Hook v$REPO_VERSION content differs (local modifications?)"
        echo "  Repo:      ${REPO_HASH:0:12}..."
        echo "  Installed: ${INSTALLED_HASH:0:12}..."
    fi
else
    echo "⚠ Hook version mismatch!"
    echo "  Repo:      v$REPO_VERSION"
    echo "  Installed: v$INSTALLED_VERSION"
fi

if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
    echo "Updating to v$REPO_VERSION..."
    cp "$REPO_HOOK" "$INSTALLED_HOOK"
    chmod +x "$INSTALLED_HOOK"
    echo "✓ Hook updated"
else
    echo ""
    echo "Run with --force to update, or manually review:"
    echo "  diff \"$INSTALLED_HOOK\" \"$REPO_HOOK\""
fi
