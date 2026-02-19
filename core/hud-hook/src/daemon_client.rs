//! Client helper for sending hook events to the capacitor daemon.
//!
//! The daemon is the only writer. Failures should be surfaced to the caller
//! (no legacy file-based fallback).

use capacitor_daemon_protocol::{
    EventEnvelope, EventType, Method, Request, Response, MAX_REQUEST_BYTES, PROTOCOL_VERSION,
};
use chrono::Utc;
use hud_core::state::{HookEvent, HookInput};
use hud_core::ParentApp;
use rand::RngCore;
use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

const ENABLE_ENV: &str = "CAPACITOR_DAEMON_ENABLED";
const SOCKET_ENV: &str = "CAPACITOR_DAEMON_SOCKET";
const SOCKET_NAME: &str = "daemon.sock";
const READ_TIMEOUT_MS: u64 = 600;
const WRITE_TIMEOUT_MS: u64 = 600;
const RETRY_DELAY_MS: u64 = 50;
const CAPABILITY_TOOL_USE_ID_CONSISTENCY: &str = "partial";

pub fn send_handle_event(
    event: &HookEvent,
    hook_input: &HookInput,
    session_id: &str,
    pid: Option<u32>,
    cwd: &str,
) -> bool {
    if !daemon_enabled() {
        return false;
    }

    let event_type = match event_type_for_hook(event) {
        Some(event_type) => event_type,
        None => return false,
    };

    let hook_input_file_path = hook_input
        .tool_input
        .as_ref()
        .and_then(|input| input.file_path.clone().or_else(|| input.path.clone()));

    let (tool, file_path, notification_type, stop_hook_active) = match event {
        HookEvent::PreToolUse {
            tool_name,
            file_path,
        } => (tool_name.clone(), file_path.clone(), None, None),
        HookEvent::PostToolUse {
            tool_name,
            file_path,
        } => (tool_name.clone(), file_path.clone(), None, None),
        HookEvent::PostToolUseFailure {
            tool_name,
            file_path,
        } => (tool_name.clone(), file_path.clone(), None, None),
        HookEvent::PermissionRequest => (
            hook_input.tool_name.clone(),
            hook_input_file_path,
            None,
            None,
        ),
        HookEvent::Notification { notification_type } => {
            (None, None, Some(notification_type.clone()), None)
        }
        HookEvent::Stop { stop_hook_active } => (None, None, None, Some(*stop_hook_active)),
        _ => (None, None, None, None),
    };

    let event_id = make_event_id(pid.unwrap_or(0));
    let recorded_at = Utc::now().to_rfc3339();
    let metadata = build_runtime_capability_metadata(Some(hook_input));
    let build_envelope = || EventEnvelope {
        event_id: event_id.clone(),
        recorded_at: recorded_at.clone(),
        event_type,
        session_id: Some(session_id.to_string()),
        pid,
        cwd: Some(cwd.to_string()),
        tool: tool.clone(),
        file_path: file_path.clone(),
        parent_app: None,
        tty: None,
        tmux_session: None,
        tmux_client_tty: None,
        notification_type: notification_type.clone(),
        stop_hook_active,
        metadata: metadata.clone(),
    };

    send_event_with_retry(build_envelope, "session event").is_ok()
}

#[allow(clippy::too_many_arguments)]
pub fn send_shell_cwd_event(
    pid: u32,
    cwd: &str,
    tty: &str,
    parent_app: ParentApp,
    tmux_session: Option<String>,
    tmux_client_tty: Option<String>,
    proc_start: Option<u64>,
    tmux_pane: Option<String>,
) -> Result<(), String> {
    if !daemon_enabled() {
        return Err("Daemon disabled".to_string());
    }

    let event_id = make_event_id(pid);
    let recorded_at = Utc::now().to_rfc3339();
    let build_envelope = || EventEnvelope {
        event_id: event_id.clone(),
        recorded_at: recorded_at.clone(),
        event_type: EventType::ShellCwd,
        session_id: None,
        pid: Some(pid),
        cwd: Some(cwd.to_string()),
        tool: None,
        file_path: None,
        parent_app: Some(parent_app_string(parent_app)),
        tty: Some(tty.to_string()),
        tmux_session: tmux_session.clone(),
        tmux_client_tty: tmux_client_tty.clone(),
        notification_type: None,
        stop_hook_active: None,
        metadata: build_shell_cwd_metadata(proc_start, tmux_pane.clone()),
    };

    send_event_with_retry(build_envelope, "shell-cwd event")
}

