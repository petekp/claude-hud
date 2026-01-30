//! IPC protocol types and validation for capacitor-daemon.
//!
//! This module defines the on-the-wire schema and the rules we enforce at the
//! daemon boundary. The goal is to fail fast on malformed input so we never
//! accept events that could corrupt state.

use chrono::DateTime;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_REQUEST_BYTES: usize = 1024 * 1024; // 1MB

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Method {
    GetHealth,
    Event,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub protocol_version: u32,
    pub method: Method,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub params: Option<Value>,
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorInfo>,
}

#[derive(Debug, Serialize, Clone)]
pub struct ErrorInfo {
    pub code: String,
    pub message: String,
}

impl ErrorInfo {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

impl Response {
    pub fn ok(id: Option<String>, data: Value) -> Self {
        Self {
            ok: true,
            id,
            data: Some(data),
            error: None,
        }
    }

    pub fn error(id: Option<String>, code: &str, message: impl Into<String>) -> Self {
        Self {
            ok: false,
            id,
            data: None,
            error: Some(ErrorInfo::new(code, message)),
        }
    }

    pub fn error_with_info(id: Option<String>, error: ErrorInfo) -> Self {
        Self {
            ok: false,
            id,
            data: None,
            error: Some(error),
        }
    }
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum EventType {
    SessionStart,
    UserPromptSubmit,
    PostToolUse,
    Stop,
    SessionEnd,
    ShellCwd,
}

// IPC contract fields; not all are consumed in Phase 1, but we keep them
// to lock the schema early and avoid churn during client integration.
#[allow(dead_code)]
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EventEnvelope {
    pub event_id: String,
    pub recorded_at: String,
    pub event_type: EventType,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub tool: Option<String>,
    #[serde(default)]
    pub file_path: Option<String>,
    #[serde(default)]
    pub parent_app: Option<String>,
    #[serde(default)]
    pub tty: Option<String>,
    #[serde(default)]
    pub tmux_session: Option<String>,
    #[serde(default)]
    pub tmux_client_tty: Option<String>,
    #[serde(default)]
    pub metadata: Option<Value>,
}

impl EventEnvelope {
    pub fn validate(&self) -> Result<(), ErrorInfo> {
        if self.event_id.trim().is_empty() {
            return Err(ErrorInfo::new("invalid_event_id", "event_id is required"));
        }
        if self.event_id.len() > 128 {
            return Err(ErrorInfo::new(
                "invalid_event_id",
                "event_id must be 128 characters or fewer",
            ));
        }

        if DateTime::parse_from_rfc3339(&self.recorded_at).is_err() {
            return Err(ErrorInfo::new(
                "invalid_timestamp",
                "recorded_at must be RFC3339",
            ));
        }

        match self.event_type {
            EventType::ShellCwd => {
                require_pid(&self.pid)?;
                require_string(&self.cwd, "cwd")?;
                require_string(&self.tty, "tty")?;
            }
            EventType::SessionStart
            | EventType::UserPromptSubmit
            | EventType::PostToolUse
            | EventType::Stop
            | EventType::SessionEnd => {
                require_string(&self.session_id, "session_id")?;
                require_pid(&self.pid)?;
                require_string(&self.cwd, "cwd")?;
            }
        }

        Ok(())
    }
}

pub fn parse_event(params: Value) -> Result<EventEnvelope, ErrorInfo> {
    let envelope: EventEnvelope = serde_json::from_value(params).map_err(|err| {
        ErrorInfo::new(
            "invalid_params",
            format!("event payload is invalid JSON: {}", err),
        )
    })?;
    envelope.validate()?;
    Ok(envelope)
}

fn require_string(value: &Option<String>, field: &str) -> Result<(), ErrorInfo> {
    if let Some(candidate) = value {
        if !candidate.trim().is_empty() {
            return Ok(());
        }
    }
    Err(ErrorInfo::new(
        "missing_field",
        format!("{} is required", field),
    ))
}

fn require_pid(pid: &Option<u32>) -> Result<(), ErrorInfo> {
    match pid {
        Some(0) | None => Err(ErrorInfo::new("invalid_pid", "pid is required")),
        Some(_) => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_event(event_type: EventType) -> EventEnvelope {
        EventEnvelope {
            event_id: "evt-1".to_string(),
            recorded_at: "2026-01-30T12:00:00Z".to_string(),
            event_type,
            session_id: Some("session-1".to_string()),
            pid: Some(1234),
            cwd: Some("/repo".to_string()),
            tool: None,
            file_path: None,
            parent_app: None,
            tty: None,
            tmux_session: None,
            tmux_client_tty: None,
            metadata: None,
        }
    }

    #[test]
    fn validates_session_event() {
        let event = base_event(EventType::SessionStart);
        assert!(event.validate().is_ok());
    }

    #[test]
    fn rejects_missing_session_id() {
        let mut event = base_event(EventType::SessionStart);
        event.session_id = None;
        assert!(event.validate().is_err());
    }

    #[test]
    fn validates_shell_cwd_requires_tty() {
        let mut event = base_event(EventType::ShellCwd);
        event.tty = None;
        event.session_id = None;
        assert!(event.validate().is_err());
    }

    #[test]
    fn rejects_bad_timestamp() {
        let mut event = base_event(EventType::SessionEnd);
        event.recorded_at = "not-a-time".to_string();
        assert!(event.validate().is_err());
    }

    #[test]
    fn rejects_long_event_id() {
        let mut event = base_event(EventType::SessionEnd);
        event.event_id = "a".repeat(256);
        assert!(event.validate().is_err());
    }
}
