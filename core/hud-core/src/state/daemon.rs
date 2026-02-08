//! Daemon client helpers for state liveness checks.
//!
//! The daemon is authoritative; callers should not fall back to local checks.

use capacitor_daemon_protocol::{Method, Request, Response, MAX_REQUEST_BYTES, PROTOCOL_VERSION};
use chrono::{DateTime, Utc};
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
#[allow(dead_code)]
pub struct DaemonSessionRecord {
    pub session_id: String,
    pub pid: u32,
    pub state: String,
    pub cwd: String,
    pub project_path: String,
    pub updated_at: String,
    pub state_changed_at: String,
    #[serde(default)]
    pub last_event: Option<String>,
    #[serde(default)]
    pub last_activity_at: Option<String>,
    #[serde(default)]
    pub tools_in_flight: u32,
    #[serde(default)]
    pub ready_reason: Option<String>,
    #[serde(default)]
    pub is_alive: Option<bool>,
}

pub struct DaemonSessionsSnapshot {
    sessions: Vec<DaemonSessionRecord>,
}

impl DaemonSessionsSnapshot {
    pub fn sessions(&self) -> &[DaemonSessionRecord] {
        &self.sessions
    }

    pub fn latest_for_project(&self, project_path: &str) -> Option<&DaemonSessionRecord> {
        let home_dir = dirs::home_dir().map(|path| path.to_string_lossy().to_string());
        let mut best: Option<&DaemonSessionRecord> = None;

        for session in &self.sessions {
            let matches = super::path_utils::path_is_parent_or_self_excluding_home(
                project_path,
                &session.project_path,
                home_dir.as_deref(),
            );

            if !matches {
                continue;
            }

            let is_newer = match best {
                None => true,
                Some(existing) => is_more_recent(session, existing),
            };

            if is_newer {
                best = Some(session);
            }
        }

        best
    }
}

pub fn sessions_snapshot() -> Option<DaemonSessionsSnapshot> {
    if !daemon_enabled() {
        return None;
    }

    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::GetSessions,
        id: Some("sessions-snapshot".to_string()),
        params: None,
    };

    let response = send_request(request).ok()?;
    if !response.ok {
        return None;
    }

    let data = response.data?;
    let sessions: Vec<DaemonSessionRecord> = serde_json::from_value(data).ok()?;
    Some(DaemonSessionsSnapshot { sessions })
}

pub(crate) fn daemon_health() -> Option<bool> {
    if !daemon_enabled() {
        return None;
    }

    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::GetHealth,
        id: Some("daemon-health".to_string()),
        params: None,
    };

    let response = send_request(request).ok()?;
    Some(response.ok)
}

pub(crate) fn daemon_enabled() -> bool {
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

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn is_more_recent(left: &DaemonSessionRecord, right: &DaemonSessionRecord) -> bool {
    let left_ts = parse_rfc3339(&left.updated_at).or_else(|| parse_rfc3339(&left.state_changed_at));
    let right_ts =
        parse_rfc3339(&right.updated_at).or_else(|| parse_rfc3339(&right.state_changed_at));

    match (left_ts, right_ts) {
        (Some(left), Some(right)) => left > right,
        (Some(_), None) => true,
        (None, Some(_)) => false,
        (None, None) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_session_record(
        session_id: &str,
        project_path: &str,
        updated_at: &str,
    ) -> DaemonSessionRecord {
        DaemonSessionRecord {
            session_id: session_id.to_string(),
            pid: 123,
            state: "working".to_string(),
            cwd: project_path.to_string(),
            project_path: project_path.to_string(),
            updated_at: updated_at.to_string(),
            state_changed_at: updated_at.to_string(),
            last_event: None,
            last_activity_at: None,
            tools_in_flight: 0,
            ready_reason: None,
            is_alive: Some(true),
        }
    }

    #[test]
    fn sessions_snapshot_parses_entries() {
        let value = serde_json::json!([
            {
                "session_id": "session-1",
                "pid": 123,
                "state": "working",
                "cwd": "/repo",
                "project_path": "/repo",
                "updated_at": "2026-01-31T00:00:00Z",
                "state_changed_at": "2026-01-31T00:00:00Z",
                "is_alive": true
            }
        ]);

        let entries: Vec<DaemonSessionRecord> =
            serde_json::from_value(value).expect("parse sessions");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].session_id, "session-1");
    }

    #[test]
    fn latest_for_project_matches_subpath() {
        let snapshot = DaemonSessionsSnapshot {
            sessions: vec![make_session_record(
                "session-1",
                "/Users/pete/Code/assistant-ui/packages/web",
                "2026-02-01T00:00:00Z",
            )],
        };

        let selected = snapshot
            .latest_for_project("/Users/pete/Code/assistant-ui")
            .expect("expected parent project to match child session path");

        assert_eq!(
            selected.project_path,
            "/Users/pete/Code/assistant-ui/packages/web"
        );
    }

    #[test]
    fn latest_for_project_does_not_match_parent_path() {
        let snapshot = DaemonSessionsSnapshot {
            sessions: vec![make_session_record(
                "session-1",
                "/Users/pete/Code/assistant-ui",
                "2026-02-01T00:00:00Z",
            )],
        };

        let selected = snapshot.latest_for_project("/Users/pete/Code/assistant-ui/packages/web");

        assert!(selected.is_none());
    }
}
