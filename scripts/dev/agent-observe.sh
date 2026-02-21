#!/usr/bin/env bash
set -euo pipefail

CAP_HOME="${CAPACITOR_HOME:-$HOME/.capacitor}"
DAEMON_DIR="${CAP_HOME}/daemon"
SOCKET_PATH="${CAPACITOR_DAEMON_SOCKET:-${CAP_HOME}/daemon.sock}"
DB_PATH="${CAPACITOR_DAEMON_DB:-${DAEMON_DIR}/state.db}"
APP_LOG_PATH="${CAPACITOR_APP_DEBUG_LOG:-${DAEMON_DIR}/app-debug.log}"
DAEMON_STDERR_LOG_PATH="${CAPACITOR_DAEMON_STDERR_LOG:-${DAEMON_DIR}/daemon.stderr.log}"
DAEMON_STDOUT_LOG_PATH="${CAPACITOR_DAEMON_STDOUT_LOG:-${DAEMON_DIR}/daemon.stdout.log}"
TRANSPARENT_UI_BASE_URL="${CAPACITOR_TRANSPARENT_UI_BASE_URL:-http://localhost:9133}"

usage() {
  cat <<'EOF'
Usage: scripts/dev/agent-observe.sh <command> [args...]

Canonical agent observability helper for Capacitor.

Commands:
  check                                  Validate local observability dependencies and paths
  paths                                  Print canonical paths + endpoint roots
  health                                 IPC: get_health
  sessions                               IPC: get_sessions
  projects                               IPC: get_project_states
  shells                                 IPC: get_shell_state
  activity [limit]                       IPC: get_activity (default limit=50)
  routing-snapshot <project_path> [ws]   IPC: get_routing_snapshot
  routing-diagnostics <project_path> [ws] IPC: get_routing_diagnostics
  ipc <method> [params_json]             IPC: arbitrary daemon method call
  telemetry [limit]                      Transparent UI: GET /telemetry
  snapshot                               Transparent UI: GET /daemon-snapshot
  briefing [limit]                       Transparent UI: GET /agent-briefing
  stream                                 Transparent UI: GET /telemetry-stream (SSE passthrough)
  sql <query>                            sqlite3 query against ~/.capacitor/daemon/state.db
  tail <app|daemon-stderr|daemon-stdout> Tail key logs

Examples:
  scripts/dev/agent-observe.sh check
  scripts/dev/agent-observe.sh health
  scripts/dev/agent-observe.sh activity 120
  scripts/dev/agent-observe.sh routing-snapshot /Users/petepetrash/Code/capacitor
  scripts/dev/agent-observe.sh sql "SELECT event_type, COUNT(*) FROM events GROUP BY event_type ORDER BY COUNT(*) DESC LIMIT 20;"
EOF
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

pretty_print_json() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  else
    cat
  fi
}

send_ipc() {
  require_cmd nc
  local method="$1"
  local params="${2:-null}"
  local request_id="agent-observe-${method}-$(date +%s)"

  if [[ ! -S "$SOCKET_PATH" ]]; then
    echo "Daemon socket not found: $SOCKET_PATH" >&2
    exit 1
  fi

  printf '{"protocol_version":1,"method":"%s","id":"%s","params":%s}\n' \
    "$method" "$request_id" "$params" \
    | nc -U "$SOCKET_PATH" \
    | pretty_print_json
}

http_get_json() {
  require_cmd curl
  local url="$1"
  curl -fsS "$url" | pretty_print_json
}

build_project_params() {
  local project_path="$1"
  local workspace_id="${2:-}"
  if [[ -n "$workspace_id" ]]; then
    printf '{"project_path":"%s","workspace_id":"%s"}' "$project_path" "$workspace_id"
  else
    printf '{"project_path":"%s"}' "$project_path"
  fi
}

check() {
  local ok=1
  echo "Socket: $SOCKET_PATH"
  if [[ -S "$SOCKET_PATH" ]]; then
    echo "  ok (socket exists)"
  else
    echo "  missing"
    ok=0
  fi

  echo "DB: $DB_PATH"
  if [[ -f "$DB_PATH" ]]; then
    echo "  ok (database exists)"
  else
    echo "  missing"
    ok=0
  fi

  echo "App log: $APP_LOG_PATH"
  [[ -f "$APP_LOG_PATH" ]] && echo "  ok" || echo "  missing"

  echo "Daemon stderr log: $DAEMON_STDERR_LOG_PATH"
  [[ -f "$DAEMON_STDERR_LOG_PATH" ]] && echo "  ok" || echo "  missing"

  echo "Daemon stdout log: $DAEMON_STDOUT_LOG_PATH"
  [[ -f "$DAEMON_STDOUT_LOG_PATH" ]] && echo "  ok" || echo "  missing"

  echo "Transparent UI: $TRANSPARENT_UI_BASE_URL"
  if curl -fsS "${TRANSPARENT_UI_BASE_URL}/daemon-snapshot" >/dev/null 2>&1; then
    echo "  ok (reachable)"
  else
    echo "  not reachable"
  fi

  if [[ "$ok" -eq 0 ]]; then
    exit 1
  fi
}

