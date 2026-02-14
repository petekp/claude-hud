use capacitor_daemon_protocol::{
    EventEnvelope, EventType, Method, Request, Response, PROTOCOL_VERSION,
};
use chrono::{Duration as ChronoDuration, Utc};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

struct DaemonGuard {
    child: Child,
}

impl Drop for DaemonGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn spawn_daemon(home: &Path) -> Child {
    Command::new(env!("CARGO_BIN_EXE_capacitor-daemon"))
        .env("HOME", home)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("Failed to spawn capacitor-daemon")
}

fn socket_path(home: &Path) -> PathBuf {
    home.join(".capacitor").join("daemon.sock")
}

fn can_bind_socket(home: &Path) -> bool {
    let probe_path = home.join("probe.sock");
    match UnixListener::bind(&probe_path) {
        Ok(listener) => {
            drop(listener);
            let _ = fs::remove_file(&probe_path);
            true
        }
        Err(err) if err.kind() == std::io::ErrorKind::PermissionDenied => false,
        Err(_) => true,
    }
}

fn wait_for_socket(path: &Path, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if path.exists() {
            return;
        }
        sleep(Duration::from_millis(25));
    }
    panic!("Timed out waiting for daemon socket at {}", path.display());
}

fn canonicalize_path(path: &str) -> String {
    std::fs::canonicalize(path)
        .unwrap_or_else(|_| PathBuf::from(path))
        .to_string_lossy()
        .to_string()
}

fn send_request(socket: &Path, request: Request) -> Response {
    let mut stream = UnixStream::connect(socket).expect("Failed to connect to daemon socket");
    serde_json::to_writer(&mut stream, &request).expect("Failed to serialize request");
    stream.write_all(b"\n").expect("Failed to write request");
    stream.flush().ok();
    read_response(&mut stream)
}

fn read_response(stream: &mut UnixStream) -> Response {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];

    loop {
        let n = stream.read(&mut chunk).expect("Failed to read response");
        if n == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..n]);
        if chunk[..n].contains(&b'\n') {
            break;
        }
    }

    let newline_index = buffer.iter().position(|b| *b == b'\n');
    let response_bytes = match newline_index {
        Some(index) => &buffer[..index],
        None => buffer.as_slice(),
    };

    serde_json::from_slice(response_bytes).expect("Failed to parse response JSON")
}

