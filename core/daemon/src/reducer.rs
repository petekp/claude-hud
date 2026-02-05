use capacitor_daemon_protocol::{EventEnvelope, EventType};
use serde::Serialize;

use crate::project_identity::resolve_project_identity;

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
    pub project_id: String,
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

    if is_event_stale(current, event) {
        return SessionUpdate::Skip;
    }

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

fn is_event_stale(current: Option<&SessionRecord>, event: &EventEnvelope) -> bool {
    let Some(current) = current else { return false };
    let Some(event_time) = parse_rfc3339(&event.recorded_at) else {
        return false;
    };
    let Some(current_time) = parse_rfc3339(&current.updated_at) else {
        return false;
    };

    event_time < current_time
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
    let identity = derive_project_identity(&cwd, event.file_path.as_deref());
    let project_path = identity
        .as_ref()
        .map(|identity| identity.project_path.clone())
        .or_else(|| current.map(|record| record.project_path.clone()))
        .or_else(|| {
            if cwd.trim().is_empty() {
                None
            } else {
                Some(cwd.clone())
            }
        })
        .unwrap_or_default();
    let project_id = identity
        .as_ref()
        .map(|identity| identity.project_id.clone())
        .or_else(|| current.map(|record| record.project_id.clone()))
        .or_else(|| {
            if project_path.trim().is_empty() {
                None
            } else {
                Some(project_path.clone())
            }
        })
        .unwrap_or_default();
    let mut project_path = project_path;
    let mut project_id = project_id;
    if event.file_path.is_none() {
        if let Some(current_record) = current {
            if !current_record.project_path.is_empty()
                && is_parent_path(&project_path, &current_record.project_path)
            {
                project_path = current_record.project_path.clone();
                if !current_record.project_id.trim().is_empty() {
                    project_id = current_record.project_id.clone();
                }
            }
        }
    }

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
        project_id,
        project_path,
        updated_at,
        state_changed_at,
        last_event: Some(event_type_string(&event.event_type)),
    })
}

fn is_parent_path(parent: &str, child: &str) -> bool {
    if parent == child {
        return true;
    }
    let parent = parent.trim_end_matches('/');
    let child = child.trim_end_matches('/');
    if parent.is_empty() || child.is_empty() {
        return false;
    }
    if child == parent {
        return true;
    }
    child.starts_with(&(parent.to_string() + "/"))
}

fn derive_project_identity(
    cwd: &str,
    file_path: Option<&str>,
) -> Option<crate::project_identity::ProjectIdentity> {
    if let Some(file_path) = file_path {
        if let Some(resolved) = resolve_file_path(cwd, file_path) {
            if let Some(identity) = resolve_project_identity(&resolved) {
                return Some(identity);
            }
        }
    }

    if cwd.trim().is_empty() {
        return None;
    }

    resolve_project_identity(cwd)
}

fn resolve_file_path(cwd: &str, file_path: &str) -> Option<String> {
    let path = std::path::Path::new(file_path);
    if path.is_absolute() {
        return Some(file_path.to_string());
    }

    if cwd.trim().is_empty() {
        return None;
    }

    let combined = std::path::Path::new(cwd).join(file_path);
    combined.to_str().map(|value| value.to_string())
}

fn event_type_string(event_type: &EventType) -> String {
    serde_json::to_string(event_type)
        .unwrap_or_else(|_| "unknown".to_string())
        .trim_matches('"')
        .to_string()
}

