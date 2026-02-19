//! Claude Code adapter backed by daemon session snapshots.

use super::types::{AgentSession, AgentState, AgentType};
use super::AgentAdapter;
use crate::state::daemon::{sessions_snapshot, DaemonSessionRecord};
use crate::storage::StorageConfig;
use crate::types::SessionState;

/// Adapter for Claude Code CLI sessions.
///
/// The daemon is the sole source of session data.
pub struct ClaudeAdapter {
    storage: StorageConfig,
}

impl ClaudeAdapter {
    pub fn new() -> Self {
        Self {
            storage: StorageConfig::default(),
        }
    }

    /// Creates an adapter with custom storage configuration.
    /// Used for testing with isolated directories.
    pub fn with_storage(storage: StorageConfig) -> Self {
        Self { storage }
    }

    fn map_state(state: SessionState) -> AgentState {
        match state {
            SessionState::Ready => AgentState::Ready,
            SessionState::Working => AgentState::Working,
            SessionState::Compacting => AgentState::Working,
            SessionState::Waiting => AgentState::Waiting,
            SessionState::Idle => AgentState::Idle,
        }
    }

    fn state_detail(state: SessionState) -> Option<String> {
        match state {
            SessionState::Compacting => Some("compacting context".to_string()),
            SessionState::Waiting => Some("waiting for input or permission".to_string()),
            _ => None,
        }
    }
}

impl Default for ClaudeAdapter {
    fn default() -> Self {
        Self::new()
    }
}

impl AgentAdapter for ClaudeAdapter {
    fn id(&self) -> &'static str {
        "claude"
    }

    fn display_name(&self) -> &'static str {
        "Claude Code"
    }

    fn is_installed(&self) -> bool {
        // Check if Claude directory exists (coarse "installed" signal).
        self.storage.claude_root().is_dir()
    }

    fn detect_session(&self, project_path: &str) -> Option<AgentSession> {
        let snapshot = sessions_snapshot()?;
        let record = snapshot.latest_for_project(project_path)?;
        daemon_session_to_agent(record)
    }

    fn all_sessions(&self) -> Vec<AgentSession> {
        let snapshot = match sessions_snapshot() {
            Some(snapshot) => snapshot,
            None => return vec![],
        };

        snapshot
            .sessions()
            .iter()
            .filter_map(daemon_session_to_agent)
            .collect()
    }

    fn state_mtime(&self) -> Option<std::time::SystemTime> {
        None
    }
}

fn daemon_session_to_agent(record: &DaemonSessionRecord) -> Option<AgentSession> {
    if record.is_alive == Some(false) {
        return None;
    }

    let state = match record.state.as_str() {
        "working" => SessionState::Working,
        "ready" => SessionState::Ready,
        "compacting" => SessionState::Compacting,
        "waiting" => SessionState::Waiting,
        "idle" => SessionState::Idle,
        _ => SessionState::Idle,
    };

    if state == SessionState::Idle {
        return None;
    }

    Some(AgentSession {
        agent_type: AgentType::Claude,
        agent_name: "Claude Code".to_string(),
        state: ClaudeAdapter::map_state(state),
        session_id: Some(record.session_id.clone()),
        cwd: record.cwd.clone(),
        detail: ClaudeAdapter::state_detail(state),
        working_on: None,
        updated_at: Some(record.updated_at.clone()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_state_mapping_compacting_detail() {
        assert_eq!(
            ClaudeAdapter::state_detail(SessionState::Compacting),
            Some("compacting context".to_string())
        );
    }

    #[test]
    fn test_state_mapping_waiting_detail() {
        assert_eq!(
            ClaudeAdapter::state_detail(SessionState::Waiting),
            Some("waiting for input or permission".to_string())
        );
    }
}
