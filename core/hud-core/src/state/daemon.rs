//! Daemon client helpers for state liveness checks.
//!
//! These are best-effort: failures should never block or crash callers. When
//! the daemon is unavailable, callers should fall back to local checks.

use capacitor_daemon_protocol::{Method, Request, Response, MAX_REQUEST_BYTES, PROTOCOL_VERSION};
use serde::Deserialize;
use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

const ENABLE_ENV: &str = "CAPACITOR_DAEMON_ENABLED";
const SOCKET_ENV: &str = "CAPACITOR_DAEMON_SOCKET";
const SOCKET_NAME: &str = "daemon.sock";
const READ_TIMEOUT_MS: u64 = 150;
const WRITE_TIMEOUT_MS: u64 = 150;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProcessLivenessSnapshot {
    #[serde(default)]
    pub found: Option<bool>,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default)]
    pub proc_started: Option<u64>,
    #[serde(default)]
    pub current_start_time: Option<u64>,
    #[serde(default)]
    #[allow(dead_code)]
    pub last_seen_at: Option<String>,
    #[serde(default)]
    pub is_alive: Option<bool>,
    #[serde(default)]
    pub identity_matches: Option<bool>,
}

pub fn process_liveness(pid: u32) -> Option<ProcessLivenessSnapshot> {
    if !daemon_enabled() {
        return None;
    }

    let socket = socket_path().ok()?;
    let mut stream = UnixStream::connect(&socket).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(READ_TIMEOUT_MS)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(WRITE_TIMEOUT_MS)));

    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::GetProcessLiveness,
        id: Some(format!("pid-{}", pid)),
        params: Some(serde_json::json!({ "pid": pid })),
    };

    serde_json::to_writer(&mut stream, &request).ok()?;
    stream.write_all(b"\n").ok()?;
    stream.flush().ok()?;

    let response = read_response(&mut stream).ok()?;
    if !response.ok {
        return None;
    }

    let data = response.data?;
    let snapshot: ProcessLivenessSnapshot = serde_json::from_value(data).ok()?;
    if snapshot.found == Some(false) {
        return None;
    }
    if snapshot.pid.is_none() {
        return None;
    }

    Some(snapshot)
}

fn daemon_enabled() -> bool {
    match env::var(ENABLE_ENV) {
        Ok(value) => matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"),
        Err(_) => false,
    }
}

fn socket_path() -> Result<PathBuf, String> {
    if let Ok(path) = env::var(SOCKET_ENV) {
        return Ok(PathBuf::from(path));
    }
    let home = dirs::home_dir().ok_or_else(|| "Home directory not found".to_string())?;
    Ok(home.join(".capacitor").join(SOCKET_NAME))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_process_liveness_payload() {
        let value = serde_json::json!({
            "pid": 123,
            "proc_started": 10,
            "current_start_time": 10,
            "last_seen_at": "2026-01-30T00:03:00Z",
            "is_alive": true,
            "identity_matches": true
        });

        let snapshot: ProcessLivenessSnapshot =
            serde_json::from_value(value).expect("parse snapshot");
        assert_eq!(snapshot.pid, Some(123));
        assert_eq!(snapshot.proc_started, Some(10));
        assert_eq!(snapshot.identity_matches, Some(true));
    }
}