fn build_shell_cwd_metadata(
    proc_start: Option<u64>,
    tmux_pane: Option<String>,
) -> Option<serde_json::Value> {
    let mut metadata =
        build_runtime_capability_metadata(None).unwrap_or_else(|| serde_json::json!({}));
    if let Some(object) = metadata.as_object_mut() {
        if let Some(proc_start) = proc_start {
            object.insert("proc_start".to_string(), serde_json::json!(proc_start));
        }
        if let Some(tmux_pane) = tmux_pane
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
        {
            object.insert("tmux_pane".to_string(), serde_json::json!(tmux_pane));
        }
    }
    Some(metadata)
}

fn build_runtime_capability_metadata(hook_input: Option<&HookInput>) -> Option<serde_json::Value> {
    let mut metadata = serde_json::json!({
        "capabilities": {
            "hook_snapshot_introspection": false,
            "event_delivery_ack": false,
            "global_ordering_guarantee": false,
            "per_event_correlation_id": true,
            "notification_matcher_support": true,
            "tool_use_id_consistency": CAPABILITY_TOOL_USE_ID_CONSISTENCY
        }
    });

    if let Some(object) = metadata.as_object_mut() {
        if let Some(hook_input) = hook_input {
            for (key, value) in hook_input.to_metadata_map() {
                object.insert(key, value);
            }
        }
    }

    Some(metadata)
}

#[allow(dead_code)]
pub fn daemon_health() -> Option<bool> {
    if !daemon_enabled() {
        return None;
    }

    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::GetHealth,
        id: Some("health-check".to_string()),
        params: None,
    };

    let response = send_request(request).ok()?;
    if !response.ok {
        return Some(false);
    }

    let status = response
        .data
        .as_ref()
        .and_then(|data| data.get("status"))
        .and_then(|value| value.as_str());

    Some(matches!(status, Some("ok")))
}

pub fn daemon_enabled() -> bool {
    match env::var(ENABLE_ENV) {
        Ok(value) => matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"),
        Err(_) => true,
    }
}

fn socket_path() -> Result<PathBuf, String> {
    if let Ok(path) = env::var(SOCKET_ENV) {
        return Ok(PathBuf::from(path));
    }
    let home = dirs::home_dir().ok_or_else(|| "Home directory not found".to_string())?;
    Ok(home.join(".capacitor").join(SOCKET_NAME))
}

fn send_event(event: EventEnvelope) -> Result<(), String> {
    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::Event,
        id: Some(event.event_id.clone()),
        params: Some(
            serde_json::to_value(event)
                .map_err(|err| format!("Failed to serialize event: {}", err))?,
        ),
    };

    let response = send_request(request)?;
    if response.ok {
        Ok(())
    } else {
        let message = response
            .error
            .map(|err| format!("{}: {}", err.code, err.message))
            .unwrap_or_else(|| "Unknown daemon error".to_string());
        Err(message)
    }
}

fn send_event_with_retry<F>(mut build: F, label: &str) -> Result<(), String>
where
    F: FnMut() -> EventEnvelope,
{
    match send_event(build()) {
        Ok(_) => Ok(()),
        Err(err) => {
            tracing::warn!(error = %err, "Failed to send {} to daemon", label);
            std::thread::sleep(Duration::from_millis(RETRY_DELAY_MS));
            send_event(build()).map_err(|retry_err| {
                tracing::warn!(
                    error = %retry_err,
                    "Retry failed sending {} to daemon",
                    label
                );
                retry_err
            })
        }
    }
}

