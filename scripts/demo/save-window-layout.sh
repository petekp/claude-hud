#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_FILE="$PROJECT_ROOT/artifacts/demo/window-layout.env"
APP_BINARY="$PROJECT_ROOT/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor"

usage() {
    cat <<USAGE
Usage: ./scripts/demo/save-window-layout.sh [--output <path>]

Captures current Capacitor + Ghostty window positions/sizes and writes a layout env file.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --output)
        [[ $# -ge 2 ]] || { echo "--output requires a value" >&2; exit 1; }
        OUTPUT_FILE="$2"
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

CAP_PID="$(pgrep -f "$APP_BINARY$" | head -n 1 || true)"
GHOST_PID="$(pgrep -x ghostty | head -n 1 || true)"

if [[ -z "$CAP_PID" ]]; then
    echo "Capacitor debug process not found. Launch the app first." >&2
    exit 1
fi

if [[ -z "$GHOST_PID" ]]; then
    echo "Ghostty process not found. Launch Ghostty first." >&2
    exit 1
fi

BOUNDS="$(osascript <<APPLESCRIPT
try
    tell application "System Events"
        set capProc to first process whose unix id is $CAP_PID
        set ghostProc to first process whose unix id is $GHOST_PID

        if (count of windows of capProc) is 0 then error "Capacitor window not found"
        if (count of windows of ghostProc) is 0 then error "Ghostty window not found"

        tell capProc
            set capWin to front window
            set {capX, capY} to position of capWin
            set {capW, capH} to size of capWin
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
            set {ghostX, ghostY} to position of ghostWin
            set {ghostW, ghostH} to size of ghostWin
        end tell

        set leftEdge to capX
        if ghostX < leftEdge then set leftEdge to ghostX
        set topEdge to capY
        if ghostY < topEdge then set topEdge to ghostY

        set capRight to capX + capW
        set ghostRight to ghostX + ghostW
        set rightEdge to capRight
        if ghostRight > rightEdge then set rightEdge to ghostRight

        set capBottom to capY + capH
        set ghostBottom to ghostY + ghostH
        set bottomEdge to capBottom
        if ghostBottom > bottomEdge then set bottomEdge to ghostBottom

        set unionW to rightEdge - leftEdge
        set unionH to bottomEdge - topEdge

        return (capX as integer as string) & "|" & (capY as integer as string) & "|" & (capW as integer as string) & "|" & (capH as integer as string) & "|" & (ghostX as integer as string) & "|" & (ghostY as integer as string) & "|" & (ghostW as integer as string) & "|" & (ghostH as integer as string) & "|" & (leftEdge as integer as string) & "|" & (topEdge as integer as string) & "|" & (unionW as integer as string) & "|" & (unionH as integer as string)
    end tell
on error errMsg
    return "ERROR:" & errMsg
end try
APPLESCRIPT
)"

if [[ "$BOUNDS" == ERROR:* ]]; then
    echo "${BOUNDS#ERROR:}" >&2
    exit 1
fi

IFS='|' read -r CAP_X CAP_Y CAP_W CAP_H GHOST_X GHOST_Y GHOST_W GHOST_H REC_X REC_Y REC_W REC_H <<< "$BOUNDS"
mkdir -p "$(dirname "$OUTPUT_FILE")"

cat > "$OUTPUT_FILE" <<EOF
# Captured by scripts/demo/save-window-layout.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)
CAP_X=$CAP_X
CAP_Y=$CAP_Y
CAP_W=$CAP_W
CAP_H=$CAP_H
GHOST_X=$GHOST_X
GHOST_Y=$GHOST_Y
GHOST_W=$GHOST_W
GHOST_H=$GHOST_H
REC_X=$REC_X
REC_Y=$REC_Y
REC_W=$REC_W
REC_H=$REC_H
EOF

echo "Saved layout to $OUTPUT_FILE"
echo "Capacitor: $CAP_X,$CAP_Y,$CAP_W,$CAP_H"
echo "Ghostty:   $GHOST_X,$GHOST_Y,$GHOST_W,$GHOST_H"
echo "Recording: $REC_X,$REC_Y,$REC_W,$REC_H"
