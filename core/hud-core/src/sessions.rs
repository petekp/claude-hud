//! Session state management for Claude Code sessions.
//!
//! Handles reading session states from the daemon and
//! detecting the current state of Claude Code sessions.
//!
//! The daemon is the single writer; no file-based fallback.

use crate::state::daemon::{sessions_snapshot, DaemonSessionRecord, DaemonSessionsSnapshot};
use crate::storage::StorageConfig;
use crate::types::{ProjectSessionState, SessionState};
use fs_err as fs;
use std::path::Path;

/// Detects session state from daemon snapshots.
pub fn detect_session_state(project_path: &str) -> ProjectSessionState {
    detect_session_state_with_storage(&StorageConfig::default(), project_path)
}

pub fn detect_session_state_with_storage(
    _storage: &StorageConfig,
    project_path: &str,
) -> ProjectSessionState {
    let daemon_sessions = sessions_snapshot();
    detect_session_state_with_snapshots(_storage, project_path, daemon_sessions.as_ref())
}

fn detect_session_state_with_snapshots(
    _storage: &StorageConfig,
    project_path: &str,
    daemon_sessions: Option<&DaemonSessionsSnapshot>,
) -> ProjectSessionState {
    if let Some(snapshot) = daemon_sessions {
        if let Some(record) = snapshot.latest_for_project(project_path) {
            return project_state_from_daemon(record);
        }
    }

    ProjectSessionState {
        state: SessionState::Idle,
        state_changed_at: None,
        updated_at: None,
        session_id: None,
        working_on: None,
        context: None,
        thinking: None,
        has_session: false,
    }
}

/// Gets all session states using daemon session snapshots.
pub fn get_all_session_states(
    project_paths: &[String],
) -> std::collections::HashMap<String, ProjectSessionState> {
    get_all_session_states_with_storage(&StorageConfig::default(), project_paths)
}

pub fn get_all_session_states_with_storage(
    storage: &StorageConfig,
    project_paths: &[String],
) -> std::collections::HashMap<String, ProjectSessionState> {
    let mut states = std::collections::HashMap::new();
    let daemon_sessions = sessions_snapshot();

    for path in project_paths {
        states.insert(
            path.clone(),
            detect_session_state_with_snapshots(
                storage,
                path,
                daemon_sessions.as_ref(),
            ),
        );
    }

    states
}

fn project_state_from_daemon(record: &DaemonSessionRecord) -> ProjectSessionState {
    let state = map_daemon_state(&record.state);
    let is_alive = record.is_alive.unwrap_or(true);
    let has_session = is_alive && state != SessionState::Idle;
    let is_working = state == SessionState::Working;

    ProjectSessionState {
        state,
        state_changed_at: Some(record.state_changed_at.clone()),
        updated_at: Some(record.updated_at.clone()),
        session_id: Some(record.session_id.clone()),
        working_on: None,
        context: None,
        thinking: Some(is_working),
        has_session,
    }
}

fn map_daemon_state(value: &str) -> SessionState {
    match value.to_ascii_lowercase().as_str() {
        "working" => SessionState::Working,
        "ready" => SessionState::Ready,
        "compacting" => SessionState::Compacting,
        "waiting" => SessionState::Waiting,
        "idle" => SessionState::Idle,
        _ => SessionState::Idle,
    }
}

/// Project status as stored in .claude/hud-status.json within each project.
#[derive(Debug, serde::Serialize, serde::Deserialize, Clone, Default, uniffi::Record)]
pub struct ProjectStatus {
    pub working_on: Option<String>,
    pub next_step: Option<String>,
    pub status: Option<String>,
    pub blocker: Option<String>,
    pub updated_at: Option<String>,
}

/// Reads project status from a project's .claude/hud-status.json file.
pub fn read_project_status(project_path: &str) -> Option<ProjectStatus> {
    let status_path = Path::new(project_path)
        .join(".claude")
        .join("hud-status.json");

    if status_path.exists() {
        fs::read_to_string(&status_path)
            .ok()
            .and_then(|content| serde_json::from_str(&content).ok())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fs_err as fs;
    use tempfile::TempDir;

    fn setup_storage() -> (TempDir, StorageConfig) {
        let temp = TempDir::new().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        fs::create_dir_all(&capacitor_root).unwrap();
        fs::create_dir_all(&claude_root).unwrap();
        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        (temp, storage)
    }

    #[test]
    fn test_md5_hash_consistency() {
        let path = "/Users/test/project";
        let hash1 = format!("{:x}", md5::compute(path));
        let hash2 = format!("{:x}", md5::compute(path));
        assert_eq!(hash1, hash2, "MD5 hash should be consistent for same input");
    }

    #[test]
    fn test_md5_hash_uniqueness() {
        let hash1 = format!("{:x}", md5::compute("/path/one"));
        let hash2 = format!("{:x}", md5::compute("/path/two"));
        assert_ne!(hash1, hash2, "Different paths should have different hashes");
    }

    #[test]
    fn test_detect_session_state_returns_idle_for_unknown() {
        let (_temp, storage) = setup_storage();
        let state = detect_session_state_with_storage(
            &storage,
            "/definitely/not/a/real/project/path/xyz123",
        );
        assert_eq!(state.state, SessionState::Idle);
        assert!(state.session_id.is_none());
        assert!(state.working_on.is_none());
    }

    #[test]
    fn test_get_all_session_states_empty_input() {
        let (_temp, storage) = setup_storage();
        let paths: Vec<String> = vec![];
        let states = get_all_session_states_with_storage(&storage, &paths);
        assert!(states.is_empty());
    }

    #[test]
    fn test_get_all_session_states_multiple_paths() {
        let (_temp, storage) = setup_storage();
        let paths = vec![
            "/fake/path/one".to_string(),
            "/fake/path/two".to_string(),
            "/fake/path/three".to_string(),
        ];
        let states = get_all_session_states_with_storage(&storage, &paths);

        assert_eq!(states.len(), 3);
        assert!(states.contains_key("/fake/path/one"));
        assert!(states.contains_key("/fake/path/two"));
        assert!(states.contains_key("/fake/path/three"));
    }

    #[test]
    fn test_project_status_default() {
        let status = ProjectStatus::default();
        assert!(status.working_on.is_none());
        assert!(status.next_step.is_none());
        assert!(status.status.is_none());
        assert!(status.blocker.is_none());
        assert!(status.updated_at.is_none());
    }

    #[test]
    fn test_project_status_serialization() {
        let status = ProjectStatus {
            working_on: Some("Building feature X".to_string()),
            next_step: Some("Write tests".to_string()),
            status: Some("in_progress".to_string()),
            blocker: None,
            updated_at: Some("2024-01-01T00:00:00Z".to_string()),
        };

        let json = serde_json::to_string(&status).unwrap();
        let deserialized: ProjectStatus = serde_json::from_str(&json).unwrap();

        assert_eq!(
            deserialized.working_on,
            Some("Building feature X".to_string())
        );
        assert_eq!(deserialized.next_step, Some("Write tests".to_string()));
        assert!(deserialized.blocker.is_none());
    }

    #[test]
    fn test_read_project_status_missing_file() {
        let result = read_project_status("/definitely/not/a/real/path/xyz");
        assert!(result.is_none());
    }
}
