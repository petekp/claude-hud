#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Verify hook is in sync (warn only, don't block)
"$PROJECT_ROOT/scripts/sync-hooks.sh" 2>/dev/null || true

pkill -x ClaudeHUD 2>/dev/null || true
sleep 0.3

cd "$PROJECT_ROOT"
cargo build -p hud-core --release || { echo "Rust build failed"; exit 1; }

cd "$PROJECT_ROOT/apps/swift"
swift build || { echo "Swift build failed"; exit 1; }

swift run 2>&1 &
echo "ClaudeHUD started (PID: $!)"
