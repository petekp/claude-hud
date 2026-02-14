use chrono::{DateTime, Utc};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellSignal {
    pub pid: u32,
    pub proc_start: Option<u64>,
    pub cwd: String,
    pub tty: String,
    pub parent_app: Option<String>,
    pub tmux_session: Option<String>,
    pub tmux_client_tty: Option<String>,
    pub tmux_pane: Option<String>,
    pub recorded_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default)]
pub struct ShellRegistry {
    entries: HashMap<String, ShellSignal>,
}

impl ShellRegistry {
    pub fn upsert(&mut self, signal: ShellSignal) {
        self.entries.insert(shell_signal_key(&signal), signal);
    }

    pub fn all(&self) -> Vec<&ShellSignal> {
        self.entries.values().collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxClientSignal {
    pub client_tty: String,
    pub session_name: String,
    pub pane_current_path: Option<String>,
    pub captured_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxSessionSignal {
    pub session_name: String,
    pub pane_paths: Vec<String>,
    pub captured_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default)]
pub struct TmuxRegistry {
    pub clients: Vec<TmuxClientSignal>,
    pub sessions: Vec<TmuxSessionSignal>,
}

impl TmuxRegistry {
    pub fn upsert_client(&mut self, signal: TmuxClientSignal) {
        if let Some(existing) = self
            .clients
            .iter_mut()
            .find(|existing| existing.client_tty == signal.client_tty)
        {
            *existing = signal;
        } else {
            self.clients.push(signal);
            self.clients
                .sort_by(|left, right| left.client_tty.cmp(&right.client_tty));
        }
    }

    pub fn upsert_session(&mut self, signal: TmuxSessionSignal) {
        if let Some(existing) = self
            .sessions
            .iter_mut()
            .find(|existing| existing.session_name == signal.session_name)
        {
            *existing = signal;
        } else {
            self.sessions.push(signal);
            self.sessions
                .sort_by(|left, right| left.session_name.cmp(&right.session_name));
        }
    }

    pub fn replace_snapshot(
        &mut self,
        mut clients: Vec<TmuxClientSignal>,
        mut sessions: Vec<TmuxSessionSignal>,
    ) {
        clients.sort_by(|left, right| left.client_tty.cmp(&right.client_tty));
        sessions.sort_by(|left, right| left.session_name.cmp(&right.session_name));
        self.clients = clients;
        self.sessions = sessions;
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessSignal {
    pub pid: u32,
    pub proc_start: Option<u64>,
    pub is_alive: bool,
    pub checked_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default)]
pub struct ProcessRegistry {
    entries: HashMap<String, ProcessSignal>,
}

impl ProcessRegistry {
    pub fn upsert(&mut self, signal: ProcessSignal) {
        self.entries.insert(process_signal_key(&signal), signal);
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorkspaceBinding {
    pub preferred_sessions: Vec<String>,
    pub path_patterns: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct WorkspaceBindings {
    bindings: HashMap<String, WorkspaceBinding>,
}

impl WorkspaceBindings {
    pub fn upsert(&mut self, workspace_id: impl Into<String>, binding: WorkspaceBinding) {
        self.bindings.insert(workspace_id.into(), binding);
    }

    pub fn get(&self, workspace_id: &str) -> Option<&WorkspaceBinding> {
        self.bindings.get(workspace_id)
    }
}

fn shell_signal_key(signal: &ShellSignal) -> String {
    let proc_start = signal.proc_start.unwrap_or(0);
    format!("{}:{}", signal.pid, proc_start)
}

fn process_signal_key(signal: &ProcessSignal) -> String {
    let proc_start = signal.proc_start.unwrap_or(0);
    format!("{}:{}", signal.pid, proc_start)
}
