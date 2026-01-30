//! In-memory state managed by the daemon.
//!
//! Phase 2 stores only shell CWD data so the Swift app can read it directly
//! from the daemon. Session/state data will be added in later phases.

use capacitor_daemon_protocol::{EventEnvelope, EventType};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Default)]
pub struct SharedState {
    shell_state: Mutex<ShellState>,
}

impl SharedState {
    pub fn update_from_event(&self, event: &EventEnvelope) {
        if event.event_type == EventType::ShellCwd {
            self.update_shell_state(event);
        }
    }

    pub fn shell_state_snapshot(&self) -> ShellState {
        self.shell_state
            .lock()
            .map(|state| state.clone())
            .unwrap_or_default()
    }

    fn update_shell_state(&self, event: &EventEnvelope) {
        let (pid, cwd, tty) = match (event.pid, &event.cwd, &event.tty) {
            (Some(pid), Some(cwd), Some(tty)) => (pid, cwd, tty),
            _ => return,
        };

        let entry = ShellEntry {
            cwd: cwd.clone(),
            tty: tty.clone(),
            parent_app: event.parent_app.clone(),
            tmux_session: event.tmux_session.clone(),
            tmux_client_tty: event.tmux_client_tty.clone(),
            updated_at: event.recorded_at.clone(),
        };

        if let Ok(mut state) = self.shell_state.lock() {
            state.shells.insert(pid.to_string(), entry);
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ShellState {
    pub version: u32,
    pub shells: HashMap<String, ShellEntry>,
}

impl Default for ShellState {
    fn default() -> Self {
        Self {
            version: 1,
            shells: HashMap::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ShellEntry {
    pub cwd: String,
    pub tty: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_app: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_client_tty: Option<String>,
    pub updated_at: String,
}
