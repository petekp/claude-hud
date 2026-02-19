#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TEST_DIR="$(mktemp -d)"
    TEST_BIN="$TEST_DIR/bin"
    mkdir -p "$TEST_BIN"
    LAUNCHCTL_LOG="$TEST_DIR/launchctl.log"
    : > "$LAUNCHCTL_LOG"

    cat > "$TEST_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${LAUNCHCTL_LOG:?}"
exit 0
EOF
    chmod +x "$TEST_BIN/launchctl"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "restart-app clears demo env from launchctl by default even if inherited in shell" {
    run env \
        PATH="$TEST_BIN:$PATH" \
        LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
        CAPACITOR_DEMO_MODE=1 \
        CAPACITOR_DEMO_SCENARIO=project_flow_states_v1 \
        CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS=0 \
        CAPACITOR_DEMO_PROJECTS_FILE=/tmp/demo-projects.json \
        "$PROJECT_ROOT/scripts/dev/restart-app.sh" --help

    [ "$status" -eq 0 ]

    run grep -F "unsetenv CAPACITOR_DEMO_MODE" "$LAUNCHCTL_LOG"
    [ "$status" -eq 0 ]
    run grep -F "unsetenv CAPACITOR_DEMO_SCENARIO" "$LAUNCHCTL_LOG"
    [ "$status" -eq 0 ]
    run grep -F "unsetenv CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS" "$LAUNCHCTL_LOG"
    [ "$status" -eq 0 ]
    run grep -F "unsetenv CAPACITOR_DEMO_PROJECTS_FILE" "$LAUNCHCTL_LOG"
    [ "$status" -eq 0 ]
}

@test "demo runner explicitly preserves demo env when restarting app for recordings" {
    run grep -En 'CAPACITOR_DEMO_ENV_PRESERVE=1 .*scripts/dev/restart-app.sh"? --alpha' \
        "$PROJECT_ROOT/scripts/demo/run-vertical-slice.sh"
    [ "$status" -eq 0 ]
}

@test "restart-app explicitly unsets demo env vars from its own process before launch" {
    run grep -En 'unset "\$_var"' "$PROJECT_ROOT/scripts/dev/restart-app.sh"
    [ "$status" -eq 0 ]
}
