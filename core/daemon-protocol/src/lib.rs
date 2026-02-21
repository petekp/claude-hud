//! IPC protocol types and validation for capacitor-daemon.
//!
//! This crate is shared by the daemon and its clients to prevent schema drift.
//! The daemon remains the authority on validation, but clients can reuse the
//! same types to construct valid requests.

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_REQUEST_BYTES: usize = 1024 * 1024; // 1MB
pub const ERROR_UNAUTHORIZED_PEER: &str = "unauthorized_peer";
pub const ERROR_TOO_MANY_CONNECTIONS: &str = "too_many_connections";
pub const ERROR_INVALID_PROJECT_PATH: &str = "invalid_project_path";

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Method {
    GetHealth,
    GetShellState,
    GetProcessLiveness,
    GetRoutingSnapshot,
    GetRoutingDiagnostics,
    GetConfig,
    GetSessions,
    GetProjectStates,
    GetActivity,
    GetTombstones,
    Event,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub protocol_version: u32,
    pub method: Method,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub params: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProcessLivenessRequest {
    pub pid: u32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoutingSnapshotRequest {
    pub project_path: String,
    #[serde(default)]
    pub workspace_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoutingDiagnosticsRequest {
    pub project_path: String,
    #[serde(default)]
    pub workspace_id: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RoutingStatus {
    Attached,
    Detached,
    Unavailable,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RoutingTargetKind {
    TmuxSession,
    TerminalApp,
    None,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RoutingConfidence {
    High,
    Medium,
    Low,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RoutingTarget {
    pub kind: RoutingTargetKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RoutingEvidence {
    pub evidence_type: String,
    pub value: String,
    pub age_ms: u64,
    pub trust_rank: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RoutingSnapshot {
    pub version: u32,
    pub workspace_id: String,
    pub project_path: String,
    pub status: RoutingStatus,
    pub target: RoutingTarget,
    pub confidence: RoutingConfidence,
    pub reason_code: String,
    pub reason: String,
    pub evidence: Vec<RoutingEvidence>,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RoutingDiagnostics {
    pub snapshot: RoutingSnapshot,
    pub signal_ages_ms: HashMap<String, u64>,
    pub candidate_targets: Vec<RoutingTarget>,
    pub conflicts: Vec<String>,
    pub scope_resolution: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RoutingConfigView {
    pub tmux_signal_fresh_ms: u64,
    pub shell_signal_fresh_ms: u64,
    pub shell_retention_hours: u64,
    pub tmux_poll_interval_ms: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Response {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorInfo>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
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

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq, Clone, Copy)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum EventType {
    SessionStart,
    UserPromptSubmit,
    PreToolUse,
    PostToolUse,
    PostToolUseFailure,
    PermissionRequest,
    PreCompact,
    Notification,
    SubagentStart,
    SubagentStop,
    Stop,
    TeammateIdle,
    TaskCompleted,
    WorktreeCreate,
    WorktreeRemove,
    ConfigChange,
    SessionEnd,
    ShellCwd,
}

// IPC contract fields; not all are consumed in Phase 1, but we keep them
// to lock the schema early and avoid churn during client integration.
#[allow(dead_code)]
#[derive(Debug, Deserialize, Serialize)]
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
    pub notification_type: Option<String>,
    #[serde(default)]
    pub stop_hook_active: Option<bool>,
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
            EventType::Notification => {
                require_session_fields(self)?;
                require_string(&self.notification_type, "notification_type")?;
            }
            EventType::Stop => {
                require_session_fields(self)?;
                require_bool(&self.stop_hook_active, "stop_hook_active")?;
            }
            EventType::SessionEnd => {
                require_string(&self.session_id, "session_id")?;
            }
            // All other event types require standard session fields.
            _ => {
                require_session_fields(self)?;
            }
        }

        Ok(())
    }
}

pub fn parse_event(params: Value) -> Result<EventEnvelope, ErrorInfo> {
    let mut envelope: EventEnvelope = serde_json::from_value(params).map_err(|err| {
        ErrorInfo::new(
            "invalid_params",
            format!("event payload is invalid JSON: {}", err),
        )
    })?;
    envelope.recorded_at = normalize_recorded_at(&envelope.recorded_at)?;
    envelope.validate()?;
    Ok(envelope)
}

pub fn parse_process_liveness(params: Value) -> Result<ProcessLivenessRequest, ErrorInfo> {
    serde_json::from_value(params).map_err(|err| {
        ErrorInfo::new(
            "invalid_params",
            format!("process liveness params are invalid JSON: {}", err),
        )
    })
}

pub fn parse_routing_snapshot(params: Value) -> Result<RoutingSnapshotRequest, ErrorInfo> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct RawRoutingRequest {
        #[serde(default)]
        project_path: Option<String>,
        #[serde(default)]
        workspace_id: Option<String>,
    }

    let parsed: RawRoutingRequest = serde_json::from_value(params).map_err(|err| {
        ErrorInfo::new(
            "invalid_params",
            format!("routing snapshot params are invalid JSON: {}", err),
        )
    })?;

    Ok(RoutingSnapshotRequest {
        project_path: normalize_required_string(
            parsed.project_path.unwrap_or_default(),
            "project_path",
        )?,
        workspace_id: normalize_optional_string(parsed.workspace_id),
    })
}

pub fn parse_routing_diagnostics(params: Value) -> Result<RoutingDiagnosticsRequest, ErrorInfo> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct RawRoutingRequest {
        #[serde(default)]
        project_path: Option<String>,
        #[serde(default)]
        workspace_id: Option<String>,
    }

    let parsed: RawRoutingRequest = serde_json::from_value(params).map_err(|err| {
        ErrorInfo::new(
            "invalid_params",
            format!("routing diagnostics params are invalid JSON: {}", err),
        )
    })?;

    Ok(RoutingDiagnosticsRequest {
        project_path: normalize_required_string(
            parsed.project_path.unwrap_or_default(),
            "project_path",
        )?,
        workspace_id: normalize_optional_string(parsed.workspace_id),
    })
}

fn require_session_fields(event: &EventEnvelope) -> Result<(), ErrorInfo> {
    require_string(&event.session_id, "session_id")?;
    require_string(&event.cwd, "cwd")?;
    Ok(())
}

fn normalize_recorded_at(value: &str) -> Result<String, ErrorInfo> {
    let timestamp = DateTime::parse_from_rfc3339(value)
        .map_err(|_| ErrorInfo::new("invalid_timestamp", "recorded_at must be RFC3339"))?;
    Ok(timestamp
        .with_timezone(&Utc)
        .to_rfc3339_opts(SecondsFormat::Secs, true))
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

fn require_bool(value: &Option<bool>, field: &str) -> Result<(), ErrorInfo> {
    match value {
        Some(_) => Ok(()),
        None => Err(ErrorInfo::new(
            "missing_field",
            format!("{} is required", field),
        )),
    }
}

fn normalize_required_string(value: String, field: &str) -> Result<String, ErrorInfo> {
    let normalized = value.trim().to_string();
    if normalized.is_empty() {
        return Err(ErrorInfo::new(
            "missing_field",
            format!("{} is required", field),
        ));
    }
    Ok(normalized)
}

fn normalize_optional_string(value: Option<String>) -> Option<String> {
    value.and_then(|candidate| {
        let normalized = candidate.trim().to_string();
        if normalized.is_empty() {
            None
        } else {
            Some(normalized)
        }
    })
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
            notification_type: None,
            stop_hook_active: None,
            metadata: None,
        }
    }

    #[test]
    fn validates_session_event() {
        let event = base_event(EventType::SessionStart);
        assert!(event.validate().is_ok());
    }

    #[test]
    fn validates_stop_requires_flag() {
        let event = base_event(EventType::Stop);
        assert!(event.validate().is_err());
    }

    #[test]
    fn validates_notification_requires_type() {
        let event = base_event(EventType::Notification);
        assert!(event.validate().is_err());
    }

    #[test]
    fn rejects_missing_session_id() {
        let mut event = base_event(EventType::SessionStart);
        event.session_id = None;
        assert!(event.validate().is_err());
    }

    #[test]
    fn session_end_allows_missing_cwd() {
        let mut event = base_event(EventType::SessionEnd);
        event.cwd = None;
        assert!(event.validate().is_ok());
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

    #[test]
    fn parse_event_normalizes_recorded_at_to_utc_z() {
        let params = serde_json::json!({
            "event_id": "evt-1",
            "recorded_at": "2026-01-30T07:00:00-05:00",
            "event_type": "session_start",
            "session_id": "session-1",
            "pid": 1234,
            "cwd": "/repo"
        });

        let parsed = parse_event(params).expect("parse event");
        assert_eq!(parsed.recorded_at, "2026-01-30T12:00:00Z");
    }

    #[test]
    fn session_events_allow_missing_pid() {
        let mut event = base_event(EventType::SessionStart);
        event.pid = None;
        assert!(event.validate().is_ok());

        let mut end_event = base_event(EventType::SessionEnd);
        end_event.pid = None;
        assert!(end_event.validate().is_ok());
    }

    #[test]
    fn shell_cwd_requires_pid() {
        let mut event = base_event(EventType::ShellCwd);
        event.session_id = None;
        event.pid = None;
        assert!(event.validate().is_err());
    }

    #[test]
    fn parse_routing_snapshot_requires_project_path() {
        let params = serde_json::json!({});
        let error = parse_routing_snapshot(params).expect_err("missing project path should fail");
        assert_eq!(error.code, "missing_field");
    }

    #[test]
    fn parse_routing_snapshot_supports_workspace_id() {
        let params = serde_json::json!({
            "project_path": "/Users/petepetrash/Code/capacitor",
            "workspace_id": "workspace-1"
        });
        let parsed = parse_routing_snapshot(params).expect("parse routing snapshot request");
        assert_eq!(parsed.project_path, "/Users/petepetrash/Code/capacitor");
        assert_eq!(parsed.workspace_id.as_deref(), Some("workspace-1"));
    }

    #[test]
    fn parse_routing_diagnostics_requires_project_path() {
        let params = serde_json::json!({
            "workspace_id": "workspace-2"
        });
        let error =
            parse_routing_diagnostics(params).expect_err("missing project path should fail");
        assert_eq!(error.code, "missing_field");
    }

    #[test]
    fn method_serializes_new_routing_variants_as_snake_case() {
        let snapshot = serde_json::to_string(&Method::GetRoutingSnapshot).expect("serialize");
        let diagnostics = serde_json::to_string(&Method::GetRoutingDiagnostics).expect("serialize");
        let config = serde_json::to_string(&Method::GetConfig).expect("serialize");

        assert_eq!(snapshot, "\"get_routing_snapshot\"");
        assert_eq!(diagnostics, "\"get_routing_diagnostics\"");
        assert_eq!(config, "\"get_config\"");
    }
}