fn send_request(request: Request) -> Result<Response, String> {
    let socket = socket_path()?;
    let mut stream = UnixStream::connect(&socket)
        .map_err(|err| format!("Failed to connect to daemon socket: {}", err))?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(READ_TIMEOUT_MS)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(WRITE_TIMEOUT_MS)));

    serde_json::to_writer(&mut stream, &request)
        .map_err(|err| format!("Failed to write request: {}", err))?;
    stream
        .write_all(b"\n")
        .map_err(|err| format!("Failed to flush request: {}", err))?;
    stream.flush().ok();

    read_response(&mut stream)
}

fn read_response(stream: &mut UnixStream) -> Result<Response, String> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];

    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buffer.extend_from_slice(&chunk[..n]);
                if buffer.len() > MAX_REQUEST_BYTES {
                    return Err("Response exceeded maximum size".to_string());
                }
                if chunk[..n].contains(&b'\n') {
                    break;
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                return Err("Timed out waiting for daemon response".to_string());
            }
            Err(err) => return Err(format!("Failed to read response: {}", err)),
        }
    }

    let newline_index = buffer.iter().position(|b| *b == b'\n');
    let response_bytes = match newline_index {
        Some(index) => &buffer[..index],
        None => buffer.as_slice(),
    };

    if response_bytes.is_empty() {
        return Err("Daemon response was empty".to_string());
    }

    serde_json::from_slice(response_bytes)
        .map_err(|err| format!("Failed to parse response JSON: {}", err))
}

fn event_type_for_hook(event: &HookEvent) -> Option<EventType> {
    match event {
        HookEvent::SessionStart => Some(EventType::SessionStart),
        HookEvent::UserPromptSubmit => Some(EventType::UserPromptSubmit),
        HookEvent::PreToolUse { .. } => Some(EventType::PreToolUse),
        HookEvent::PostToolUse { .. } => Some(EventType::PostToolUse),
        HookEvent::PostToolUseFailure { .. } => Some(EventType::PostToolUseFailure),
        HookEvent::PermissionRequest => Some(EventType::PermissionRequest),
        HookEvent::PreCompact => Some(EventType::PreCompact),
        HookEvent::Notification { .. } => Some(EventType::Notification),
        HookEvent::SubagentStart => Some(EventType::SubagentStart),
        HookEvent::SubagentStop => Some(EventType::SubagentStop),
        HookEvent::Stop { .. } => Some(EventType::Stop),
        HookEvent::TeammateIdle => Some(EventType::TeammateIdle),
        HookEvent::TaskCompleted => Some(EventType::TaskCompleted),
        HookEvent::SessionEnd => Some(EventType::SessionEnd),
        HookEvent::Unknown { .. } => None,
    }
}

fn make_event_id(pid: u32) -> String {
    let mut random = rand::thread_rng();
    let rand = random.next_u64();
    format!("evt-{}-{}-{:x}", Utc::now().timestamp_millis(), pid, rand)
}

