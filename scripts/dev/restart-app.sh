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

# Always regenerate UniFFI bindings to prevent checksum mismatch crashes
cargo run --bin uniffi-bindgen generate \
    --library target/release/libhud_core.dylib \
    --language swift \
    --out-dir apps/swift/bindings/ 2>/dev/null

# Copy bindings to Bridge directory
cp apps/swift/bindings/hud_core.swift apps/swift/Sources/ClaudeHUD/Bridge/

# Copy dylib to Swift build directory
mkdir -p apps/swift/.build/arm64-apple-macosx/debug
cp target/release/libhud_core.dylib apps/swift/.build/arm64-apple-macosx/debug/

cd "$PROJECT_ROOT/apps/swift"
swift build || { echo "Swift build failed"; exit 1; }

swift run 2>&1 &
echo "ClaudeHUD started (PID: $!)"
