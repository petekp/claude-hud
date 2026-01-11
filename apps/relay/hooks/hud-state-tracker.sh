#!/bin/bash
# HUD State Tracker Hook
# Tracks Claude session state and writes to ~/.claude/hud-session-states.json
#
# This script should be configured in ~/.claude/settings.json for the following events:
# - SessionStart, UserPromptSubmit, PermissionRequest, PostToolUse
# - PreCompact, Stop, SessionEnd, Notification (idle_prompt)
#
# The canonical implementation lives at ~/.claude/scripts/hud-state-tracker.sh
# This version in the repo is provided as a reference/starting point.
#
# For relay publishing, also configure ~/.claude/hooks/publish-state.sh

set -e

# Skip if this is a summary generation subprocess (prevents recursive hook pollution)
if [ "$HUD_SUMMARY_GEN" = "1" ]; then
  cat > /dev/null
  exit 0
fi

STATE_FILE="$HOME/.claude/hud-session-states.json"
LOG_FILE="$HOME/.claude/hud-hook-debug.log"

INPUT=$(cat)

# Log every hook call for debugging
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | $(echo "$INPUT" | jq -c '{event: .hook_event_name, cwd: .cwd}' 2>/dev/null)" >> "$LOG_FILE"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // empty')
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty')

# Skip if stop hook is re-running (prevents loops)
if [ "$HOOK_EVENT" = "Stop" ] && [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  echo '{"continue": true}'
  exit 0
fi

# Skip if missing required fields
if [ -z "$CWD" ] || [ -z "$HOOK_EVENT" ]; then
  echo '{"continue": true}'
  exit 0
fi

# Normalize CWD to git root for consistent path matching
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    GIT_ROOT=$(cd "$CWD" && git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$GIT_ROOT" ]; then
        PROJECT_PATH="$GIT_ROOT"
    else
        PROJECT_PATH="$CWD"
    fi
else
    PROJECT_PATH="$CWD"
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine state and thinking based on hook event
case "$HOOK_EVENT" in
    "SessionStart")
        STATE="ready"
        THINKING="false"
        ;;
    "UserPromptSubmit")
        STATE="working"
        THINKING="true"
        ;;
    "PermissionRequest")
        # Stay in current state - permissions happen during active work
        echo '{"continue": true}'
        exit 0
        ;;
    "PostToolUse")
        # Check if we're coming out of compacting - tool use means work resumed
        CURRENT_STATE=$(jq -r --arg path "$PROJECT_PATH" '.projects[$path].state // "idle"' "$STATE_FILE" 2>/dev/null)
        if [ "$CURRENT_STATE" = "compacting" ]; then
            STATE="working"
            THINKING="true"
        elif [ "$CURRENT_STATE" = "working" ]; then
            # Update heartbeat timestamp only
            TEMP_FILE=$(mktemp)
            jq --arg path "$PROJECT_PATH" \
               --arg ts "$TIMESTAMP" \
               '.projects[$path].thinking = true | .projects[$path].thinking_updated_at = $ts | .projects[$path].context.updated_at = $ts' \
               "$STATE_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$STATE_FILE"
            echo '{"continue": true}'
            exit 0
        else
            echo '{"continue": true}'
            exit 0
        fi
        ;;
    "PreCompact")
        if [ "$TRIGGER" = "auto" ]; then
            STATE="compacting"
            THINKING="true"
        else
            echo '{"continue": true}'
            exit 0
        fi
        ;;
    "Stop")
        STATE="ready"
        THINKING="false"
        ;;
    "SubagentStop")
        # Subagent stopped but main agent may continue
        STATE="working"
        THINKING="false"
        ;;
    "SessionEnd")
        # Don't set idle - SessionEnd fires immediately after Stop,
        # which would overwrite "ready" with "idle". Just exit.
        echo '{"continue": true}'
        exit 0
        ;;
    "Notification")
        # idle_prompt means Claude is waiting for user input (handles interrupt case)
        if [ "$NOTIFICATION_TYPE" = "idle_prompt" ]; then
            STATE="ready"
            THINKING="false"
        else
            echo '{"continue": true}'
            exit 0
        fi
        ;;
    *)
        echo '{"continue": true}'
        exit 0
        ;;
esac

# Ensure state file exists with valid JSON
if [ ! -f "$STATE_FILE" ] || ! jq -e . "$STATE_FILE" &>/dev/null; then
    echo '{"version": 1, "projects": {}}' > "$STATE_FILE"
fi

# Update the state file atomically
TEMP_FILE=$(mktemp)

jq --arg path "$PROJECT_PATH" \
   --arg state "$STATE" \
   --argjson thinking "$THINKING" \
   --arg session_id "$SESSION_ID" \
   --arg timestamp "$TIMESTAMP" \
   '.projects[$path] = ((.projects[$path] // {}) + {
       state: $state,
       thinking: $thinking,
       session_id: (if $session_id == "" then null else $session_id end),
       state_changed_at: $timestamp,
       thinking_updated_at: $timestamp
   }) | .projects[$path].context.updated_at = $timestamp' "$STATE_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$STATE_FILE"

# Output success response (allows Claude to continue)
echo '{"continue": true}'
