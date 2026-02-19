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
    pub last_activity_at: Option<String>,
    pub tools_in_flight: u32,
    pub ready_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(clippy::large_enum_variant)]
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
                upsert_session(current, event, session_id, SessionState::Ready, None)
            }
        }
        EventType::UserPromptSubmit => {
            upsert_session(current, event, session_id, SessionState::Working, None)
        }
        EventType::PreToolUse => {
            upsert_session(current, event, session_id, SessionState::Working, None)
        }
        EventType::PostToolUse | EventType::PostToolUseFailure => {
            let state = if current
                .map(|record| record.state == SessionState::Compacting)
                .unwrap_or(false)
            {
                SessionState::Compacting
            } else {
                SessionState::Working
            };
            upsert_session(current, event, session_id, state, None)
        }
        EventType::PermissionRequest => {
            upsert_session(current, event, session_id, SessionState::Waiting, None)
        }
        EventType::PreCompact => {
            upsert_session(current, event, session_id, SessionState::Compacting, None)
        }
        EventType::Notification => match event.notification_type.as_deref() {
            Some("idle_prompt") => {
                if current
                    .map(|record| record.tools_in_flight > 0)
                    .unwrap_or(false)
                {
                    SessionUpdate::Skip
                } else {
                    upsert_session(
                        current,
                        event,
                        session_id,
                        SessionState::Ready,
                        Some("idle_prompt".to_string()),
                    )
                }
            }
            Some("auth_success") => upsert_session(
                current,
                event,
                session_id,
                SessionState::Ready,
                Some("auth_success".to_string()),
            ),
            Some("permission_prompt") => upsert_session(
                current,
                event,
                session_id,
                SessionState::Waiting,
                Some("permission_prompt".to_string()),
            ),
            Some("elicitation_dialog") => {
                upsert_session(current, event, session_id, SessionState::Waiting, None)
            }
            _ => SessionUpdate::Skip,
        },
        EventType::SubagentStart | EventType::SubagentStop | EventType::TeammateIdle => {
            SessionUpdate::Skip
        }
        EventType::Stop => {
            if should_skip_stop(current, event) {
                SessionUpdate::Skip
            } else {
                upsert_session(
                    current,
                    event,
                    session_id,
                    SessionState::Ready,
                    Some("stop_gate".to_string()),
                )
            }
        }
        EventType::TaskCompleted => {
            if has_auxiliary_task_metadata(event) {
                SessionUpdate::Skip
            } else {
                upsert_session(
                    current,
                    event,
                    session_id,
                    SessionState::Ready,
                    Some("task_completed".to_string()),
                )
            }
        }
        EventType::SessionEnd => SessionUpdate::Delete { session_id },
        EventType::ShellCwd => SessionUpdate::Skip,
    }
}

fn has_non_empty_metadata_string(event: &EventEnvelope, key: &str) -> bool {
    event
        .metadata
        .as_ref()
        .and_then(|value| value.get(key))
        .and_then(|value| value.as_str())
        .map(|value| !value.is_empty())
        .unwrap_or(false)
}

fn has_agent_id_metadata(event: &EventEnvelope) -> bool {
    has_non_empty_metadata_string(event, "agent_id")
}

fn has_auxiliary_task_metadata(event: &EventEnvelope) -> bool {
    has_agent_id_metadata(event) || has_non_empty_metadata_string(event, "teammate_name")
}

fn should_skip_stop(current: Option<&SessionRecord>, event: &EventEnvelope) -> bool {
    if current
        .map(|record| record.state == SessionState::Compacting)
        .unwrap_or(false)
    {
        return true;
    }

    if event.stop_hook_active == Some(true) || has_agent_id_metadata(event) {
        return true;
    }

    false
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
    ready_reason: Option<String>,
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
    let resolved_file_path = event
        .file_path
        .as_deref()
        .and_then(|path| resolve_file_path(&cwd, path));
    let file_path_for_identity = match (current, resolved_file_path.as_deref()) {
        (Some(current_record), Some(resolved))
            if !current_record.project_path.trim().is_empty()
                && !is_parent_path(&current_record.project_path, resolved) =>
        {
            None
        }
        _ => event.file_path.as_deref(),
    };
    let identity = derive_project_identity(&cwd, file_path_for_identity);
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
    let mut last_activity_at = current.and_then(|record| record.last_activity_at.clone());
    if should_update_activity(&event.event_type) {
        last_activity_at = Some(updated_at.clone());
    }

    let tools_in_flight = adjust_tools_in_flight(
        current.map(|record| record.tools_in_flight).unwrap_or(0),
        &event.event_type,
    );
    let ready_reason = if new_state == SessionState::Ready {
        ready_reason.or_else(|| current.and_then(|record| record.ready_reason.clone()))
    } else {
        None
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
        last_activity_at,
        tools_in_flight,
        ready_reason,
    })
}

