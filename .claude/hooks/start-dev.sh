#!/bin/bash

# Auto-start Claude HUD dev server on session start
# Only starts if not already running

if ! lsof -ti:5173 > /dev/null 2>&1; then
  cd /Users/petepetrash/Code/claude-hud
  nohup pnpm tauri dev > /tmp/claude-hud-dev.log 2>&1 &
fi

echo '{"continue": true}'