paths() {
  cat <<EOF
socket_path=$SOCKET_PATH
db_path=$DB_PATH
app_log_path=$APP_LOG_PATH
daemon_stderr_log_path=$DAEMON_STDERR_LOG_PATH
daemon_stdout_log_path=$DAEMON_STDOUT_LOG_PATH
transparent_ui_base_url=$TRANSPARENT_UI_BASE_URL
telemetry_endpoint=${TRANSPARENT_UI_BASE_URL}/telemetry
telemetry_stream_endpoint=${TRANSPARENT_UI_BASE_URL}/telemetry-stream
daemon_snapshot_endpoint=${TRANSPARENT_UI_BASE_URL}/daemon-snapshot
agent_briefing_endpoint=${TRANSPARENT_UI_BASE_URL}/agent-briefing
EOF
}

command="${1:-help}"
shift || true

case "$command" in
  help|-h|--help)
    usage
    ;;
  check)
    check
    ;;
  paths)
    paths
    ;;
  health)
    send_ipc "get_health"
    ;;
  sessions)
    send_ipc "get_sessions"
    ;;
  projects)
    send_ipc "get_project_states"
    ;;
  shells)
    send_ipc "get_shell_state"
    ;;
  activity)
    limit="${1:-50}"
    send_ipc "get_activity" "{\"limit\":${limit}}"
    ;;
  routing-snapshot)
    if [[ $# -lt 1 ]]; then
      echo "Usage: scripts/dev/agent-observe.sh routing-snapshot <project_path> [workspace_id]" >&2
      exit 1
    fi
    project_path="$1"
    workspace_id="${2:-}"
    send_ipc "get_routing_snapshot" "$(build_project_params "$project_path" "$workspace_id")"
    ;;
  routing-diagnostics)
    if [[ $# -lt 1 ]]; then
      echo "Usage: scripts/dev/agent-observe.sh routing-diagnostics <project_path> [workspace_id]" >&2
      exit 1
    fi
    project_path="$1"
    workspace_id="${2:-}"
    send_ipc "get_routing_diagnostics" "$(build_project_params "$project_path" "$workspace_id")"
    ;;
  ipc)
    if [[ $# -lt 1 ]]; then
      echo "Usage: scripts/dev/agent-observe.sh ipc <method> [params_json]" >&2
      exit 1
    fi
    method="$1"
    params="${2:-null}"
    send_ipc "$method" "$params"
    ;;
  telemetry)
    limit="${1:-200}"
    http_get_json "${TRANSPARENT_UI_BASE_URL}/telemetry?limit=${limit}"
    ;;
  snapshot)
    http_get_json "${TRANSPARENT_UI_BASE_URL}/daemon-snapshot"
    ;;
  briefing)
    limit="${1:-200}"
    http_get_json "${TRANSPARENT_UI_BASE_URL}/agent-briefing?limit=${limit}"
    ;;
  stream)
    require_cmd curl
    curl -N -fsS "${TRANSPARENT_UI_BASE_URL}/telemetry-stream"
    ;;
  sql)
    if [[ $# -lt 1 ]]; then
      echo "Usage: scripts/dev/agent-observe.sh sql <query>" >&2
      exit 1
    fi
    require_cmd sqlite3
    query="$1"
    if [[ ! -f "$DB_PATH" ]]; then
      echo "Database not found: $DB_PATH" >&2
      exit 1
    fi
    sqlite3 -header -column "$DB_PATH" "$query"
    ;;
  tail)
    if [[ $# -lt 1 ]]; then
      echo "Usage: scripts/dev/agent-observe.sh tail <app|daemon-stderr|daemon-stdout>" >&2
      exit 1
    fi
    target="$1"
    case "$target" in
      app)
        exec tail -f "$APP_LOG_PATH"
        ;;
      daemon-stderr)
        exec tail -f "$DAEMON_STDERR_LOG_PATH"
        ;;
      daemon-stdout)
        exec tail -f "$DAEMON_STDOUT_LOG_PATH"
        ;;
      *)
        echo "Unknown tail target: $target" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Unknown command: $command" >&2
    usage
    exit 1
    ;;
esac
