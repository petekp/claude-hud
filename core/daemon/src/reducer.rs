use capacitor_daemon_protocol::{EventEnvelope, EventType};
use serde::Serialize;

use crate::boundaries::find_project_boundary;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionState {
    Working,
    Ready,
    Idle,
    Compacting,
    Waiting,
}

impl SessionState {
    fn is_active(&self) -> bool {
        matches!(
            self,
            SessionState::Working | SessionState::Waiting | SessionState::Compacting
        )
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            SessionState::Working => "working",
            SessionState::Ready => "ready",
            SessionState::Idle => "idle",
            SessionState::Compacting => "compacting",
            SessionState::Waiting => "waiting",
        }
    }

    pub fn from_str(value: &str) -> Option<Self> {
        match value {
            "working" => Some(SessionState::Working),
            "ready" => Some(SessionState::Ready),
            "idle" => Some(SessionState::Idle),
            "compacting" => Some(SessionState::Compacting),
            "waiting" => Some(SessionState::Waiting),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SessionRecord {
    pub session_id: String,
    pub pid: u32,
    pub state: SessionState,
    pub cwd: String,
    pub project_path: String,
    pub updated_at: String,
    pub state_changed_at: String,
    pub last_event: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionUpdate {
    Upsert(SessionRecord),
    Delete { session_id: String },
    Skip,
}

pub fn reduce_session(current: Option<&SessionRecord>, event: &EventEnvelope) -> SessionUpdate {
    if event.event_type == EventType::ShellCwd {
        return SessionUpdate::Skip;
    }

    let session_id = match event.session_id.as_ref() {
        Some(value) => value.clone(),
        None => return SessionUpdate::Skip,
    };

    match event.event_type {
        EventType::SessionStart => {
            if current
                .map(|record| record.state.is_active())
                .unwrap_or(false)
            {
                SessionUpdate::Skip
            } else {
                upsert_session(current, event, session_id, SessionState::Ready)
            }
        }
        EventType::UserPromptSubmit => {
            upsert_session(current, event, session_id, SessionState::Working)
        }
        EventType::PreToolUse | EventType::PostToolUse => {
            upsert_session(current, event, session_id, SessionState::Working)
        }
        EventType::PermissionRequest => {
            upsert_session(current, event, session_id, SessionState::Waiting)
        }
        EventType::PreCompact => {
            upsert_session(current, event, session_id, SessionState::Compacting)
        }
        EventType::Notification => {
            if event.notification_type.as_deref() == Some("idle_prompt") {
                upsert_session(current, event, session_id, SessionState::Ready)
            } else {
                SessionUpdate::Skip
            }
        }
        EventType::Stop => {
            if event.stop_hook_active == Some(true) {
                SessionUpdate::Skip
            } else {
                upsert_session(current, event, session_id, SessionState::Ready)
            }
        }
        EventType::SessionEnd => SessionUpdate::Delete { session_id },
        EventType::ShellCwd => SessionUpdate::Skip,
    }
}

fn upsert_session(
    current: Option<&SessionRecord>,
    event: &EventEnvelope,
    session_id: String,
    new_state: SessionState,
) -> SessionUpdate {
    let pid = event
        .pid
        .or_else(|| current.map(|record| record.pid))
        .unwrap_or(0);
    let cwd = event
        .cwd
        .clone()
        .or_else(|| current.map(|record| record.cwd.clone()))
        .unwrap_or_default();
    let project_path = derive_project_path(&cwd)
        .or_else(|| current.map(|record| record.project_path.clone()))
        .or_else(|| {
            if cwd.trim().is_empty() {
                None
            } else {
                Some(cwd.clone())
            }
        })
        .unwrap_or_default();

    let updated_at = event.recorded_at.clone();
    let state_changed_at = match current {
        Some(record) if record.state == new_state => record.state_changed_at.clone(),
        _ => updated_at.clone(),
    };

    SessionUpdate::Upsert(SessionRecord {
        session_id,
        pid,
        state: new_state,
        cwd,
        project_path,
        updated_at,
        state_changed_at,
        last_event: Some(event_type_string(&event.event_type)),
    })
}

fn derive_project_path(cwd: &str) -> Option<String> {
    if cwd.trim().is_empty() {
        return None;
    }
    find_project_boundary(cwd).map(|boundary| boundary.path)
}

fn event_type_string(event_type: &EventType) -> String {
    serde_json::to_string(event_type)
        .unwrap_or_else(|_| "unknown".to_string())
        .trim_matches('"')
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event_base(event_type: EventType) -> EventEnvelope {
        EventEnvelope {
            event_id: "evt-1".to_string(),
            recorded_at: "2026-01-31T00:00:00Z".to_string(),
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

    fn record_with_state(state: SessionState, state_changed_at: &str) -> SessionRecord {
        SessionRecord {
            session_id: "session-1".to_string(),
            pid: 1234,
            state,
            cwd: "/repo".to_string(),
            project_path: "/repo".to_string(),
            updated_at: "2026-01-30T23:59:00Z".to_string(),
            state_changed_at: state_changed_at.to_string(),
            last_event: Some("session_start".to_string()),
        }
    }

    #[test]
    fn session_start_sets_ready_when_not_active() {
        let event = event_base(EventType::SessionStart);
        let update = reduce_session(None, &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.updated_at, event.recorded_at);
                assert_eq!(record.state_changed_at, event.recorded_at);
                assert_eq!(record.cwd, "/repo");
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn session_start_skips_when_active() {
        let event = event_base(EventType::SessionStart);
        let current = record_with_state(SessionState::Working, "2026-01-30T23:59:00Z");
        let update = reduce_session(Some(&current), &event);
        assert_eq!(update, SessionUpdate::Skip);
    }

    #[test]
    fn missing_boundary_keeps_existing_project_path() {
        let mut event = event_base(EventType::UserPromptSubmit);
        event.cwd = Some("/does/not/exist".to_string());
        let current = record_with_state(SessionState::Ready, "2026-01-30T23:50:00Z");

        let update = reduce_session(Some(&current), &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.project_path, current.project_path);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn user_prompt_sets_working_and_updates_state_changed_at() {
        let event = event_base(EventType::UserPromptSubmit);
        let current = record_with_state(SessionState::Ready, "2026-01-30T23:50:00Z");
        let update = reduce_session(Some(&current), &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Working);
                assert_eq!(record.state_changed_at, event.recorded_at);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn pre_tool_use_heartbeat_when_already_working() {
        let event = event_base(EventType::PreToolUse);
        let current = record_with_state(SessionState::Working, "2026-01-30T23:55:00Z");
        let update = reduce_session(Some(&current), &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Working);
                assert_eq!(record.state_changed_at, current.state_changed_at);
                assert_eq!(record.updated_at, event.recorded_at);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn post_tool_use_sets_working_when_not_working() {
        let event = event_base(EventType::PostToolUse);
        let current = record_with_state(SessionState::Ready, "2026-01-30T23:55:00Z");
        let update = reduce_session(Some(&current), &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Working);
                assert_eq!(record.state_changed_at, event.recorded_at);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn permission_request_sets_waiting() {
        let event = event_base(EventType::PermissionRequest);
        let update = reduce_session(None, &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Waiting);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn notification_idle_prompt_sets_ready() {
        let mut event = event_base(EventType::Notification);
        event.notification_type = Some("idle_prompt".to_string());
        let update = reduce_session(None, &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn notification_non_idle_is_skipped() {
        let mut event = event_base(EventType::Notification);
        event.notification_type = Some("other".to_string());
        let update = reduce_session(None, &event);
        assert_eq!(update, SessionUpdate::Skip);
    }

    #[test]
    fn stop_hook_active_skips() {
        let mut event = event_base(EventType::Stop);
        event.stop_hook_active = Some(true);
        let update = reduce_session(None, &event);
        assert_eq!(update, SessionUpdate::Skip);
    }

    #[test]
    fn stop_hook_inactive_sets_ready() {
        let mut event = event_base(EventType::Stop);
        event.stop_hook_active = Some(false);
        let update = reduce_session(None, &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn session_end_deletes() {
        let event = event_base(EventType::SessionEnd);
        let update = reduce_session(None, &event);
        assert_eq!(
            update,
            SessionUpdate::Delete {
                session_id: "session-1".to_string()
            }
        );
    }
}