#[test]
fn daemon_ipc_health_and_liveness_smoke() {
    let home = tempfile::Builder::new()
        .prefix("capacitor-daemon")
        .tempdir_in("/tmp")
        .expect("Failed to create temp HOME");
    let socket = socket_path(home.path());
    if !can_bind_socket(home.path()) {
        eprintln!(
            "Skipping ipc smoke test: unix socket binding not permitted in this environment."
        );
        return;
    }
    let child = spawn_daemon(home.path());
    let _guard = DaemonGuard { child };

    wait_for_socket(&socket, Duration::from_secs(5));

    let health = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetHealth,
            id: Some("health-check".to_string()),
            params: None,
        },
    );

    assert!(health.ok, "health response was not ok");
    let status = health
        .data
        .as_ref()
        .and_then(|data| data.get("status"))
        .and_then(|value| value.as_str())
        .unwrap_or("missing");
    assert_eq!(status, "ok");
    let reconcile = health
        .data
        .as_ref()
        .and_then(|data| data.get("dead_session_reconcile"))
        .and_then(|value| value.as_object())
        .expect("dead_session_reconcile object");
    let startup = reconcile
        .get("startup")
        .and_then(|value| value.as_object())
        .expect("startup metrics");
    let startup_runs = startup
        .get("runs")
        .and_then(|value| value.as_u64())
        .unwrap_or(0);
    assert!(
        startup_runs >= 1,
        "expected startup reconcile runs >= 1, got {}",
        startup_runs
    );
    let interval = health
        .data
        .as_ref()
        .and_then(|data| data.get("dead_session_reconcile_interval_secs"))
        .and_then(|value| value.as_u64())
        .unwrap_or(0);
    assert_eq!(interval, 15);
    let hem_shadow = health
        .data
        .as_ref()
        .and_then(|data| data.get("hem_shadow"))
        .and_then(|value| value.as_object())
        .expect("hem_shadow object");
    assert_eq!(
        hem_shadow.get("enabled").and_then(|value| value.as_bool()),
        Some(false)
    );
    assert_eq!(
        hem_shadow.get("mode").and_then(|value| value.as_str()),
        Some("primary")
    );
    assert_eq!(
        hem_shadow
            .get("gate_blocking_mismatches")
            .and_then(|value| value.as_u64()),
        Some(0)
    );
    assert_eq!(
        hem_shadow
            .get("gate_critical_mismatches")
            .and_then(|value| value.as_u64()),
        Some(0)
    );
    assert_eq!(
        hem_shadow
            .get("gate_important_mismatches")
            .and_then(|value| value.as_u64()),
        Some(0)
    );
    assert_eq!(
        hem_shadow
            .get("shadow_gate_ready")
            .and_then(|value| value.as_bool()),
        Some(false)
    );
    assert_eq!(
        hem_shadow
            .get("blocking_mismatch_rate")
            .and_then(|value| value.as_f64()),
        Some(0.0)
    );
    assert_eq!(
        hem_shadow
            .get("stable_state_samples")
            .and_then(|value| value.as_u64()),
        Some(0)
    );
    assert_eq!(
        hem_shadow
            .get("stable_state_matches")
            .and_then(|value| value.as_u64()),
        Some(0)
    );
    assert_eq!(
        hem_shadow
            .get("stable_state_agreement_rate")
            .and_then(|value| value.as_f64()),
        Some(0.0)
    );
    assert_eq!(
        hem_shadow
            .get("stable_state_agreement_gate_target")
            .and_then(|value| value.as_f64()),
        Some(0.995)
    );
    assert_eq!(
        hem_shadow
            .get("stable_state_agreement_gate_met")
            .and_then(|value| value.as_bool()),
        Some(false)
    );
    let capability_status = hem_shadow
        .get("capability_status")
        .and_then(|value| value.as_object())
        .expect("capability_status object");
    assert_eq!(
        capability_status
            .get("strategy")
            .and_then(|value| value.as_str()),
        Some("runtime_handshake")
    );
    assert_eq!(
        capability_status
            .get("handshake_seen")
            .and_then(|value| value.as_bool()),
        Some(false)
    );
    assert_eq!(
        capability_status
            .get("warning_count")
            .and_then(|value| value.as_u64()),
        Some(0)
    );
    assert_eq!(
        capability_status
            .get("confidence_penalty_factor")
            .and_then(|value| value.as_f64()),
        Some(1.0)
    );
    assert!(
        hem_shadow.get("last_blocking_mismatch_at").is_none()
            || hem_shadow
                .get("last_blocking_mismatch_at")
                .is_some_and(|value| value.is_null())
    );
    let routing = health
        .data
        .as_ref()
        .and_then(|data| data.get("routing"))
        .and_then(|value| value.as_object())
        .expect("routing metrics object");
    assert_eq!(
        routing.get("enabled").and_then(|value| value.as_bool()),
        Some(false)
    );
    assert_eq!(
        routing
            .get("dual_run_enabled")
            .and_then(|value| value.as_bool()),
        Some(true)
    );
    assert_eq!(
        routing
            .get("snapshots_emitted")
            .and_then(|value| value.as_u64()),
        Some(0)
    );

    let config = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetConfig,
            id: Some("routing-config-check".to_string()),
            params: None,
        },
    );
    assert!(config.ok, "get_config response was not ok");
    let config_data = config.data.expect("config payload");
    assert_eq!(
        config_data
            .get("tmux_signal_fresh_ms")
            .and_then(|value| value.as_u64()),
        Some(5_000)
    );
    assert_eq!(
        config_data
            .get("shell_signal_fresh_ms")
            .and_then(|value| value.as_u64()),
        Some(600_000)
    );
    assert_eq!(
        config_data
            .get("shell_retention_hours")
            .and_then(|value| value.as_u64()),
        Some(24)
    );
    assert_eq!(
        config_data
            .get("tmux_poll_interval_ms")
            .and_then(|value| value.as_u64()),
        Some(1_000)
    );

    let repo_root = home.path().join("repo");
    let src_dir = repo_root.join("src");
    std::fs::create_dir_all(&src_dir).expect("create repo dir");
    std::fs::write(repo_root.join("package.json"), "{}").expect("write boundary marker");
    std::fs::write(src_dir.join("main.rs"), "fn main() {}").expect("write source file");

    let pid = std::process::id();
    let session_id = "session-test-1".to_string();
    let now = Utc::now();
    let event = EventEnvelope {
        event_id: "evt-test-1".to_string(),
        recorded_at: now.to_rfc3339(),
        event_type: EventType::SessionStart,
        session_id: Some(session_id.clone()),
        pid: Some(pid),
        cwd: Some(repo_root.to_string_lossy().to_string()),
        tool: None,
        file_path: None,
        parent_app: None,
        tty: None,
        tmux_session: None,
        tmux_client_tty: None,
        notification_type: None,
        stop_hook_active: None,
        metadata: None,
    };

    let event_response = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::Event,
            id: Some(event.event_id.clone()),
            params: Some(serde_json::to_value(event).expect("Failed to serialize event")),
        },
    );
    assert!(event_response.ok, "event response was not ok");

    let post_event = EventEnvelope {
        event_id: "evt-test-2".to_string(),
        recorded_at: (now + ChronoDuration::seconds(10)).to_rfc3339(),
        event_type: EventType::PostToolUse,
        session_id: Some(session_id.clone()),
        pid: Some(pid),
        cwd: Some(repo_root.to_string_lossy().to_string()),
        tool: Some("Edit".to_string()),
        file_path: Some("src/main.rs".to_string()),
        parent_app: None,
        tty: None,
        tmux_session: None,
        tmux_client_tty: None,
        notification_type: None,
        stop_hook_active: None,
        metadata: None,
    };

    let post_response = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::Event,
            id: Some(post_event.event_id.clone()),
            params: Some(serde_json::to_value(post_event).expect("serialize post event")),
        },
    );
    assert!(post_response.ok, "post_tool_use response was not ok");

    let shell_event = EventEnvelope {
        event_id: "evt-shell-1".to_string(),
        recorded_at: (now + ChronoDuration::seconds(12)).to_rfc3339(),
        event_type: EventType::ShellCwd,
        session_id: None,
        pid: Some(pid),
        cwd: Some(repo_root.to_string_lossy().to_string()),
        tool: None,
        file_path: None,
        parent_app: Some("tmux".to_string()),
        tty: Some("/dev/ttys001".to_string()),
        tmux_session: Some("caps".to_string()),
        tmux_client_tty: Some("/dev/ttys001".to_string()),
        notification_type: None,
        stop_hook_active: None,
        metadata: Some(serde_json::json!({
            "proc_start": 123456789,
            "tmux_pane": "%1"
        })),
    };

    let shell_response = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::Event,
            id: Some(shell_event.event_id.clone()),
            params: Some(serde_json::to_value(shell_event).expect("serialize shell event")),
        },
    );
    assert!(shell_response.ok, "shell_cwd response was not ok");

    let routing_snapshot = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetRoutingSnapshot,
            id: Some("routing-snapshot-check".to_string()),
            params: Some(serde_json::json!({
                "project_path": repo_root.to_string_lossy().to_string()
            })),
        },
    );
    assert!(routing_snapshot.ok, "routing snapshot response was not ok");
    let routing_snapshot_data = routing_snapshot.data.expect("routing snapshot payload");
    assert_eq!(
        routing_snapshot_data
            .get("status")
            .and_then(|value| value.as_str()),
        Some("attached")
    );
    let routing_target = routing_snapshot_data
        .get("target")
        .and_then(|value| value.as_object())
        .expect("routing target object");
    assert_eq!(
        routing_target.get("kind").and_then(|value| value.as_str()),
        Some("tmux_session")
    );
    assert_eq!(
        routing_target.get("value").and_then(|value| value.as_str()),
        Some("caps")
    );

    let routing_diagnostics = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetRoutingDiagnostics,
            id: Some("routing-diagnostics-check".to_string()),
            params: Some(serde_json::json!({
                "project_path": repo_root.to_string_lossy().to_string()
            })),
        },
    );
    assert!(
        routing_diagnostics.ok,
        "routing diagnostics response was not ok"
    );
    let routing_diagnostics_data = routing_diagnostics
        .data
        .expect("routing diagnostics payload");
    let routing_diagnostics_snapshot = routing_diagnostics_data
        .get("snapshot")
        .and_then(|value| value.as_object())
        .expect("routing diagnostics snapshot");
    assert_eq!(
        routing_diagnostics_snapshot
            .get("reason_code")
            .and_then(|value| value.as_str()),
        Some("TMUX_CLIENT_ATTACHED")
    );

    let health_after_routing = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetHealth,
            id: Some("health-after-routing".to_string()),
            params: None,
        },
    );
    assert!(
        health_after_routing.ok,
        "health after routing response was not ok"
    );
    let routing_after = health_after_routing
        .data
        .as_ref()
        .and_then(|data| data.get("routing"))
        .and_then(|value| value.as_object())
        .expect("routing health after snapshot");
    assert_eq!(
        routing_after
            .get("snapshots_emitted")
            .and_then(|value| value.as_u64()),
        Some(1)
    );
    assert_eq!(
        routing_after
            .get("confidence_high")
            .and_then(|value| value.as_u64()),
        Some(1)
    );

    let sessions = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetSessions,
            id: Some("sessions-check".to_string()),
            params: None,
        },
    );
    assert!(sessions.ok, "sessions response was not ok");
    let sessions_value = sessions.data.expect("sessions payload");
    let sessions_array = sessions_value
        .as_array()
        .expect("sessions payload is array");
    assert_eq!(sessions_array.len(), 1);
    let session = &sessions_array[0];
    assert_eq!(
        session.get("session_id").and_then(|value| value.as_str()),
        Some(session_id.as_str())
    );
    assert_eq!(
        session.get("state").and_then(|value| value.as_str()),
        Some("working")
    );
    let expected_project_path = std::fs::canonicalize(&repo_root)
        .unwrap_or(repo_root.clone())
        .to_string_lossy()
        .to_string();
    let session_project_id = session
        .get("project_id")
        .and_then(|value| value.as_str())
        .map(|value| canonicalize_path(value));
    assert_eq!(
        session_project_id.as_deref(),
        Some(expected_project_path.as_str())
    );
    assert!(session
        .get("workspace_id")
        .and_then(|value| value.as_str())
        .map(|value| !value.is_empty())
        .unwrap_or(false));

    let project_states = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetProjectStates,
            id: Some("project-states-check".to_string()),
            params: None,
        },
    );
    assert!(project_states.ok, "project states response was not ok");
    let project_value = project_states.data.expect("project states payload");
    let project_array = project_value
        .as_array()
        .expect("project states payload is array");
    assert_eq!(project_array.len(), 1);
    let project = &project_array[0];
    let project_path_value = project
        .get("project_path")
        .and_then(|value| value.as_str())
        .map(|value| canonicalize_path(value));
    let project_id_value = project
        .get("project_id")
        .and_then(|value| value.as_str())
        .map(|value| canonicalize_path(value));
    assert_eq!(
        project_path_value.as_deref(),
        Some(expected_project_path.as_str())
    );
    assert_eq!(
        project_id_value.as_deref(),
        Some(expected_project_path.as_str())
    );
    assert!(project
        .get("workspace_id")
        .and_then(|value| value.as_str())
        .map(|value| !value.is_empty())
        .unwrap_or(false));
    assert_eq!(
        project.get("state").and_then(|value| value.as_str()),
        Some("working")
    );

    let activity = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetActivity,
            id: Some("activity-check".to_string()),
            params: Some(serde_json::json!({
                "session_id": session_id,
                "limit": 5
            })),
        },
    );
    assert!(activity.ok, "activity response was not ok");
    let activity_value = activity.data.expect("activity payload");
    let activity_array = activity_value
        .as_array()
        .expect("activity payload is array");
    assert_eq!(activity_array.len(), 1);
    let entry = &activity_array[0];
    assert_eq!(
        entry.get("file_path").and_then(|value| value.as_str()),
        Some(src_dir.join("main.rs").to_string_lossy().as_ref())
    );

    let liveness = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetProcessLiveness,
            id: Some("liveness-check".to_string()),
            params: Some(serde_json::json!({ "pid": pid })),
        },
    );
    assert!(liveness.ok, "liveness response was not ok");
    let pid_value = liveness
        .data
        .as_ref()
        .and_then(|data| data.get("pid"))
        .and_then(|value| value.as_u64())
        .unwrap_or_default();
    assert_eq!(pid_value, pid as u64);

    let end_event = EventEnvelope {
        event_id: "evt-test-3".to_string(),
        recorded_at: (now + ChronoDuration::seconds(20)).to_rfc3339(),
        event_type: EventType::SessionEnd,
        session_id: Some(session_id.clone()),
        pid: Some(pid),
        cwd: Some(repo_root.to_string_lossy().to_string()),
        tool: None,
        file_path: None,
        parent_app: None,
        tty: None,
        tmux_session: None,
        tmux_client_tty: None,
        notification_type: None,
        stop_hook_active: None,
        metadata: None,
    };

    let end_response = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::Event,
            id: Some(end_event.event_id.clone()),
            params: Some(serde_json::to_value(end_event).expect("serialize end event")),
        },
    );
    assert!(end_response.ok, "session_end response was not ok");

    let sessions_after = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetSessions,
            id: Some("sessions-after".to_string()),
            params: None,
        },
    );
    let sessions_after_value = sessions_after.data.expect("sessions payload");
    let sessions_after_array = sessions_after_value
        .as_array()
        .expect("sessions payload is array");
    assert!(sessions_after_array.is_empty());

    let projects_after = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetProjectStates,
            id: Some("project-states-after".to_string()),
            params: None,
        },
    );
    let projects_after_value = projects_after.data.expect("project states payload");
    let projects_after_array = projects_after_value
        .as_array()
        .expect("project states payload is array");
    assert!(projects_after_array.is_empty());

    let activity_after = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetActivity,
            id: Some("activity-after".to_string()),
            params: Some(serde_json::json!({
                "session_id": session_id,
                "limit": 5
            })),
        },
    );
    let activity_after_value = activity_after.data.expect("activity payload");
    let activity_after_array = activity_after_value
        .as_array()
        .expect("activity payload is array");
    assert!(activity_after_array.is_empty());

    let tombstones = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetTombstones,
            id: Some("tombstones-check".to_string()),
            params: None,
        },
    );
    assert!(tombstones.ok, "tombstones response was not ok");
    let tombstones_value = tombstones.data.expect("tombstones payload");
    let tombstones_array = tombstones_value
        .as_array()
        .expect("tombstones payload is array");
    assert_eq!(tombstones_array.len(), 1);
    let tombstone = &tombstones_array[0];
    assert_eq!(
        tombstone.get("session_id").and_then(|value| value.as_str()),
        Some("session-test-1")
    );
}
