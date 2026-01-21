#!/bin/bash
# Claude HUD State Tracker Hook v2.1.0
# Writes session state to ~/.capacitor/sessions.json
#
# This hook is called by Claude Code on session lifecycle events.
# It receives JSON via stdin containing session info and event details.
#
# Required dependency: jq (brew install jq)
# Optional dependency: python3 (JSON parsing fallback)

set -o pipefail

STATE_FILE="$HOME/.capacitor/sessions.json"
STATE_DIR="$(dirname "$STATE_FILE")"
mkdir -p "$STATE_DIR"

# Read JSON from stdin (Claude Code hook format)
INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

HAVE_JQ=""
HAVE_PY=""
command -v jq >/dev/null 2>&1 && HAVE_JQ="1"
command -v python3 >/dev/null 2>&1 && HAVE_PY="1"
[ -z "$HAVE_JQ" ] && [ -z "$HAVE_PY" ] && exit 0

json_get() {
    local jq_expr="$1"
    local py_key="$2"
    if [ -n "$HAVE_JQ" ]; then
        printf '%s' "$INPUT" | jq -r "$jq_expr" 2>/dev/null
        return 0
    fi
    if [ -n "$HAVE_PY" ]; then
        printf '%s' "$INPUT" | python3 -c $'import sys, json\nkey = sys.argv[1]\ntry:\n    data = json.load(sys.stdin)\nexcept Exception:\n    sys.exit(0)\nval = data.get(key, "")\nval = "" if val is None else val\nprint(json.dumps(val) if isinstance(val, (dict, list)) else val)' "$py_key"
        return 0
    fi
    echo ""
}

normalize_path() {
    local path="$1"
    if [ -z "$path" ]; then
        echo ""
        return
    fi
    while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
        path="${path%/}"
    done
    if [ -z "$path" ]; then
        echo "/"
    else
        echo "$path"
    fi
}

# Parse required fields from JSON
EVENT=$(json_get '.hook_event_name // empty' 'hook_event_name')
SESSION_ID=$(json_get '.session_id // empty' 'session_id')

# cwd may be missing in some events - fallback to PWD, then env var
CWD=$(json_get '.cwd // empty' 'cwd')
CWD="${CWD:-${PWD:-}}"
CWD="${CWD:-${CLAUDE_PROJECT_DIR:-}}"
CWD="$(normalize_path "$CWD")"

# Parse event-specific fields for conditional state transitions
TRIGGER=$(json_get '.trigger // empty' 'trigger')
NOTIFICATION_TYPE=$(json_get '.notification_type // empty' 'notification_type')

# Skip if essential data missing
[ -z "$SESSION_ID" ] && exit 0
[ -z "$CWD" ] && exit 0
[ -z "$EVENT" ] && exit 0

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# TODO: Subagent tracking opportunity
# - PreToolUse provides `tool_name` field - when tool_name="Task", a subagent is spawning
# - SubagentStop hook fires when subagents complete (not currently handled)
# - Could enable "background agents" indicator showing active subagents
# - Would need to parse: TOOL_NAME=$(json_get '.tool_name // empty' 'tool_name')

# Map hook events to states per transition.rs
case "$EVENT" in
    "SessionStart")
        STATE="ready"
        ;;
    "UserPromptSubmit")
        STATE="working"
        ;;
    "PreToolUse")
        STATE="working"
        ;;
    "PostToolUse")
        STATE="working"
        ;;
    "PermissionRequest")
        STATE="blocked"
        ;;
    "PreCompact")
        # Only auto-triggered compaction shows compacting state
        if [ "$TRIGGER" = "auto" ]; then
            STATE="compacting"
        else
            # Manual compaction - maintain current state
            exit 0
        fi
        ;;
    "Stop")
        STATE="ready"
        ;;
    "Notification")
        # Only idle_prompt notification resets to ready
        if [ "$NOTIFICATION_TYPE" = "idle_prompt" ]; then
            STATE="ready"
        else
            exit 0
        fi
        ;;
    "SessionEnd")
        # Remove session entry instead of setting state
        STATE=""
        ;;
    *)
        # Unknown event - skip
        exit 0
        ;;
esac

# Initialize state file if missing
if [ ! -f "$STATE_FILE" ]; then
    echo '{"version":2,"sessions":{}}' > "$STATE_FILE"
fi

# Serialize updates under an optional file lock to avoid clobbering
LOCK_FD=""
LOCK_FILE="${STATE_FILE}.lock"
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if flock -x 9; then
        LOCK_FD="9"
    fi
fi

TEMP_FILE="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
cleanup() {
    [ -n "$LOCK_FD" ] && flock -u "$LOCK_FD" 2>/dev/null || true
    [ -f "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
}
trap cleanup EXIT

write_with_jq() {
    if [ -z "$STATE" ]; then
        jq --arg sid "$SESSION_ID" \
           '.version = 2 | .sessions = (.sessions // {}) | del(.sessions[$sid])' \
           "$STATE_FILE" > "$TEMP_FILE" 2>/dev/null
        return $?
    fi

    jq --arg sid "$SESSION_ID" \
       --arg path "$CWD" \
       --arg state "$STATE" \
       --arg ts "$TIMESTAMP" \
       '.version = 2
        | .sessions = (.sessions // {})
        | .sessions[$sid] = ((.sessions[$sid] // {}) + {session_id: $sid, cwd: $path, state: $state, updated_at: $ts})
        | del(.sessions[$sid].pid)' \
       "$STATE_FILE" > "$TEMP_FILE" 2>/dev/null
    return $?
}

write_with_python() {
    local action="upsert"
    [ -z "$STATE" ] && action="delete"
    python3 - "$STATE_FILE" "$TEMP_FILE" "$SESSION_ID" "$CWD" "$STATE" "$TIMESTAMP" "$action" <<'PY'
import json
import sys

state_file, temp_file, sid, cwd, state, ts, action = sys.argv[1:8]

data = {"version": 2, "sessions": {}}
try:
    with open(state_file, "r", encoding="utf-8") as fh:
        loaded = json.load(fh)
        if isinstance(loaded, dict):
            data.update(loaded)
except Exception:
    pass

sessions = data.get("sessions")
if not isinstance(sessions, dict):
    sessions = {}
data["sessions"] = sessions

if action == "delete":
    sessions.pop(sid, None)
else:
    existing = sessions.get(sid)
    if not isinstance(existing, dict):
        existing = {}
    existing.pop("pid", None)
    existing.update({
        "session_id": sid,
        "cwd": cwd,
        "state": state,
        "updated_at": ts,
    })
    sessions[sid] = existing

data["version"] = 2

with open(temp_file, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
}

if [ -n "$HAVE_JQ" ]; then
    if ! write_with_jq; then
        if [ -n "$HAVE_PY" ]; then
            write_with_python || exit 0
        else
            exit 0
        fi
    fi
else
    write_with_python || exit 0
fi

mv "$TEMP_FILE" "$STATE_FILE" 2>/dev/null || true
