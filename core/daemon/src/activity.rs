use capacitor_daemon_protocol::{EventEnvelope, EventType};
use serde::Serialize;
use std::path::{Path, PathBuf};

use crate::project_identity::resolve_project_identity;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ActivityEntry {
    pub session_id: String,
    pub project_path: String,
    pub file_path: String,
    pub tool_name: Option<String>,
    pub recorded_at: String,
}

pub fn reduce_activity(event: &EventEnvelope) -> Option<ActivityEntry> {
    if event.event_type != EventType::PostToolUse {
        return None;
    }

    let session_id = event.session_id.as_ref()?.clone();
    let cwd = event.cwd.as_ref()?;
    let file_path = event.file_path.as_ref()?;

    let resolved_path = resolve_file_path(cwd, file_path)?;
    let project_path = resolve_project_identity(&resolved_path)
        .map(|identity| identity.project_path)
        .unwrap_or_else(|| cwd.to_string());

    Some(ActivityEntry {
        session_id,
        project_path,
        file_path: resolved_path,
        tool_name: event.tool.clone(),
        recorded_at: event.recorded_at.clone(),
    })
}

fn resolve_file_path(cwd: &str, file_path: &str) -> Option<String> {
    let path = Path::new(file_path);
    if path.is_absolute() {
        return Some(file_path.to_string());
    }

    let combined = PathBuf::from(cwd).join(file_path);
    combined.to_str().map(|value| value.to_string())
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
            cwd: Some("/tmp".to_string()),
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
    fn post_tool_use_with_file_path_creates_entry() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("repo");
        let src_dir = repo_root.join("src");
        std::fs::create_dir_all(&src_dir).expect("src dir");
        std::fs::write(repo_root.join("package.json"), "{}").expect("marker");
        std::fs::write(src_dir.join("main.rs"), "fn main() {}").expect("file");

        let mut event = event_base(EventType::PostToolUse);
        event.cwd = Some(repo_root.to_string_lossy().to_string());
        event.file_path = Some("src/main.rs".to_string());
        event.tool = Some("Edit".to_string());

        let entry = reduce_activity(&event).expect("entry");
        let expected_path = repo_root.join("src/main.rs").to_string_lossy().to_string();
        let expected_project = std::fs::canonicalize(&repo_root)
            .unwrap_or(repo_root.clone())
            .to_string_lossy()
            .to_string();
        let canonical_entry = std::fs::canonicalize(&entry.project_path)
            .unwrap_or_else(|_| std::path::PathBuf::from(&entry.project_path))
            .to_string_lossy()
            .to_string();

        assert_eq!(entry.file_path, expected_path);
        assert_eq!(canonical_entry, expected_project);
        assert_eq!(entry.tool_name, Some("Edit".to_string()));
    }

    #[test]
    fn post_tool_use_without_file_path_skips() {
        let event = event_base(EventType::PostToolUse);
        assert!(reduce_activity(&event).is_none());
    }

    #[test]
    fn non_post_tool_use_skips() {
        let event = event_base(EventType::PreToolUse);
        assert!(reduce_activity(&event).is_none());
    }
}
