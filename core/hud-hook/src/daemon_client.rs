//! Client helper for sending hook events to the capacitor daemon.
//!
//! The daemon is the only writer. Failures should be surfaced to the caller
//! (no legacy file-based fallback).

use capacitor_daemon_protocol::{
    EventEnvelope, EventType, Method, Request, Response, MAX_REQUEST_BYTES, PROTOCOL_VERSION,
};
use chrono::Utc;
use hud_core::state::HookEvent;
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

pub fn send_handle_event(
    event: &HookEvent,
    session_id: &str,
    pid: u32,
    cwd: &str,
    agent_id: Option<&str>,
) -> bool {
    if !daemon_enabled() {
        return false;
    }

    let event_type = match event_type_for_hook(event) {
        Some(event_type) => event_type,
        None => return false,
    };

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
        HookEvent::Notification { notification_type } => {
            (None, None, Some(notification_type.clone()), None)
        }
        HookEvent::Stop { stop_hook_active } => (None, None, None, Some(*stop_hook_active)),
        _ => (None, None, None, None),
    };

    let event_id = make_event_id(pid);
    let recorded_at = Utc::now().to_rfc3339();
    let metadata = agent_id.and_then(|id| {
        let trimmed = id.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(serde_json::json!({ "agent_id": trimmed }))
        }
    });
    let build_envelope = || EventEnvelope {
        event_id: event_id.clone(),
        recorded_at: recorded_at.clone(),
        event_type,
        session_id: Some(session_id.to_string()),
        pid: Some(pid),
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

pub fn send_shell_cwd_event(
    pid: u32,
    cwd: &str,
    tty: &str,
    parent_app: ParentApp,
    tmux_session: Option<String>,
    tmux_client_tty: Option<String>,
) -> Result<(), String> {
    if !daemon_enabled() {
        return Err("Daemon disabled".to_string());
    }

    let build_envelope = || EventEnvelope {
        event_id: make_event_id(pid),
        recorded_at: Utc::now().to_rfc3339(),
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
        metadata: None,
    };

    send_event_with_retry(build_envelope, "shell-cwd event")
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
    use capacitor_daemon_protocol::Response;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex, OnceLock,
    };
    use std::time::{Duration, Instant};

    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

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

    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        ENV_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
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
        listener.set_nonblocking(true).unwrap();

        let attempt_count = std::sync::Arc::new(AtomicUsize::new(0));
        let attempt_count_clone = attempt_count.clone();

        let server = std::thread::spawn(move || {
            let start = Instant::now();
            let mut handled = 0;
            while handled < 2 && start.elapsed() < Duration::from_secs(5) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        handled += 1;
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
                    Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => break,
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
        );

        assert!(result.is_ok());

        server.join().unwrap();

        assert_eq!(attempt_count.load(Ordering::SeqCst), 2);
    }
}
