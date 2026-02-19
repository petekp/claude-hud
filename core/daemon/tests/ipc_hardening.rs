use capacitor_daemon_protocol::{
    Method, Request, Response, ERROR_TOO_MANY_CONNECTIONS, PROTOCOL_VERSION,
};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

const MAX_ACTIVE_CONNECTIONS: usize = 64;

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
        .expect("failed to spawn capacitor-daemon")
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
        if path.exists() && UnixStream::connect(path).is_ok() {
            return;
        }
        sleep(Duration::from_millis(25));
    }
    panic!("timed out waiting for daemon socket at {}", path.display());
}

fn send_request(socket: &Path, request: Request) -> Response {
    let mut stream = UnixStream::connect(socket).expect("failed to connect to daemon socket");
    serde_json::to_writer(&mut stream, &request).expect("failed to serialize request");
    stream.write_all(b"\n").expect("failed to write request");
    stream.flush().expect("failed to flush request");
    read_response(&mut stream)
}

fn send_raw_request(socket: &Path, payload: &[u8]) -> Response {
    let mut stream = UnixStream::connect(socket).expect("failed to connect to daemon socket");
    stream
        .write_all(payload)
        .expect("failed to write raw payload");
    stream.flush().expect("failed to flush raw payload");
    read_response(&mut stream)
}

fn read_response(stream: &mut UnixStream) -> Response {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];

    loop {
        let n = stream.read(&mut chunk).expect("failed to read response");
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

    serde_json::from_slice(response_bytes).expect("failed to parse response JSON")
}

fn try_send_request(socket: &Path, request: &Request) -> Option<Response> {
    let mut stream = UnixStream::connect(socket).ok()?;
    serde_json::to_writer(&mut stream, request).ok()?;
    stream.write_all(b"\n").ok()?;
    stream.flush().ok()?;
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..n]);
        if chunk[..n].contains(&b'\n') {
            break;
        }
    }
    if buffer.is_empty() {
        return None;
    }
    let newline_index = buffer.iter().position(|b| *b == b'\n');
    let response_bytes = match newline_index {
        Some(index) => &buffer[..index],
        None => buffer.as_slice(),
    };
    serde_json::from_slice(response_bytes).ok()
}

fn wait_for_health_ok(socket: &Path, timeout: Duration) -> Option<Response> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let request = Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetHealth,
            id: Some("health-retry".to_string()),
            params: None,
        };
        if let Some(response) = try_send_request(socket, &request) {
            if response.ok {
                return Some(response);
            }
        }
        sleep(Duration::from_millis(25));
    }
    None
}

#[test]
fn daemon_connection_limit_rejects_overflow_and_stays_healthy() {
    let home = tempfile::Builder::new()
        .prefix("capacitor-daemon-hardening-limit")
        .tempdir_in("/tmp")
        .expect("failed to create temp HOME");
    if !can_bind_socket(home.path()) {
        eprintln!(
            "Skipping daemon connection cap hardening test: unix socket binding not permitted in this environment."
        );
        return;
    }

    let socket = socket_path(home.path());
    let child = spawn_daemon(home.path());
    let mut guard = Some(DaemonGuard { child });
    wait_for_socket(&socket, Duration::from_secs(5));

    let mut saturated_streams = Vec::with_capacity(MAX_ACTIVE_CONNECTIONS);
    for _ in 0..MAX_ACTIVE_CONNECTIONS {
        saturated_streams
            .push(UnixStream::connect(&socket).expect("failed to saturate connection"));
    }

    let mut overflow = UnixStream::connect(&socket).expect("failed to connect overflow stream");
    let overflow_response = read_response(&mut overflow);
    assert!(
        !overflow_response.ok,
        "overflow response should be an error"
    );
    assert_eq!(
        overflow_response
            .error
            .as_ref()
            .map(|err| err.code.as_str()),
        Some(ERROR_TOO_MANY_CONNECTIONS)
    );

    saturated_streams.pop();

    let health = wait_for_health_ok(&socket, Duration::from_secs(1))
        .expect("daemon should become healthy shortly after releasing one connection");
    let rejected = health
        .data
        .as_ref()
        .and_then(|data| data.get("security"))
        .and_then(|security| security.get("rejected_connections"))
        .and_then(|value| value.as_u64())
        .unwrap_or(0);
    assert!(
        rejected >= 1,
        "expected rejected_connections >= 1, got {rejected}"
    );

    saturated_streams.clear();
    drop(overflow);
    drop(guard.take());
}

#[test]
fn daemon_handles_malformed_payload_flood_without_losing_health() {
    let home = tempfile::Builder::new()
        .prefix("capacitor-daemon-hardening-malformed")
        .tempdir_in("/tmp")
        .expect("failed to create temp HOME");
    if !can_bind_socket(home.path()) {
        eprintln!(
            "Skipping malformed flood hardening test: unix socket binding not permitted in this environment."
        );
        return;
    }

    let socket = socket_path(home.path());
    let child = spawn_daemon(home.path());
    let mut guard = Some(DaemonGuard { child });
    wait_for_socket(&socket, Duration::from_secs(5));

    for _ in 0..128 {
        let response = send_raw_request(&socket, b"{\"bad_json\": true\n");
        assert!(!response.ok, "malformed payload must be rejected");
        assert_eq!(
            response.error.as_ref().map(|err| err.code.as_str()),
            Some("invalid_json")
        );
    }

    let health = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetHealth,
            id: Some("health-after-malformed-flood".to_string()),
            params: None,
        },
    );
    assert!(
        health.ok,
        "daemon should remain healthy after malformed flood"
    );

    drop(guard.take());
}

#[test]
fn daemon_idle_connection_returns_read_timeout_error() {
    let home = tempfile::Builder::new()
        .prefix("capacitor-daemon-hardening-timeout")
        .tempdir_in("/tmp")
        .expect("failed to create temp HOME");
    if !can_bind_socket(home.path()) {
        eprintln!(
            "Skipping timeout hardening test: unix socket binding not permitted in this environment."
        );
        return;
    }

    let socket = socket_path(home.path());
    let child = spawn_daemon(home.path());
    let mut guard = Some(DaemonGuard { child });
    wait_for_socket(&socket, Duration::from_secs(5));

    let mut idle = UnixStream::connect(&socket).expect("failed to connect idle stream");
    let response = read_response(&mut idle);
    assert!(!response.ok, "idle request should return an error");
    assert_eq!(
        response.error.as_ref().map(|err| err.code.as_str()),
        Some("read_timeout")
    );

    drop(guard.take());
}
