#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_SCENARIO_FILE="$SCRIPT_DIR/scenarios/project_flow_v1.json"
AX_RUNNER="$SCRIPT_DIR/ax_runner.swift"
BUNDLE_ID="com.capacitor.app.debug"
APP_BINARY="$PROJECT_ROOT/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor"

SCENARIO_FILE="$DEFAULT_SCENARIO_FILE"
DEMO_SCENARIO_NAME="project_flow_v1"
RECORD_SECONDS=40
WITH_GHOSTTY=0
CLICK_MODE="scenario"
DEMO_DISABLE_SIDE_EFFECTS=1
DEMO_DISABLE_SIDE_EFFECTS_EXPLICIT=0
LAYOUT_FILE="$PROJECT_ROOT/artifacts/demo/window-layout.env"
DEMO_PROJECTS_FILE=""
RECORD_PADDING=18

usage() {
    cat <<USAGE
Usage: ./scripts/demo/run-vertical-slice.sh [options]

Options:
  --with-ghostty                    Include Ghostty alongside Capacitor in one recording frame.
  --scenario <path>                 Scenario JSON path (default: scripts/demo/scenarios/project_flow_v1.json).
  --record-seconds <n>              Recording duration in seconds (default: 40).
  --click-mode <scenario|ax|visible> Click execution mode for AX runner (default: scenario).
  --demo-disable-side-effects <0|1> Override CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS.
  --layout-file <path>              Window layout env file for --with-ghostty runs.
  --projects-file <path>            JSON file that defines demo projects/hidden section.
  --help                            Show this help text.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --with-ghostty)
        WITH_GHOSTTY=1
        shift
        ;;
    --scenario)
        [[ $# -ge 2 ]] || { echo "--scenario requires a value" >&2; exit 1; }
        SCENARIO_FILE="$2"
        shift 2
        ;;
    --record-seconds)
        [[ $# -ge 2 ]] || { echo "--record-seconds requires a value" >&2; exit 1; }
        RECORD_SECONDS="$2"
        shift 2
        ;;
    --click-mode)
        [[ $# -ge 2 ]] || { echo "--click-mode requires a value" >&2; exit 1; }
        CLICK_MODE="$2"
        shift 2
        ;;
    --demo-disable-side-effects)
        [[ $# -ge 2 ]] || { echo "--demo-disable-side-effects requires 0 or 1" >&2; exit 1; }
        DEMO_DISABLE_SIDE_EFFECTS="$2"
        DEMO_DISABLE_SIDE_EFFECTS_EXPLICIT=1
        shift 2
        ;;
    --layout-file)
        [[ $# -ge 2 ]] || { echo "--layout-file requires a value" >&2; exit 1; }
        LAYOUT_FILE="$2"
        shift 2
        ;;
    --projects-file)
        [[ $# -ge 2 ]] || { echo "--projects-file requires a value" >&2; exit 1; }
        DEMO_PROJECTS_FILE="$2"
        shift 2
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
done

if ! [[ "$RECORD_SECONDS" =~ ^[0-9]+$ ]] || [[ "$RECORD_SECONDS" -le 0 ]]; then
    echo "--record-seconds must be a positive integer" >&2
    exit 1
fi

if [[ "$CLICK_MODE" != "scenario" && "$CLICK_MODE" != "ax" && "$CLICK_MODE" != "visible" ]]; then
    echo "--click-mode must be one of: scenario, ax, visible" >&2
    exit 1
fi

if [[ "$DEMO_DISABLE_SIDE_EFFECTS" != "0" && "$DEMO_DISABLE_SIDE_EFFECTS" != "1" ]]; then
    echo "--demo-disable-side-effects must be 0 or 1" >&2
    exit 1
fi

if [[ "$WITH_GHOSTTY" -eq 1 && "$DEMO_DISABLE_SIDE_EFFECTS_EXPLICIT" -eq 0 ]]; then
    DEMO_DISABLE_SIDE_EFFECTS=0
fi

scenario_basename="$(basename "$SCENARIO_FILE")"
if [[ "$scenario_basename" == *.json ]]; then
    DEMO_SCENARIO_NAME="${scenario_basename%.json}"
fi

if [[ -z "$DEMO_SCENARIO_NAME" ]]; then
    DEMO_SCENARIO_NAME="project_flow_v1"
fi

if [[ ! -f "$SCENARIO_FILE" ]]; then
    echo "Scenario file not found: $SCENARIO_FILE" >&2
    exit 1
fi
SCENARIO_FILE="$(cd "$(dirname "$SCENARIO_FILE")" && pwd)/$(basename "$SCENARIO_FILE")"

if [[ -n "$DEMO_PROJECTS_FILE" && ! -f "$DEMO_PROJECTS_FILE" ]]; then
    echo "Projects file not found: $DEMO_PROJECTS_FILE" >&2
    exit 1
fi
if [[ -n "$DEMO_PROJECTS_FILE" ]]; then
    DEMO_PROJECTS_FILE="$(cd "$(dirname "$DEMO_PROJECTS_FILE")" && pwd)/$(basename "$DEMO_PROJECTS_FILE")"
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is required for MP4 conversion" >&2
    exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
    echo "ffprobe is required for output validation" >&2
    exit 1
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR="$PROJECT_ROOT/artifacts/demo"
ARTIFACT_STEM="${DEMO_SCENARIO_NAME//_/-}"
mkdir -p "$ARTIFACT_DIR"

LOG_FILE="$ARTIFACT_DIR/$ARTIFACT_STEM-$TIMESTAMP.log"
RAW_MOV="$ARTIFACT_DIR/$ARTIFACT_STEM-$TIMESTAMP.mov"
MP4_FILE="$ARTIFACT_DIR/$ARTIFACT_STEM-$TIMESTAMP.mp4"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "[demo] Started run at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[demo] Log: $LOG_FILE"
echo "[demo] Scenario: $SCENARIO_FILE"
echo "[demo] Demo scenario name: $DEMO_SCENARIO_NAME"
echo "[demo] Click mode: $CLICK_MODE"
echo "[demo] With Ghostty: $WITH_GHOSTTY"
echo "[demo] Demo disable side effects: $DEMO_DISABLE_SIDE_EFFECTS"
echo "[demo] Demo channel: alpha"
echo "[demo] Layout file: $LAYOUT_FILE"
if [[ -n "$DEMO_PROJECTS_FILE" ]]; then
    echo "[demo] Projects file: $DEMO_PROJECTS_FILE"
fi

DEMO_ENV_VARS=(
    CAPACITOR_DEMO_MODE
    CAPACITOR_DEMO_SCENARIO
    CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS
    CAPACITOR_DEMO_PROJECTS_FILE
    CAPACITOR_CHANNEL
)

BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/capacitor-demo-backup.XXXXXX")"
PREFERENCES_PLIST="$HOME/Library/Preferences/com.capacitor.app.debug.plist"
PROJECTS_JSON="$HOME/.capacitor/projects.json"
CREATIONS_JSON="$HOME/.capacitor/creations.json"
PROJECT_DESCRIPTIONS_JSON="$HOME/.capacitor/project-descriptions.json"
APP_DEBUG_LOG="$HOME/.capacitor/daemon/app-debug.log"
APP_DEBUG_LOG_OFFSET=0

RECORDER_PID=""
LAYOUT_GUARD_PID=""
CLEANUP_DONE=0
USING_SAVED_LAYOUT=0
LAUNCHED_DEMO_GHOSTTY=0
DEMO_GHOSTTY_PID=""

backup_file() {
    local source_path="$1"
    local key="$2"

    if [[ -e "$source_path" ]]; then
        cp -a "$source_path" "$BACKUP_DIR/$key"
        echo "present" > "$BACKUP_DIR/$key.state"
        echo "[demo] Backed up $source_path"
    else
        echo "missing" > "$BACKUP_DIR/$key.state"
        echo "[demo] Backup note: $source_path was not present"
    fi
}

restore_file() {
    local source_path="$1"
    local key="$2"

    if [[ ! -f "$BACKUP_DIR/$key.state" ]]; then
        return
    fi

    local state
    state="$(cat "$BACKUP_DIR/$key.state")"
    if [[ "$state" == "present" ]]; then
        mkdir -p "$(dirname "$source_path")"
        rm -rf "$source_path"
        cp -a "$BACKUP_DIR/$key" "$source_path"
        echo "[demo] Restored $source_path"
    else
        rm -rf "$source_path"
        echo "[demo] Removed demo-created file $source_path"
    fi
}

capture_env_state() {
    local var_name
    for var_name in "${DEMO_ENV_VARS[@]}"; do
        if value="$(launchctl getenv "$var_name" 2>/dev/null)"; then
            printf '%s' "$value" > "$BACKUP_DIR/env.$var_name.value"
            echo "present" > "$BACKUP_DIR/env.$var_name.state"
        else
            echo "missing" > "$BACKUP_DIR/env.$var_name.state"
        fi
    done
}

apply_demo_env() {
    launchctl setenv CAPACITOR_DEMO_MODE 1
    launchctl setenv CAPACITOR_DEMO_SCENARIO "$DEMO_SCENARIO_NAME"
    launchctl setenv CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS "$DEMO_DISABLE_SIDE_EFFECTS"
    if [[ -n "$DEMO_PROJECTS_FILE" ]]; then
        launchctl setenv CAPACITOR_DEMO_PROJECTS_FILE "$DEMO_PROJECTS_FILE"
    else
        launchctl unsetenv CAPACITOR_DEMO_PROJECTS_FILE 2>/dev/null || true
    fi
    launchctl setenv CAPACITOR_CHANNEL alpha

    export CAPACITOR_DEMO_MODE=1
    export CAPACITOR_DEMO_SCENARIO="$DEMO_SCENARIO_NAME"
    export CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS="$DEMO_DISABLE_SIDE_EFFECTS"
    if [[ -n "$DEMO_PROJECTS_FILE" ]]; then
        export CAPACITOR_DEMO_PROJECTS_FILE="$DEMO_PROJECTS_FILE"
    else
        unset CAPACITOR_DEMO_PROJECTS_FILE 2>/dev/null || true
    fi
    export CAPACITOR_CHANNEL=alpha

    echo "[demo] Demo environment variables applied"
}

restore_env_state() {
    local var_name
    for var_name in "${DEMO_ENV_VARS[@]}"; do
        unset "$var_name" 2>/dev/null || true
        if [[ -f "$BACKUP_DIR/env.$var_name.state" ]] && [[ "$(cat "$BACKUP_DIR/env.$var_name.state")" == "present" ]]; then
            launchctl setenv "$var_name" "$(cat "$BACKUP_DIR/env.$var_name.value")"
            echo "[demo] Restored launchctl env $var_name"
        else
            launchctl unsetenv "$var_name" 2>/dev/null || true
            echo "[demo] Cleared launchctl env $var_name"
        fi
    done
}

stop_recording_if_needed() {
    if [[ -n "$RECORDER_PID" ]] && kill -0 "$RECORDER_PID" 2>/dev/null; then
        kill -INT "$RECORDER_PID" 2>/dev/null || true
        for _ in {1..80}; do
            if ! kill -0 "$RECORDER_PID" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done

        if kill -0 "$RECORDER_PID" 2>/dev/null; then
            kill -TERM "$RECORDER_PID" 2>/dev/null || true
        fi

        wait "$RECORDER_PID" 2>/dev/null || true
        RECORDER_PID=""
    fi
}

stop_layout_guard_if_needed() {
    if [[ -n "$LAYOUT_GUARD_PID" ]] && kill -0 "$LAYOUT_GUARD_PID" 2>/dev/null; then
        kill -TERM "$LAYOUT_GUARD_PID" 2>/dev/null || true
        wait "$LAYOUT_GUARD_PID" 2>/dev/null || true
        LAYOUT_GUARD_PID=""
    fi
}

cleanup() {
    if [[ "$CLEANUP_DONE" -eq 1 ]]; then
        return
    fi
    CLEANUP_DONE=1

    local exit_code=$?

    stop_layout_guard_if_needed
    stop_recording_if_needed
    if [[ "$LAUNCHED_DEMO_GHOSTTY" -eq 1 && -n "$DEMO_GHOSTTY_PID" ]] && kill -0 "$DEMO_GHOSTTY_PID" 2>/dev/null; then
        kill -TERM "$DEMO_GHOSTTY_PID" 2>/dev/null || true
        wait "$DEMO_GHOSTTY_PID" 2>/dev/null || true
        echo "[demo] Stopped demo Ghostty instance pid=$DEMO_GHOSTTY_PID"
    fi
    restore_env_state

    restore_file "$PREFERENCES_PLIST" "preferences.plist"
    restore_file "$PROJECTS_JSON" "projects.json"
    restore_file "$CREATIONS_JSON" "creations.json"
    restore_file "$PROJECT_DESCRIPTIONS_JSON" "project-descriptions.json"

    rm -rf "$BACKUP_DIR"

    if [[ $exit_code -eq 0 ]]; then
        echo "[demo] Cleanup complete"
    else
        echo "[demo] Cleanup complete after failure (exit=$exit_code)"
    fi

    exit $exit_code
}

trap cleanup EXIT INT TERM

wait_for_pid() {
    local pattern="$1"
    local pid=""
    for _ in {1..120}; do
        pid="$(pgrep -f "$pattern" | head -n 1 || true)"
        if [[ -n "$pid" ]]; then
            printf '%s' "$pid"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

capture_app_log_offset() {
    if [[ -f "$APP_DEBUG_LOG" ]]; then
        APP_DEBUG_LOG_OFFSET="$(wc -c < "$APP_DEBUG_LOG" | tr -d '[:space:]')"
    else
        APP_DEBUG_LOG_OFFSET=0
    fi
}

tail_new_app_log() {
    [[ -f "$APP_DEBUG_LOG" ]] || return 1
    local current_size
    current_size="$(wc -c < "$APP_DEBUG_LOG" | tr -d '[:space:]')"
    if [[ -z "$current_size" || "$current_size" -le "$APP_DEBUG_LOG_OFFSET" ]]; then
        return 1
    fi
    local start_offset=$(( APP_DEBUG_LOG_OFFSET + 1 ))
    tail -c +"$start_offset" "$APP_DEBUG_LOG"
}

assert_alpha_channel() {
    local app_pid="$1"
    local plist_channel=""
    local launchctl_channel=""

    plist_channel="$(/usr/libexec/PlistBuddy -c "Print :CapacitorChannel" "$PROJECT_ROOT/apps/swift/CapacitorDebug.app/Contents/Info.plist" 2>/dev/null || true)"
    launchctl_channel="$(launchctl getenv CAPACITOR_CHANNEL 2>/dev/null || true)"

    if [[ "$plist_channel" != "alpha" ]]; then
        echo "[demo] Expected CapacitorDebug.app channel=alpha, got: ${plist_channel:-<unset>}" >&2
        return 1
    fi

    if [[ "$launchctl_channel" != "alpha" ]]; then
        echo "[demo] Expected launchctl CAPACITOR_CHANNEL=alpha, got: ${launchctl_channel:-<unset>}" >&2
        return 1
    fi

    if process_row="$(ps eww -p "$app_pid" 2>/dev/null | tail -n 1)"; then
        if [[ "$process_row" != *"CAPACITOR_CHANNEL=alpha"* ]]; then
            echo "[demo] Warning: process env does not expose CAPACITOR_CHANNEL=alpha (macOS may redact env)."
        fi
    fi

    echo "[demo] Alpha verification passed (plist=$plist_channel, launchctl=$launchctl_channel)"
}

assert_runtime_demo_alpha() {
    local timeout_seconds=20
    local deadline=$(( $(date +%s) + timeout_seconds ))

    while [[ "$(date +%s)" -lt "$deadline" ]]; do
        local new_log
        if new_log="$(tail_new_app_log 2>/dev/null)"; then
            if echo "$new_log" | rg -q "AppState\\.demo applied scenario=${DEMO_SCENARIO_NAME} .*channel=alpha"; then
                echo "[demo] Runtime alpha confirmation found in app debug log"
                return 0
            fi
            if echo "$new_log" | rg -q "AppState\\.demo fixture load failed|AppState\\.demo unknown scenario"; then
                echo "[demo] Demo runtime failed while applying fixture. See $APP_DEBUG_LOG" >&2
                return 1
            fi
        fi
        sleep 0.25
    done

    echo "[demo] Timed out waiting for runtime alpha confirmation in $APP_DEBUG_LOG" >&2
    return 1
}

ensure_ghostty_running() {
    if ! open -a Ghostty >/dev/null 2>&1; then
        echo "[demo] Failed to launch Ghostty (open -a Ghostty)" >&2
        return 1
    fi

    local pid=""
    for _ in {1..120}; do
        pid="$(pgrep -x ghostty | head -n 1 || true)"
        if [[ -z "$pid" ]]; then
            pid="$(pgrep -x Ghostty | head -n 1 || true)"
        fi
        if [[ -n "$pid" ]]; then
            printf '%s' "$pid"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

ghostty_pids() {
    {
        pgrep -x ghostty 2>/dev/null || true
        pgrep -x Ghostty 2>/dev/null || true
    } | awk 'NF' | sort -n -u
}

resolve_initial_tmux_session_name() {
    local slug=""
    if command -v jq >/dev/null 2>&1; then
        slug="$(jq -r '
            first(
                .steps[]
                | select(.type == "click" and (.identifier | startswith("demo.project-card.")))
                | .identifier
                | split(".")
                | .[-1]
            ) // empty
        ' "$SCENARIO_FILE" 2>/dev/null || true)"
    fi

    if [[ -z "$slug" || "$slug" == "null" ]]; then
        slug="tool-ui"
    fi

    printf '%s' "$slug"
}

launch_demo_ghostty_tmux_window() {
    local session_name="$1"
    local before_pids after_pids new_pid
    before_pids="$(ghostty_pids)"

    if ! open -na Ghostty.app --args -e sh -lc "tmux new-session -A -s '$session_name'" >/dev/null 2>&1; then
        return 1
    fi

    for _ in {1..120}; do
        after_pids="$(ghostty_pids)"
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            if ! echo "$before_pids" | awk '{print $1}' | grep -qx "$pid"; then
                new_pid="$pid"
                break
            fi
        done <<< "$after_pids"

        if [[ -n "${new_pid:-}" ]]; then
            printf '%s' "$new_pid"
            return 0
        fi

        sleep 0.25
    done

    # Fallback: if we couldn't detect the delta, use the newest Ghostty pid.
    new_pid="$(echo "$after_pids" | tail -n 1)"
    [[ -n "$new_pid" ]] || return 1
    printf '%s' "$new_pid"
    return 0
}

resolve_single_window_bounds() {
    local app_pid="$1"

    osascript <<APPLESCRIPT
try
    tell application "System Events"
        set targetProcess to first process whose unix id is $app_pid
        repeat 120 times
            if (count of windows of targetProcess) > 0 then
                exit repeat
            end if
            delay 0.25
        end repeat

        tell targetProcess
            if (count of windows) is 0 then error "No window found for process"
            set frontmost to true
            set win to front window
            set {xPos, yPos} to position of win
            set {wVal, hVal} to size of win
            return (xPos as integer as string) & "|" & (yPos as integer as string) & "|" & (wVal as integer as string) & "|" & (hVal as integer as string)
        end tell
    end tell
on error errMsg
    return "ERROR:" & errMsg
end try
APPLESCRIPT
}

resolve_screen_bounds() {
    osascript <<'APPLESCRIPT'
try
    tell application "System Events"
        set screenBounds to {0, 0, 1728, 1117}
        try
            set screenBounds to bounds of window of desktop
        end try
    end tell

    set leftEdge to item 1 of screenBounds as integer
    set topEdge to item 2 of screenBounds as integer
    set rightEdge to item 3 of screenBounds as integer
    set bottomEdge to item 4 of screenBounds as integer

    set widthVal to rightEdge - leftEdge
    set heightVal to bottomEdge - topEdge

    return (leftEdge as string) & "|" & (topEdge as string) & "|" & (widthVal as string) & "|" & (heightVal as string)
on error errMsg
    return "ERROR:" & errMsg
end try
APPLESCRIPT
}

resolve_dual_window_bounds() {
    local capacitor_pid="$1"
    local ghostty_pid="$2"

    osascript <<APPLESCRIPT
try

    tell application "System Events"
        set capProc to first process whose unix id is $capacitor_pid
        set ghostProc to first process whose unix id is $ghostty_pid

        repeat 120 times
            if ((count of windows of capProc) > 0) and ((count of windows of ghostProc) > 0) then
                exit repeat
            end if
            delay 0.25
        end repeat

        if (count of windows of capProc) is 0 then error "No window found for Capacitor process"
        if (count of windows of ghostProc) is 0 then error "No window found for Ghostty process"

        set screenBounds to {0, 0, 1728, 1117}
        try
            tell application "Finder"
                set screenBounds to bounds of window of desktop
            end tell
        end try

        set screenLeft to item 1 of screenBounds as integer
        set screenTop to item 2 of screenBounds as integer
        set screenRight to item 3 of screenBounds as integer
        set screenBottom to item 4 of screenBounds as integer
        set screenWidth to screenRight - screenLeft
        set screenHeight to screenBottom - screenTop

        set margin to 32
        set gutter to 20
        set availableWidth to screenWidth - (margin * 2) - gutter
        if availableWidth < 700 then set availableWidth to screenWidth - 40
        if availableWidth < 400 then error "Display too narrow for side-by-side layout"

        set panelWidth to availableWidth div 2
        set panelHeight to screenHeight - (margin * 2)
        if panelHeight > 980 then set panelHeight to 980
        if panelHeight < 480 then set panelHeight to 480

        set capX to screenLeft + margin
        set capY to screenTop + margin
        set ghostX to capX + panelWidth + gutter
        set ghostY to capY

        tell capProc
            set frontmost to true
            set capWin to front window
            set position of capWin to {capX, capY}
            set size of capWin to {panelWidth, panelHeight}
        end tell

        tell ghostProc
            set frontmost to true
            set ghostWin to front window
            set ghostWindowCount to count of windows
            repeat with idx from 1 to ghostWindowCount
                set candidateWindow to window idx
                try
                    set candidateTitle to (name of candidateWindow) as string
                on error
                    set candidateTitle to ""
                end try
                if candidateTitle contains ":" then
                    set ghostWin to candidateWindow
                    exit repeat
                end if
            end repeat
            set position of ghostWin to {ghostX, ghostY}
            set size of ghostWin to {panelWidth, panelHeight}
        end tell

        delay 0.35

        tell capProc
            set capWin to front window
            set {capXPos, capYPos} to position of capWin
            set {capWVal, capHVal} to size of capWin
        end tell

        tell ghostProc
            set ghostWin to front window
            set ghostWindowCount to count of windows
            repeat with idx from 1 to ghostWindowCount
                set candidateWindow to window idx
                try
                    set candidateTitle to (name of candidateWindow) as string
                on error
                    set candidateTitle to ""
                end try
                if candidateTitle contains ":" then
                    set ghostWin to candidateWindow
                    exit repeat
                end if
            end repeat
            set {ghostXPos, ghostYPos} to position of ghostWin
            set {ghostWVal, ghostHVal} to size of ghostWin
        end tell

        set leftEdge to capXPos
        if ghostXPos < leftEdge then set leftEdge to ghostXPos

        set topEdge to capYPos
        if ghostYPos < topEdge then set topEdge to ghostYPos

        set capRight to capXPos + capWVal
        set ghostRight to ghostXPos + ghostWVal
        set rightEdge to capRight
        if ghostRight > rightEdge then set rightEdge to ghostRight

        set capBottom to capYPos + capHVal
        set ghostBottom to ghostYPos + ghostHVal
        set bottomEdge to capBottom
        if ghostBottom > bottomEdge then set bottomEdge to ghostBottom

        set unionW to rightEdge - leftEdge
        set unionH to bottomEdge - topEdge

        return (leftEdge as integer as string) & "|" & (topEdge as integer as string) & "|" & (unionW as integer as string) & "|" & (unionH as integer as string)
    end tell
on error errMsg
    return "ERROR:" & errMsg
end try
APPLESCRIPT
}

load_saved_layout() {
    local layout_file="$1"
    [[ -f "$layout_file" ]] || return 1

    # shellcheck disable=SC1090
    source "$layout_file"

    for required_var in CAP_X CAP_Y CAP_W CAP_H GHOST_X GHOST_Y GHOST_W GHOST_H; do
        if [[ -z "${!required_var:-}" ]]; then
            echo "[demo] Saved layout missing required value: $required_var" >&2
            return 1
        fi
        if ! [[ "${!required_var}" =~ ^-?[0-9]+$ ]]; then
            echo "[demo] Saved layout value is not numeric: $required_var=${!required_var}" >&2
            return 1
        fi
    done

    SAVED_CAP_X="$CAP_X"
    SAVED_CAP_Y="$CAP_Y"
    SAVED_CAP_W="$CAP_W"
    SAVED_CAP_H="$CAP_H"
    SAVED_GHOST_X="$GHOST_X"
    SAVED_GHOST_Y="$GHOST_Y"
    SAVED_GHOST_W="$GHOST_W"
    SAVED_GHOST_H="$GHOST_H"
    return 0
}

resolve_dual_window_bounds_from_saved_layout() {
    local capacitor_pid="$1"
    local ghostty_pid="$2"

    osascript <<APPLESCRIPT
try

    tell application "System Events"
        set capProc to first process whose unix id is $capacitor_pid
        set ghostProc to first process whose unix id is $ghostty_pid

        repeat 120 times
            if ((count of windows of capProc) > 0) and ((count of windows of ghostProc) > 0) then
                exit repeat
            end if
            delay 0.25
        end repeat

        if (count of windows of capProc) is 0 then error "No window found for Capacitor process"
        if (count of windows of ghostProc) is 0 then error "No window found for Ghostty process"

        tell capProc
            set capWin to front window
            set position of capWin to {$SAVED_CAP_X, $SAVED_CAP_Y}
            set size of capWin to {$SAVED_CAP_W, $SAVED_CAP_H}
        end tell

        tell ghostProc
            set ghostWin to front window
            set ghostWindowCount to count of windows
            repeat with idx from 1 to ghostWindowCount
                set candidateWindow to window idx
                try
                    set candidateTitle to (name of candidateWindow) as string
                on error
                    set candidateTitle to ""
                end try
                if candidateTitle contains ":" then
                    set ghostWin to candidateWindow
                    exit repeat
                end if
            end repeat
            set position of ghostWin to {$SAVED_GHOST_X, $SAVED_GHOST_Y}
            set size of ghostWin to {$SAVED_GHOST_W, $SAVED_GHOST_H}
        end tell

        delay 0.60

        tell capProc
            set capWin to front window
            set {capXPos, capYPos} to position of capWin
            set {capWVal, capHVal} to size of capWin
        end tell

        tell ghostProc
            set ghostWin to front window
            set ghostWindowCount to count of windows
            repeat with idx from 1 to ghostWindowCount
                set candidateWindow to window idx
                try
                    set candidateTitle to (name of candidateWindow) as string
                on error
                    set candidateTitle to ""
                end try
                if candidateTitle contains ":" then
                    set ghostWin to candidateWindow
                    exit repeat
                end if
            end repeat
            set {ghostXPos, ghostYPos} to position of ghostWin
            set {ghostWVal, ghostHVal} to size of ghostWin
        end tell

        set leftEdge to capXPos
        if ghostXPos < leftEdge then set leftEdge to ghostXPos

        set topEdge to capYPos
        if ghostYPos < topEdge then set topEdge to ghostYPos

        set capRight to capXPos + capWVal
        set ghostRight to ghostXPos + ghostWVal
        set rightEdge to capRight
        if ghostRight > rightEdge then set rightEdge to ghostRight

        set capBottom to capYPos + capHVal
        set ghostBottom to ghostYPos + ghostHVal
        set bottomEdge to capBottom
        if ghostBottom > bottomEdge then set bottomEdge to ghostBottom

        set unionW to rightEdge - leftEdge
        set unionH to bottomEdge - topEdge

        return (leftEdge as integer as string) & "|" & (topEdge as integer as string) & "|" & (unionW as integer as string) & "|" & (unionH as integer as string)
    end tell
on error errMsg
    return "ERROR:" & errMsg
end try
APPLESCRIPT
}

start_layout_guard() {
    local capacitor_pid="$1"
    local ghostty_pid="$2"

    if [[ "$WITH_GHOSTTY" -ne 1 || "$USING_SAVED_LAYOUT" -ne 1 ]]; then
        return 0
    fi

    (
        while true; do
            osascript >/dev/null 2>&1 <<APPLESCRIPT
try

    tell application "System Events"
        set capProc to first process whose unix id is $capacitor_pid
        set ghostProc to first process whose unix id is $ghostty_pid

        tell capProc
            if (count of windows) > 0 then
                set capWin to front window
                set position of capWin to {$SAVED_CAP_X, $SAVED_CAP_Y}
                set size of capWin to {$SAVED_CAP_W, $SAVED_CAP_H}
            end if
        end tell

        tell ghostProc
            if (count of windows) > 0 then
                set ghostWin to front window
                set ghostWindowCount to count of windows
                repeat with idx from 1 to ghostWindowCount
                    set candidateWindow to window idx
                    try
                        set candidateTitle to (name of candidateWindow) as string
                    on error
                        set candidateTitle to ""
                    end try
                    if candidateTitle contains ":" then
                        set ghostWin to candidateWindow
                        exit repeat
                    end if
                end repeat
                set position of ghostWin to {$SAVED_GHOST_X, $SAVED_GHOST_Y}
                set size of ghostWin to {$SAVED_GHOST_W, $SAVED_GHOST_H}
            end if
        end tell
    end tell
end try
APPLESCRIPT
            sleep 0.2
        done
    ) &
    LAYOUT_GUARD_PID=$!
    echo "[demo] Layout guard started (pid=$LAYOUT_GUARD_PID)"
}

capture_env_state
backup_file "$PREFERENCES_PLIST" "preferences.plist"
backup_file "$PROJECTS_JSON" "projects.json"
backup_file "$CREATIONS_JSON" "creations.json"
backup_file "$PROJECT_DESCRIPTIONS_JSON" "project-descriptions.json"

apply_demo_env
capture_app_log_offset

echo "[demo] Restarting app"
# Signal restart script to preserve the demo env vars we just applied.
CAPACITOR_DEMO_ENV_PRESERVE=1 "$PROJECT_ROOT/scripts/dev/restart-app.sh" --alpha

APP_PID="$(wait_for_pid "$APP_BINARY$")" || {
    echo "[demo] Unable to find app process for $APP_BINARY" >&2
    exit 1
}

echo "[demo] App PID: $APP_PID"
assert_alpha_channel "$APP_PID"
assert_runtime_demo_alpha

GHOSTTY_PID=""
if [[ "$WITH_GHOSTTY" -eq 1 ]]; then
    initial_tmux_session="$(resolve_initial_tmux_session_name)"
    echo "[demo] Starting dedicated Ghostty tmux window for session: $initial_tmux_session"
    if GHOSTTY_PID="$(launch_demo_ghostty_tmux_window "$initial_tmux_session")"; then
        LAUNCHED_DEMO_GHOSTTY=1
        DEMO_GHOSTTY_PID="$GHOSTTY_PID"
    else
        echo "[demo] Dedicated Ghostty launch failed; falling back to existing Ghostty process"
        GHOSTTY_PID="$(ensure_ghostty_running)" || {
            echo "[demo] Unable to find Ghostty process after launch" >&2
            exit 1
        }
    fi
    echo "[demo] Ghostty PID: $GHOSTTY_PID"
fi

if [[ "$WITH_GHOSTTY" -eq 1 ]]; then
    if load_saved_layout "$LAYOUT_FILE"; then
        echo "[demo] Applying saved layout from $LAYOUT_FILE"
        USING_SAVED_LAYOUT=1
        WINDOW_BOUNDS="$(resolve_dual_window_bounds_from_saved_layout "$APP_PID" "$GHOSTTY_PID")"
    else
        echo "[demo] No valid saved layout found. Falling back to auto-tiling."
        USING_SAVED_LAYOUT=0
        WINDOW_BOUNDS="$(resolve_dual_window_bounds "$APP_PID" "$GHOSTTY_PID")"
    fi
else
    WINDOW_BOUNDS="$(resolve_single_window_bounds "$APP_PID")"
fi

if [[ "$WINDOW_BOUNDS" == ERROR:* ]]; then
    echo "[demo] Failed to resolve window bounds: ${WINDOW_BOUNDS#ERROR:}" >&2
    exit 1
fi

IFS='|' read -r raw_x raw_y raw_w raw_h <<< "$WINDOW_BOUNDS"
raw_x="$(echo "$raw_x" | tr -d '[:space:]')"
raw_y="$(echo "$raw_y" | tr -d '[:space:]')"
raw_w="$(echo "$raw_w" | tr -d '[:space:]')"
raw_h="$(echo "$raw_h" | tr -d '[:space:]')"

if ! [[ "$raw_x" =~ ^-?[0-9]+$ && "$raw_y" =~ ^-?[0-9]+$ && "$raw_w" =~ ^[0-9]+$ && "$raw_h" =~ ^[0-9]+$ ]]; then
    echo "[demo] Invalid bounds payload: $WINDOW_BOUNDS" >&2
    exit 1
fi

x=$(( raw_x < 0 ? 0 : raw_x ))
y=$(( raw_y < 0 ? 0 : raw_y ))
w=$(( raw_w ))
h=$(( raw_h ))

if [[ "$w" -le 0 || "$h" -le 0 ]]; then
    echo "[demo] Invalid capture bounds: $x,$y,$w,$h" >&2
    exit 1
fi

if [[ "$RECORD_PADDING" -gt 0 ]]; then
    screen_payload="$(resolve_screen_bounds)"
    if [[ "$screen_payload" != ERROR:* ]]; then
        IFS='|' read -r screen_left_raw screen_top_raw screen_w_raw screen_h_raw <<< "$screen_payload"
        screen_left_raw="$(echo "$screen_left_raw" | tr -d '[:space:]')"
        screen_top_raw="$(echo "$screen_top_raw" | tr -d '[:space:]')"
        screen_w_raw="$(echo "$screen_w_raw" | tr -d '[:space:]')"
        screen_h_raw="$(echo "$screen_h_raw" | tr -d '[:space:]')"

        if [[ "$screen_left_raw" =~ ^-?[0-9]+$ && "$screen_top_raw" =~ ^-?[0-9]+$ && "$screen_w_raw" =~ ^[0-9]+$ && "$screen_h_raw" =~ ^[0-9]+$ ]]; then
            screen_left=$screen_left_raw
            screen_top=$screen_top_raw
            screen_right=$(( screen_left + screen_w_raw ))
            screen_bottom=$(( screen_top + screen_h_raw ))

            padded_left=$(( x - RECORD_PADDING ))
            padded_top=$(( y - RECORD_PADDING ))
            padded_right=$(( x + w + RECORD_PADDING ))
            padded_bottom=$(( y + h + RECORD_PADDING ))

            if (( padded_left < screen_left )); then padded_left=$screen_left; fi
            if (( padded_top < screen_top )); then padded_top=$screen_top; fi
            if (( padded_right > screen_right )); then padded_right=$screen_right; fi
            if (( padded_bottom > screen_bottom )); then padded_bottom=$screen_bottom; fi

            padded_w=$(( padded_right - padded_left ))
            padded_h=$(( padded_bottom - padded_top ))

            if (( padded_w > 0 && padded_h > 0 )); then
                x=$padded_left
                y=$padded_top
                w=$padded_w
                h=$padded_h
            fi
        fi
    fi
fi

echo "[demo] Recording padding: ${RECORD_PADDING}px"
echo "[demo] Recording bounds: $x,$y,$w,$h"

/usr/sbin/screencapture -v -V "$RECORD_SECONDS" -k -R"$x,$y,$w,$h" "$RAW_MOV" >/dev/null 2>&1 &
RECORDER_PID=$!
echo "[demo] Recording started (pid=$RECORDER_PID)"
start_layout_guard "$APP_PID" "$GHOSTTY_PID"

sleep 1.0

echo "[demo] Running AX scenario"
swift "$AX_RUNNER" --bundle-id "$BUNDLE_ID" --scenario "$SCENARIO_FILE" --click-mode "$CLICK_MODE"

if [[ -n "$RECORDER_PID" ]] && kill -0 "$RECORDER_PID" 2>/dev/null; then
    echo "[demo] Waiting for timed recording to finish ($RECORD_SECONDS s target)"
    wait "$RECORDER_PID"
    RECORDER_PID=""
fi
stop_layout_guard_if_needed

echo "[demo] Converting MOV to MP4"
ffmpeg -y -i "$RAW_MOV" -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$MP4_FILE"

if [[ ! -s "$MP4_FILE" ]]; then
    echo "[demo] MP4 output is missing or empty: $MP4_FILE" >&2
    exit 1
fi

duration="$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$MP4_FILE")"
frame_count="$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 "$MP4_FILE")"

if [[ -z "$frame_count" || "$frame_count" == "N/A" ]]; then
    frame_count="$(ffprobe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of default=nokey=1:noprint_wrappers=1 "$MP4_FILE")"
fi

if [[ -z "$duration" ]]; then
    echo "[demo] Failed to read output duration" >&2
    exit 1
fi

expected_min=$(( RECORD_SECONDS > 8 ? RECORD_SECONDS - 5 : 3 ))
expected_max=$(( RECORD_SECONDS + 5 ))
if ! awk "BEGIN { exit !($duration >= $expected_min && $duration <= $expected_max) }"; then
    echo "[demo] Duration check failed: ${duration}s (expected ${expected_min}-${expected_max}s)" >&2
    exit 1
fi

if [[ -z "$frame_count" || "$frame_count" == "N/A" || "$frame_count" -le 0 ]]; then
    echo "[demo] Frame-count validation failed: $frame_count" >&2
    exit 1
fi

echo "[demo] Validation passed"
echo "[demo] MP4: $MP4_FILE"
echo "[demo] LOG: $LOG_FILE"
