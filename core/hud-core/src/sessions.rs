//! Session state management for Claude Code sessions.
//!
//! Handles reading session states from the HUD status file and
//! detecting the current state of Claude Code sessions.

use crate::config::get_claude_dir;
use crate::types::{ContextInfo, ProjectSessionState, SessionState, SessionStatesFile};
use std::fs;
use std::path::Path;

/// Loads the session states file from ~/.claude/hud-session-states.json
pub fn load_session_states_file() -> Option<SessionStatesFile> {
    let claude_dir = get_claude_dir()?;
    let state_file = claude_dir.join("hud-session-states.json");

    if !state_file.exists() {
        return None;
    }

    fs::read_to_string(&state_file)
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
}

/// Detects the session state for a given project path.
pub fn detect_session_state(project_path: &str) -> ProjectSessionState {
    let idle_state = ProjectSessionState {
        state: SessionState::Idle,
        state_changed_at: None,
        session_id: None,
        working_on: None,
        next_step: None,
        context: None,
        thinking: None,
    };

    if let Some(states_file) = load_session_states_file() {
        if let Some(entry) = states_file.projects.get(project_path) {
            let state = match entry.state.as_str() {
                "working" => SessionState::Working,
                "ready" => SessionState::Ready,
                "compacting" => SessionState::Compacting,
                "waiting" => SessionState::Waiting,
                _ => SessionState::Idle,
            };

            let context = entry.context.as_ref().and_then(|ctx| {
                Some(ContextInfo {
                    percent_used: ctx.percent_used?,
                    tokens_used: ctx.tokens_used?,
                    context_size: ctx.context_size?,
                    updated_at: ctx.updated_at.clone(),
                })
            });

            return ProjectSessionState {
                state,
                state_changed_at: entry.state_changed_at.clone(),
                session_id: entry.session_id.clone(),
                working_on: entry.working_on.clone(),
                next_step: entry.next_step.clone(),
                context,
                thinking: entry.thinking,
            };
        }
    }

    idle_state
}

/// Gets all session states for given project paths.
pub fn get_all_session_states(
    project_paths: &[String],
) -> std::collections::HashMap<String, ProjectSessionState> {
    let mut states = std::collections::HashMap::new();

    for path in project_paths {
        states.insert(path.clone(), detect_session_state(path));
    }

    states
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
