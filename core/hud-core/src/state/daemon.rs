//! Daemon client helpers for state liveness checks.
//!
//! These are best-effort: failures should never block or crash callers. When
//! the daemon is unavailable, callers should fall back to local checks.

use capacitor_daemon_protocol::{Method, Request, Response, MAX_REQUEST_BYTES, PROTOCOL_VERSION};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
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

#[derive(Debug, Deserialize)]
pub struct DaemonActivityEntry {
    pub project_path: String,
    pub file_path: String,
    pub recorded_at: String,
}

pub struct DaemonActivitySnapshot {
    entries: Vec<DaemonActivityEntry>,
}

impl DaemonActivitySnapshot {
    pub fn has_recent_activity_in_path(&self, project_path: &str, threshold: Duration) -> bool {
        let normalized_query = crate::state::normalize_path_for_comparison(project_path);
        let prefix = if normalized_query == "/" {
            "/".to_string()
        } else {
            format!("{}/", normalized_query)
        };
        let now = Utc::now();
        let threshold =
            ChronoDuration::from_std(threshold).unwrap_or_else(|_| ChronoDuration::zero());

        for entry in &self.entries {
            if crate::state::normalize_path_for_comparison(&entry.project_path) != normalized_query
            {
                continue;
            }

            let timestamp = match parse_rfc3339(&entry.recorded_at) {
                Some(ts) => ts,
                None => continue,
            };
            if now.signed_duration_since(timestamp) > threshold {
                continue;
            }

            let activity_path = crate::state::normalize_path_for_comparison(&entry.file_path);
            if !activity_path.starts_with('/') {
                continue;
            }
            if activity_path == normalized_query || activity_path.starts_with(&prefix) {
                return true;
            }
        }

        false
    }
}

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
        let normalized_query = crate::state::normalize_path_for_comparison(project_path);
        let mut best: Option<&DaemonSessionRecord> = None;

        for session in &self.sessions {
            if crate::state::normalize_path_for_comparison(&session.project_path)
                != normalized_query
            {
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

pub fn process_liveness(pid: u32) -> Option<ProcessLivenessSnapshot> {
    if !daemon_enabled() {
        return None;
    }

    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::GetProcessLiveness,
        id: Some(format!("pid-{}", pid)),
        params: Some(serde_json::json!({ "pid": pid })),
    };

    let response = send_request(request).ok()?;
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

pub fn activity_snapshot(limit: usize) -> Option<DaemonActivitySnapshot> {
    if !daemon_enabled() {
        return None;
    }

    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::GetActivity,
        id: Some("activity-snapshot".to_string()),
        params: Some(serde_json::json!({ "limit": limit })),
    };

    let response = send_request(request).ok()?;
    if !response.ok {
        return None;
    }

    let data = response.data?;
    let entries: Vec<DaemonActivityEntry> = serde_json::from_value(data).ok()?;
    Some(DaemonActivitySnapshot { entries })
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

    #[test]
    fn parses_activity_entries() {
        let value = serde_json::json!([
            {
                "project_path": "/repo",
                "file_path": "/repo/src/main.rs",
                "recorded_at": "2026-01-31T00:00:00Z"
            }
        ]);

        let entries: Vec<DaemonActivityEntry> =
            serde_json::from_value(value).expect("parse activity entries");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].project_path, "/repo");
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
}