fn parse_rfc3339(value: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    chrono::DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|dt| dt.with_timezone(&chrono::Utc))
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
            project_id: "/repo/.git".to_string(),
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
    fn file_path_boundary_overrides_cwd_boundary() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("repo");
        let docs_dir = repo_root.join("apps").join("docs");
        let src_dir = docs_dir.join("src");

        std::fs::create_dir_all(&src_dir).expect("create dirs");
        std::fs::create_dir_all(repo_root.join(".git")).expect("create git dir");
        std::fs::write(docs_dir.join("package.json"), "{}").expect("package marker");
        std::fs::write(src_dir.join("index.ts"), "export {}").expect("file");

        let mut event = event_base(EventType::PostToolUse);
        event.cwd = Some(repo_root.to_string_lossy().to_string());
        event.file_path = Some(src_dir.join("index.ts").to_string_lossy().to_string());

        let update = reduce_session(None, &event);

        match update {
            SessionUpdate::Upsert(record) => {
                let expected = std::fs::canonicalize(&docs_dir)
                    .unwrap_or(docs_dir.clone())
                    .to_string_lossy()
                    .to_string();
                assert_eq!(record.project_path, expected);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn worktree_boundary_canonicalizes_to_repo_root() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("assistant-ui");
        let repo_git = repo_root.join(".git");
        let docs_dir = repo_root.join("apps").join("docs");
        let src_dir = docs_dir.join("src");

        std::fs::create_dir_all(&src_dir).expect("create repo dirs");
        std::fs::create_dir_all(&repo_git).expect("create git dir");
        std::fs::write(docs_dir.join("package.json"), "{}").expect("package marker");
        std::fs::write(src_dir.join("index.ts"), "export {}").expect("file");

        let worktree_root = temp_dir.path().join("assistant-ui-wt");
        let worktree_docs = worktree_root.join("apps").join("docs");
        std::fs::create_dir_all(worktree_docs.join("src")).expect("create worktree dirs");
        std::fs::write(worktree_docs.join("package.json"), "{}").expect("package marker");
        std::fs::write(worktree_docs.join("src").join("index.ts"), "export {}").expect("file");

        let worktree_gitdir = repo_git.join("worktrees").join("feat-docs");
        std::fs::create_dir_all(&worktree_gitdir).expect("create gitdir");
        std::fs::write(worktree_gitdir.join("commondir"), "../..").expect("commondir");
        std::fs::write(
            worktree_root.join(".git"),
            format!("gitdir: {}\n", worktree_gitdir.to_string_lossy()),
        )
        .expect("git file");

        let mut event = event_base(EventType::PostToolUse);
        event.cwd = Some(worktree_root.to_string_lossy().to_string());
        event.file_path = Some(
            worktree_docs
                .join("src")
                .join("index.ts")
                .to_string_lossy()
                .to_string(),
        );

        let update = reduce_session(None, &event);

        match update {
            SessionUpdate::Upsert(record) => {
                let expected_docs = std::fs::canonicalize(&docs_dir)
                    .unwrap_or(docs_dir.clone())
                    .to_string_lossy()
                    .to_string();
                let expected_git = std::fs::canonicalize(&repo_git)
                    .unwrap_or(repo_git.clone())
                    .to_string_lossy()
                    .to_string();
                assert_eq!(record.project_path, expected_docs);
                assert_eq!(record.project_id, expected_git);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn pre_compact_keeps_previous_package_project() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("assistant-ui");
        let repo_git = repo_root.join(".git");
        let docs_dir = repo_root.join("apps").join("docs");
        let docs_git = docs_dir.join(".git");
        let src_dir = docs_dir.join("src");

        std::fs::create_dir_all(&src_dir).expect("create repo dirs");
        std::fs::create_dir_all(&repo_git).expect("create git dir");
        std::fs::create_dir_all(&docs_git).expect("create docs git dir");
        std::fs::write(docs_dir.join("package.json"), "{}").expect("package marker");

        let expected_docs = std::fs::canonicalize(&docs_dir)
            .unwrap_or(docs_dir.clone())
            .to_string_lossy()
            .to_string();
        let expected_git = std::fs::canonicalize(&docs_git)
            .unwrap_or(docs_git.clone())
            .to_string_lossy()
            .to_string();

        let current = SessionRecord {
            session_id: "session-1".to_string(),
            pid: 1234,
            state: SessionState::Working,
            cwd: repo_root.to_string_lossy().to_string(),
            project_id: expected_git.clone(),
            project_path: expected_docs.clone(),
            updated_at: "2026-01-31T00:00:00Z".to_string(),
            state_changed_at: "2026-01-31T00:00:00Z".to_string(),
            last_event: Some("post_tool_use".to_string()),
        };

        let mut event = event_base(EventType::PreCompact);
        event.cwd = Some(repo_root.to_string_lossy().to_string());

        let update = reduce_session(Some(&current), &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.project_path, expected_docs);
                assert_eq!(record.project_id, expected_git);
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

    #[test]
    fn stale_event_is_skipped() {
        let mut event = event_base(EventType::UserPromptSubmit);
        event.recorded_at = "2026-01-31T00:00:00Z".to_string();
        let current = SessionRecord {
            session_id: "session-1".to_string(),
            pid: 1234,
            state: SessionState::Ready,
            cwd: "/repo".to_string(),
            project_id: "/repo/.git".to_string(),
            project_path: "/repo".to_string(),
            updated_at: "2026-01-31T00:00:10Z".to_string(),
            state_changed_at: "2026-01-31T00:00:10Z".to_string(),
            last_event: Some("session_start".to_string()),
        };

        let update = reduce_session(Some(&current), &event);
        assert_eq!(update, SessionUpdate::Skip);
    }
}
