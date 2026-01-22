#!/bin/bash
# Set up git hooks for Claude HUD development
# Run once after cloning the repo

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
GIT_HOOKS_DIR="$PROJECT_ROOT/.git/hooks"

mkdir -p "$GIT_HOOKS_DIR"

# Post-checkout hook: Warn about hook version mismatches after branch switch
cat > "$GIT_HOOKS_DIR/post-checkout" << 'EOF'
#!/bin/bash
# Git post-checkout hook: Warn about hook version mismatches after branch switch

[[ "$3" != "1" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/scripts/sync-hooks.sh"

if [[ -x "$SYNC_SCRIPT" ]]; then
    "$SYNC_SCRIPT" 2>/dev/null | grep -v "^✓" || true
fi
EOF
chmod +x "$GIT_HOOKS_DIR/post-checkout"

echo "✓ Git hooks installed"
echo ""
echo "Hooks configured:"
echo "  post-checkout - Warns about hook version mismatches after branch switch"
