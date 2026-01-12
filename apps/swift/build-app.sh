#!/bin/bash

# Build ClaudeHUD and update the .app bundle
# Usage: ./build-app.sh [--release]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/ClaudeHUD.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"

# Parse arguments
BUILD_CONFIG="debug"
if [ "$1" = "--release" ]; then
    BUILD_CONFIG="release"
fi

echo "Building ClaudeHUD ($BUILD_CONFIG)..."

cd "$SCRIPT_DIR"

if [ "$BUILD_CONFIG" = "release" ]; then
    swift build -c release
    EXECUTABLE="$SCRIPT_DIR/.build/release/ClaudeHUD"
else
    swift build
    EXECUTABLE="$SCRIPT_DIR/.build/debug/ClaudeHUD"
fi

echo "Updating app bundle..."
cp "$EXECUTABLE" "$MACOS_DIR/ClaudeHUD"

echo "Done! App bundle at: $APP_BUNDLE"
echo ""
echo "To install to Applications:"
echo "  cp -r '$APP_BUNDLE' /Applications/"
echo ""
echo "To run now:"
echo "  open '$APP_BUNDLE'"