fn parent_app_string(app: ParentApp) -> String {
    serde_json::to_string(&app)
        .unwrap_or_else(|_| "unknown".to_string())
        .trim_matches('"')
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::env_lock;
    use capacitor_daemon_protocol::{Request, Response};
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    };
    use std::time::Duration;

    struct EnvGuard {
        key: &'static str,
        prior: Option<String>,
    }

    impl EnvGuard {
        fn set(key: &'static str, value: &str) -> Self {
            let prior = std::env::var(key).ok();
            std::env::set_var(key, value);
            Self { key, prior }
        }

        fn unset(key: &'static str) -> Self {
            let prior = std::env::var(key).ok();
            std::env::remove_var(key);
            Self { key, prior }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.prior {
                std::env::set_var(self.key, value);
            } else {
                std::env::remove_var(self.key);
            }
        }
    }

    fn read_request(stream: &mut UnixStream) {
        let mut buffer = Vec::new();
        let mut chunk = [0u8; 1024];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    buffer.extend_from_slice(&chunk[..n]);
                    if buffer.contains(&b'\n') {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    }

    fn read_request_id(stream: &mut UnixStream) -> Option<String> {
        let mut buffer = Vec::new();
        let mut chunk = [0u8; 1024];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    buffer.extend_from_slice(&chunk[..n]);
                    if buffer.contains(&b'\n') {
                        break;
                    }
                }
                Err(_) => return None,
            }
        }

        let newline_index = buffer.iter().position(|b| *b == b'\n');
        let request_bytes = match newline_index {
            Some(index) => &buffer[..index],
            None => buffer.as_slice(),
        };
        let request: Request = serde_json::from_slice(request_bytes).ok()?;
        request.id
    }

    fn read_request_event(stream: &mut UnixStream) -> Option<EventEnvelope> {
        let mut buffer = Vec::new();
        let mut chunk = [0u8; 1024];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    buffer.extend_from_slice(&chunk[..n]);
                    if buffer.contains(&b'\n') {
                        break;
                    }
                }
                Err(_) => return None,
            }
        }

        let newline_index = buffer.iter().position(|b| *b == b'\n');
        let request_bytes = match newline_index {
            Some(index) => &buffer[..index],
            None => buffer.as_slice(),
        };
        let request: Request = serde_json::from_slice(request_bytes).ok()?;
        let params = request.params?;
        serde_json::from_value(params).ok()
    }

    #[test]
    fn send_event_retries_after_daemon_error() {
        let _guard = env_lock();

        let socket_dir = std::env::temp_dir().join(format!(
            "hud-hook-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or(Duration::from_millis(0))
                .as_nanos()
        ));
        std::fs::create_dir_all(&socket_dir).unwrap();
        let socket_path = socket_dir.join("daemon.sock");
        let _ = std::fs::remove_file(&socket_path);

        let listener = std::os::unix::net::UnixListener::bind(&socket_path).unwrap();

        let attempt_count = std::sync::Arc::new(AtomicUsize::new(0));
        let attempt_count_clone = attempt_count.clone();

        let server = std::thread::spawn(move || {
            for handled in 1..=2 {
                let (mut stream, _) = listener.accept().expect("accept daemon request");
                attempt_count_clone.fetch_add(1, Ordering::SeqCst);
                read_request(&mut stream);
                let response = if handled == 1 {
                    Response::error(None, "test_error", "simulated")
                } else {
                    Response::ok(None, serde_json::json!({"status": "ok"}))
                };
                let mut payload = serde_json::to_vec(&response).unwrap();
                payload.push(b'\n');
                let _ = stream.write_all(&payload);
            }
        });

        let _socket_guard = EnvGuard::set(SOCKET_ENV, socket_path.to_str().unwrap());
        let _enabled_guard = EnvGuard::set(ENABLE_ENV, "1");

        let result = send_shell_cwd_event(
            4242,
            "/repo",
            "/dev/ttys001",
            ParentApp::Terminal,
            None,
            None,
            None,
            None,
        );

        assert!(result.is_ok(), "expected retry to succeed, got {result:?}");

        server.join().unwrap();

        assert_eq!(attempt_count.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn send_shell_cwd_retry_reuses_same_request_id_after_lost_response() {
        let _guard = env_lock();

        let socket_dir = std::path::Path::new("/tmp").join(format!(
            "hh-lost-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or(Duration::from_millis(0))
                .as_nanos()
        ));
        std::fs::create_dir_all(&socket_dir).unwrap();
        let socket_path = socket_dir.join("daemon.sock");
        let _ = std::fs::remove_file(&socket_path);

        let listener = std::os::unix::net::UnixListener::bind(&socket_path).unwrap();

        let attempt_ids: Arc<Mutex<Vec<Option<String>>>> = Arc::new(Mutex::new(Vec::new()));
        let attempt_ids_clone = Arc::clone(&attempt_ids);

        let server = std::thread::spawn(move || {
            for handled in 1..=2 {
                let (mut stream, _) = listener.accept().expect("accept daemon request");
                let request_id = read_request_id(&mut stream);
                attempt_ids_clone.lock().unwrap().push(request_id);

                if handled == 2 {
                    let response = Response::ok(None, serde_json::json!({"status": "ok"}));
                    let mut payload = serde_json::to_vec(&response).unwrap();
                    payload.push(b'\n');
                    let _ = stream.write_all(&payload);
                }
            }
        });

        let _socket_guard = EnvGuard::set(SOCKET_ENV, socket_path.to_str().unwrap());
        let _enabled_guard = EnvGuard::set(ENABLE_ENV, "1");

        let result = send_shell_cwd_event(
            4242,
            "/repo",
            "/dev/ttys001",
            ParentApp::Terminal,
            None,
            None,
            None,
            None,
        );

        assert!(result.is_ok());
        server.join().unwrap();

        let ids = attempt_ids.lock().unwrap();
        assert_eq!(ids.len(), 2);
        assert_eq!(ids[0], ids[1], "retry must reuse the same request/event id");
    }

    #[test]
    fn daemon_enabled_defaults_to_true_when_env_missing() {
        let _guard = env_lock();
        let _unset = EnvGuard::unset(ENABLE_ENV);
        assert!(daemon_enabled());
    }

    #[test]
    fn daemon_enabled_is_false_when_env_zero() {
        let _guard = env_lock();
        let _set = EnvGuard::set(ENABLE_ENV, "0");
        assert!(!daemon_enabled());
    }

    #[test]
    fn daemon_enabled_is_true_when_env_one() {
        let _guard = env_lock();
        let _set = EnvGuard::set(ENABLE_ENV, "1");
        assert!(daemon_enabled());
    }

    #[test]
    fn send_handle_event_includes_runtime_capability_handshake_and_hook_metadata() {
        let _guard = env_lock();

        let socket_dir = std::path::Path::new("/tmp").join(format!(
            "hh-capability-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or(Duration::from_millis(0))
                .as_nanos()
        ));
        std::fs::create_dir_all(&socket_dir).unwrap();
        let socket_path = socket_dir.join("daemon.sock");
        let _ = std::fs::remove_file(&socket_path);
        let listener = std::os::unix::net::UnixListener::bind(&socket_path).unwrap();

        let captured = Arc::new(Mutex::new(None::<EventEnvelope>));
        let captured_clone = Arc::clone(&captured);
        let server = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let event = read_request_event(&mut stream);
                *captured_clone.lock().unwrap() = event;
                let response = Response::ok(None, serde_json::json!({"status": "ok"}));
                let mut payload = serde_json::to_vec(&response).unwrap();
                payload.push(b'\n');
                let _ = stream.write_all(&payload);
            }
        });

        let _socket_guard = EnvGuard::set(SOCKET_ENV, socket_path.to_str().unwrap());
        let _enabled_guard = EnvGuard::set(ENABLE_ENV, "1");
        let event = HookEvent::PostToolUse {
            tool_name: Some("Read".to_string()),
            file_path: Some("src/main.rs".to_string()),
        };
        let hook_input: HookInput = serde_json::from_value(serde_json::json!({
            "hook_event_name": "PostToolUse",
            "session_id": "session-1",
            "transcript_path": "/tmp/transcript.jsonl",
            "cwd": "/repo",
            "permission_mode": "acceptEdits",
            "tool_name": "Read",
            "tool_use_id": "toolu_01ABC",
            "tool_input": {
                "path": "src/main.rs",
                "command": "cat src/main.rs"
            },
            "tool_response": {
                "filePath": "src/main.rs"
            },
            "agent_id": "agent-123",
            "agent_type": "Explore",
            "task_id": "task-001",
            "future_field": "future-value"
        }))
        .expect("hook input");
        assert!(send_handle_event(
            &event,
            &hook_input,
            "session-1",
            Some(4242),
            "/repo",
        ));
        server.join().unwrap();

        let event = captured.lock().unwrap().take().expect("captured event");
        let metadata = event.metadata.expect("metadata");
        let caps = metadata
            .get("capabilities")
            .and_then(|value| value.as_object())
            .expect("capabilities object");
        assert_eq!(
            caps.get("notification_matcher_support")
                .and_then(|value| value.as_bool()),
            Some(true)
        );
        assert_eq!(
            caps.get("per_event_correlation_id")
                .and_then(|value| value.as_bool()),
            Some(true)
        );
        assert_eq!(
            caps.get("tool_use_id_consistency")
                .and_then(|value| value.as_str()),
            Some("partial")
        );
        assert_eq!(
            metadata.get("agent_id").and_then(|value| value.as_str()),
            Some("agent-123")
        );
        assert_eq!(
            metadata
                .get("transcript_path")
                .and_then(|value| value.as_str()),
            Some("/tmp/transcript.jsonl")
        );
        assert_eq!(
            metadata
                .get("permission_mode")
                .and_then(|value| value.as_str()),
            Some("acceptEdits")
        );
        assert_eq!(
            metadata.get("agent_type").and_then(|value| value.as_str()),
            Some("Explore")
        );
        assert_eq!(
            metadata.get("task_id").and_then(|value| value.as_str()),
            Some("task-001")
        );
        assert_eq!(
            metadata
                .get("future_field")
                .and_then(|value| value.as_str()),
            Some("future-value")
        );
        assert_eq!(
            metadata
                .get("tool_input")
                .and_then(|value| value.get("command"))
                .and_then(|value| value.as_str()),
            Some("cat src/main.rs")
        );
    }

    #[test]
    fn send_permission_request_event_includes_tool_and_file_path() {
        let _guard = env_lock();

        let socket_dir = std::path::Path::new("/tmp").join(format!(
            "hh-permission-request-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or(Duration::from_millis(0))
                .as_nanos()
        ));
        std::fs::create_dir_all(&socket_dir).unwrap();
        let socket_path = socket_dir.join("daemon.sock");
        let _ = std::fs::remove_file(&socket_path);
        let listener = std::os::unix::net::UnixListener::bind(&socket_path).unwrap();

        let captured = Arc::new(Mutex::new(None::<EventEnvelope>));
        let captured_clone = Arc::clone(&captured);
        let server = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let event = read_request_event(&mut stream);
                *captured_clone.lock().unwrap() = event;
                let response = Response::ok(None, serde_json::json!({"status": "ok"}));
                let mut payload = serde_json::to_vec(&response).unwrap();
                payload.push(b'\n');
                let _ = stream.write_all(&payload);
            }
        });

        let _socket_guard = EnvGuard::set(SOCKET_ENV, socket_path.to_str().unwrap());
        let _enabled_guard = EnvGuard::set(ENABLE_ENV, "1");

        let event = HookEvent::PermissionRequest;
        let hook_input: HookInput = serde_json::from_value(serde_json::json!({
            "hook_event_name": "PermissionRequest",
            "session_id": "session-1",
            "cwd": "/repo",
            "tool_name": "Edit",
            "tool_input": {
                "file_path": "src/main.rs"
            }
        }))
        .expect("hook input");

        assert!(send_handle_event(
            &event,
            &hook_input,
            "session-1",
            Some(4242),
            "/repo",
        ));
        server.join().unwrap();

        let event = captured.lock().unwrap().take().expect("captured event");
        assert_eq!(event.event_type, EventType::PermissionRequest);
        assert_eq!(event.tool.as_deref(), Some("Edit"));
        assert_eq!(event.file_path.as_deref(), Some("src/main.rs"));
    }

    #[test]
    fn send_shell_cwd_event_includes_runtime_capability_handshake() {
        let _guard = env_lock();

        let socket_dir = std::path::Path::new("/tmp").join(format!(
            "hh-capability-shell-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or(Duration::from_millis(0))
                .as_nanos()
        ));
        std::fs::create_dir_all(&socket_dir).unwrap();
        let socket_path = socket_dir.join("daemon.sock");
        let _ = std::fs::remove_file(&socket_path);
        let listener = std::os::unix::net::UnixListener::bind(&socket_path).unwrap();

        let captured = Arc::new(Mutex::new(None::<EventEnvelope>));
        let captured_clone = Arc::clone(&captured);
        let server = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let event = read_request_event(&mut stream);
                *captured_clone.lock().unwrap() = event;
                let response = Response::ok(None, serde_json::json!({"status": "ok"}));
                let mut payload = serde_json::to_vec(&response).unwrap();
                payload.push(b'\n');
                let _ = stream.write_all(&payload);
            }
        });

        let _socket_guard = EnvGuard::set(SOCKET_ENV, socket_path.to_str().unwrap());
        let _enabled_guard = EnvGuard::set(ENABLE_ENV, "1");
        assert!(send_shell_cwd_event(
            4242,
            "/repo",
            "/dev/ttys001",
            ParentApp::Terminal,
            None,
            None,
            None,
            None
        )
        .is_ok());
        server.join().unwrap();

        let event = captured.lock().unwrap().take().expect("captured event");
        let metadata = event.metadata.expect("metadata");
        let caps = metadata
            .get("capabilities")
            .and_then(|value| value.as_object())
            .expect("capabilities object");
        assert_eq!(
            caps.get("notification_matcher_support")
                .and_then(|value| value.as_bool()),
            Some(true)
        );
        assert_eq!(
            caps.get("tool_use_id_consistency")
                .and_then(|value| value.as_str()),
            Some("partial")
        );
        assert!(
            metadata.get("agent_id").is_none(),
            "shell cwd metadata should not inject agent_id"
        );
    }

    #[test]
    fn send_shell_cwd_event_includes_proc_start_and_tmux_pane_metadata() {
        let _guard = env_lock();

        let socket_dir = std::path::Path::new("/tmp").join(format!(
            "hh-shell-metadata-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or(Duration::from_millis(0))
                .as_nanos()
        ));
        std::fs::create_dir_all(&socket_dir).unwrap();
        let socket_path = socket_dir.join("daemon.sock");
        let _ = std::fs::remove_file(&socket_path);
        let listener = std::os::unix::net::UnixListener::bind(&socket_path).unwrap();

        let captured = Arc::new(Mutex::new(None::<EventEnvelope>));
        let captured_clone = Arc::clone(&captured);
        let server = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let event = read_request_event(&mut stream);
                *captured_clone.lock().unwrap() = event;
                let response = Response::ok(None, serde_json::json!({"status": "ok"}));
                let mut payload = serde_json::to_vec(&response).unwrap();
                payload.push(b'\n');
                let _ = stream.write_all(&payload);
            }
        });

        let _socket_guard = EnvGuard::set(SOCKET_ENV, socket_path.to_str().unwrap());
        let _enabled_guard = EnvGuard::set(ENABLE_ENV, "1");
        assert!(send_shell_cwd_event(
            4242,
            "/repo",
            "/dev/ttys001",
            ParentApp::Terminal,
            Some("caps".to_string()),
            Some("/dev/ttys001".to_string()),
            Some(1234567),
            Some("%1".to_string()),
        )
        .is_ok());
        server.join().unwrap();

        let event = captured.lock().unwrap().take().expect("captured event");
        let metadata = event.metadata.expect("metadata");
        assert_eq!(
            metadata.get("proc_start").and_then(|value| value.as_u64()),
            Some(1234567)
        );
        assert_eq!(
            metadata.get("tmux_pane").and_then(|value| value.as_str()),
            Some("%1")
        );
    }
}