fn should_update_activity(event_type: &EventType) -> bool {
    matches!(
        event_type,
        EventType::UserPromptSubmit
            | EventType::PreToolUse
            | EventType::PostToolUse
            | EventType::PostToolUseFailure
            | EventType::PreCompact
    )
}

fn adjust_tools_in_flight(current: u32, event_type: &EventType) -> u32 {
    match event_type {
        EventType::PreToolUse => current.saturating_add(1),
        EventType::PostToolUse | EventType::PostToolUseFailure => current.saturating_sub(1),
        EventType::SessionStart
        | EventType::PreCompact
        | EventType::Stop
        | EventType::TaskCompleted => 0,
        _ => current,
    }
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
            last_activity_at: None,
            tools_in_flight: 0,
            ready_reason: None,
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
                assert_eq!(record.ready_reason, None);
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
    fn file_path_outside_current_project_keeps_current_project() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("repo");
        let repo_src = repo_root.join("src");
        let claude_root = temp_dir.path().join("claude");

        std::fs::create_dir_all(&repo_src).expect("create repo dirs");
        std::fs::create_dir_all(repo_root.join(".git")).expect("create git dir");
        std::fs::write(repo_src.join("index.ts"), "export {}").expect("file");

        std::fs::create_dir_all(&claude_root).expect("create claude dir");
        std::fs::create_dir_all(claude_root.join(".git")).expect("create claude git dir");
        std::fs::write(claude_root.join("AGENTS.md"), "instructions").expect("claude file");

        let mut current = record_with_state(SessionState::Working, "2026-01-30T23:59:00Z");
        current.cwd = repo_root.to_string_lossy().to_string();
        current.project_path = repo_root.to_string_lossy().to_string();
        current.project_id = repo_root.join(".git").to_string_lossy().to_string();

        let mut event = event_base(EventType::PreToolUse);
        event.cwd = Some(repo_root.to_string_lossy().to_string());
        event.file_path = Some(claude_root.join("AGENTS.md").to_string_lossy().to_string());

        let update = reduce_session(Some(&current), &event);

        match update {
            SessionUpdate::Upsert(record) => {
                let expected = std::fs::canonicalize(&repo_root)
                    .unwrap_or(repo_root.clone())
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
            last_activity_at: None,
            tools_in_flight: 0,
            ready_reason: None,
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
    fn pre_compact_resets_tools_in_flight() {
        let mut event = event_base(EventType::PreCompact);
        event.recorded_at = "2026-01-31T00:00:10Z".to_string();

        let mut current = record_with_state(SessionState::Working, "2026-01-31T00:00:00Z");
        current.tools_in_flight = 2;

        let update = reduce_session(Some(&current), &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Compacting);
                assert_eq!(record.tools_in_flight, 0);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn stop_after_pre_compact_is_skipped() {
        let mut pre_compact = event_base(EventType::PreCompact);
        pre_compact.recorded_at = "2026-01-31T00:00:10Z".to_string();

        let mut current = record_with_state(SessionState::Working, "2026-01-31T00:00:00Z");
        current.tools_in_flight = 1;

        let after_compact = match reduce_session(Some(&current), &pre_compact) {
            SessionUpdate::Upsert(record) => record,
            _ => panic!("expected upsert"),
        };

        let mut stop = event_base(EventType::Stop);
        stop.stop_hook_active = Some(false);
        stop.recorded_at = "2026-01-31T00:00:20Z".to_string();

        let update = reduce_session(Some(&after_compact), &stop);
        assert_eq!(update, SessionUpdate::Skip);
    }

    #[test]
    fn post_tool_use_after_pre_compact_keeps_compacting() {
        let mut pre_compact = event_base(EventType::PreCompact);
        pre_compact.recorded_at = "2026-01-31T00:00:10Z".to_string();

        let mut current = record_with_state(SessionState::Working, "2026-01-31T00:00:00Z");
        current.tools_in_flight = 1;

        let after_compact = match reduce_session(Some(&current), &pre_compact) {
            SessionUpdate::Upsert(record) => record,
            _ => panic!("expected upsert"),
        };
        assert_eq!(after_compact.state, SessionState::Compacting);

        let mut post_tool = event_base(EventType::PostToolUse);
        post_tool.recorded_at = "2026-01-31T00:00:11Z".to_string();

        let update = reduce_session(Some(&after_compact), &post_tool);
        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Compacting);
                assert_eq!(record.tools_in_flight, 0);
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
                assert_eq!(record.ready_reason, Some("idle_prompt".to_string()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn notification_auth_success_sets_ready() {
        let mut event = event_base(EventType::Notification);
        event.notification_type = Some("auth_success".to_string());
        let update = reduce_session(None, &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.ready_reason, Some("auth_success".to_string()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn notification_permission_prompt_sets_waiting() {
        let mut event = event_base(EventType::Notification);
        event.notification_type = Some("permission_prompt".to_string());
        let update = reduce_session(None, &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Waiting);
                assert_eq!(record.ready_reason, None);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn notification_elicitation_dialog_sets_waiting() {
        let mut event = event_base(EventType::Notification);
        event.notification_type = Some("elicitation_dialog".to_string());
        let update = reduce_session(None, &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Waiting);
                assert_eq!(record.ready_reason, None);
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
    fn stop_allows_ready_when_tools_in_flight() {
        let mut event = event_base(EventType::Stop);
        event.stop_hook_active = Some(false);
        event.recorded_at = "2026-01-31T00:00:10Z".to_string();

        let mut current = record_with_state(SessionState::Working, "2026-01-31T00:00:00Z");
        current.tools_in_flight = 1;
        current.last_activity_at = Some("2026-01-31T00:00:05Z".to_string());

        let update = reduce_session(Some(&current), &event);
        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.tools_in_flight, 0);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn post_tool_use_failure_clears_tools_and_allows_stop() {
        let mut pre_tool = event_base(EventType::PreToolUse);
        pre_tool.recorded_at = "2026-01-31T00:00:00Z".to_string();
        let after_pre = match reduce_session(None, &pre_tool) {
            SessionUpdate::Upsert(record) => record,
            _ => panic!("expected upsert"),
        };
        assert_eq!(after_pre.tools_in_flight, 1);

        let mut failure = event_base(EventType::PostToolUseFailure);
        failure.recorded_at = "2026-01-31T00:00:02Z".to_string();
        let after_failure = match reduce_session(Some(&after_pre), &failure) {
            SessionUpdate::Upsert(record) => record,
            _ => panic!("expected upsert"),
        };
        assert_eq!(after_failure.tools_in_flight, 0);

        let mut stop = event_base(EventType::Stop);
        stop.stop_hook_active = Some(false);
        stop.recorded_at = "2026-01-31T00:00:10Z".to_string();
        let update = reduce_session(Some(&after_failure), &stop);
        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn stop_allows_ready_even_with_recent_activity() {
        let mut event = event_base(EventType::Stop);
        event.stop_hook_active = Some(false);
        event.recorded_at = "2026-01-31T00:00:10Z".to_string();

        let mut current = record_with_state(SessionState::Working, "2026-01-31T00:00:00Z");
        current.tools_in_flight = 0;
        current.last_activity_at = Some("2026-01-31T00:00:08Z".to_string());

        let update = reduce_session(Some(&current), &event);
        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.ready_reason, Some("stop_gate".to_string()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn stop_allows_ready_when_activity_timestamp_invalid() {
        let mut event = event_base(EventType::Stop);
        event.stop_hook_active = Some(false);
        event.recorded_at = "2026-01-31T00:00:10Z".to_string();

        let mut current = record_with_state(SessionState::Working, "2026-01-31T00:00:00Z");
        current.last_activity_at = Some("not-a-timestamp".to_string());

        let update = reduce_session(Some(&current), &event);
        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.ready_reason, Some("stop_gate".to_string()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn stop_allows_ready_when_event_timestamp_invalid() {
        let mut event = event_base(EventType::Stop);
        event.stop_hook_active = Some(false);
        event.recorded_at = "invalid".to_string();

        let mut current = record_with_state(SessionState::Working, "2026-01-31T00:00:00Z");
        current.last_activity_at = Some("2026-01-31T00:00:05Z".to_string());

        let update = reduce_session(Some(&current), &event);
        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.ready_reason, Some("stop_gate".to_string()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn task_completed_sets_ready() {
        let event = event_base(EventType::TaskCompleted);

        let update = reduce_session(None, &event);
        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.ready_reason, Some("task_completed".to_string()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn task_completed_resets_tools_in_flight() {
        let mut pre_tool = event_base(EventType::PreToolUse);
        pre_tool.recorded_at = "2026-01-31T00:00:00Z".to_string();
        let after_pre = match reduce_session(None, &pre_tool) {
            SessionUpdate::Upsert(record) => record,
            _ => panic!("expected upsert"),
        };
        assert_eq!(after_pre.tools_in_flight, 1);

        let mut task = event_base(EventType::TaskCompleted);
        task.recorded_at = "2026-01-31T00:00:05Z".to_string();
        let update = reduce_session(Some(&after_pre), &task);
        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.tools_in_flight, 0);
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn task_completed_with_agent_id_metadata_skips() {
        let mut event = event_base(EventType::TaskCompleted);
        event.metadata = Some(serde_json::json!({ "agent_id": "agent-1" }));
        let update = reduce_session(None, &event);
        assert_eq!(update, SessionUpdate::Skip);
    }

    #[test]
    fn task_completed_with_teammate_name_metadata_skips() {
        let mut event = event_base(EventType::TaskCompleted);
        event.metadata = Some(serde_json::json!({
            "teammate_name": "implementer",
            "team_name": "my-project"
        }));
        let update = reduce_session(None, &event);
        assert_eq!(update, SessionUpdate::Skip);
    }

    #[test]
    fn task_completed_with_team_name_only_sets_ready() {
        let mut event = event_base(EventType::TaskCompleted);
        event.metadata = Some(serde_json::json!({ "team_name": "my-project" }));

        let update = reduce_session(None, &event);
        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.ready_reason, Some("task_completed".to_string()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn stop_with_agent_id_metadata_skips() {
        let mut event = event_base(EventType::Stop);
        event.stop_hook_active = Some(false);
        event.metadata = Some(serde_json::json!({ "agent_id": "agent-1" }));
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
                assert_eq!(record.ready_reason, Some("stop_gate".to_string()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn stop_without_agent_id_metadata_sets_ready() {
        let mut event = event_base(EventType::Stop);
        event.stop_hook_active = Some(false);
        event.metadata = Some(serde_json::json!({ "note": "no-agent" }));
        let update = reduce_session(None, &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.ready_reason, Some("stop_gate".to_string()));
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
            last_activity_at: None,
            tools_in_flight: 0,
            ready_reason: None,
        };

        let update = reduce_session(Some(&current), &event);
        assert_eq!(update, SessionUpdate::Skip);
    }

    #[test]
    fn pre_tool_use_increments_tools_in_flight() {
        let event = event_base(EventType::PreToolUse);
        let mut current = record_with_state(SessionState::Working, "2026-01-30T23:55:00Z");
        current.tools_in_flight = 1;

        let update = reduce_session(Some(&current), &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.tools_in_flight, 2);
                assert_eq!(record.last_activity_at, Some(event.recorded_at.clone()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn post_tool_use_decrements_tools_in_flight() {
        let event = event_base(EventType::PostToolUse);
        let mut current = record_with_state(SessionState::Working, "2026-01-30T23:55:00Z");
        current.tools_in_flight = 1;

        let update = reduce_session(Some(&current), &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.tools_in_flight, 0);
                assert_eq!(record.last_activity_at, Some(event.recorded_at.clone()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn user_prompt_updates_last_activity() {
        let event = event_base(EventType::UserPromptSubmit);
        let current = record_with_state(SessionState::Ready, "2026-01-30T23:55:00Z");

        let update = reduce_session(Some(&current), &event);

        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.last_activity_at, Some(event.recorded_at.clone()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn stop_allows_ready_when_activity_timestamp_is_in_future() {
        let mut event = event_base(EventType::Stop);
        event.stop_hook_active = Some(false);
        event.recorded_at = "2026-01-31T00:00:05Z".to_string();

        let mut current = record_with_state(SessionState::Working, "2026-01-31T00:00:00Z");
        current.tools_in_flight = 0;
        current.last_activity_at = Some("2026-01-31T00:00:08Z".to_string());

        let update = reduce_session(Some(&current), &event);
        match update {
            SessionUpdate::Upsert(record) => {
                assert_eq!(record.state, SessionState::Ready);
                assert_eq!(record.ready_reason, Some("stop_gate".to_string()));
            }
            _ => panic!("expected upsert"),
        }
    }

    #[test]
    fn stale_stop_is_skipped() {
        let mut event = event_base(EventType::Stop);
        event.stop_hook_active = Some(false);
        event.recorded_at = "2026-01-31T00:00:00Z".to_string();
        let current = SessionRecord {
            session_id: "session-1".to_string(),
            pid: 1234,
            state: SessionState::Working,
            cwd: "/repo".to_string(),
            project_id: "/repo/.git".to_string(),
            project_path: "/repo".to_string(),
            updated_at: "2026-01-31T00:00:10Z".to_string(),
            state_changed_at: "2026-01-31T00:00:10Z".to_string(),
            last_event: Some("user_prompt_submit".to_string()),
            last_activity_at: Some("2026-01-31T00:00:10Z".to_string()),
            tools_in_flight: 0,
            ready_reason: None,
        };

        let update = reduce_session(Some(&current), &event);
        assert_eq!(update, SessionUpdate::Skip);
    }
}
