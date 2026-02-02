use capacitor_daemon_protocol::{
    EventEnvelope, EventType, Method, Request, Response, PROTOCOL_VERSION,
};
use chrono::{Duration as ChronoDuration, Utc};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};
use tempfile::TempDir;

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
    let home = TempDir::new().expect("Failed to create temp HOME");
    let socket = socket_path(home.path());
    let child = spawn_daemon(home.path());
    let _guard = DaemonGuard { child };

    wait_for_socket(&socket, Duration::from_secs(2));

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
    assert_eq!(
        project.get("project_path").and_then(|value| value.as_str()),
        Some(repo_root.to_string_lossy().as_ref())
    );
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
