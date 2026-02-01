//! In-memory state managed by the daemon.
//!
//! Phase 3 persists an append-only event log plus a materialized shell CWD
//! table, keeping shell state fast to query while other state remains event-only.

use capacitor_daemon_protocol::{EventEnvelope, EventType};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Mutex;

use crate::activity::{reduce_activity, ActivityEntry};
use crate::db::{Db, TombstoneRow};
use crate::process::get_process_start_time;
use crate::reducer::{SessionRecord, SessionUpdate};
use crate::replay::rebuild_from_events;
use crate::session_store::handle_session_event;

const PROCESS_LIVENESS_MAX_AGE_HOURS: i64 = 24;

pub struct SharedState {
    db: Db,
    shell_state: Mutex<ShellState>,
}

impl SharedState {
    pub fn new(db: Db) -> Self {
        let mut needs_replay = false;
        match db.has_sessions() {
            Ok(false) => match db.has_events() {
                Ok(true) => needs_replay = true,
                Ok(false) => {}
                Err(err) => {
                    tracing::warn!(error = %err, "Failed to check event log for replay");
                }
            },
            Ok(true) => match (db.latest_event_time(), db.latest_session_time()) {
                (Ok(Some(latest_event)), Ok(latest_session)) => {
                    if latest_session.map(|ts| latest_event > ts).unwrap_or(true) {
                        needs_replay = true;
                    }
                }
                (Err(err), _) => {
                    tracing::warn!(error = %err, "Failed to read latest event timestamp");
                }
                (_, Err(err)) => {
                    tracing::warn!(error = %err, "Failed to read latest session timestamp");
                }
                _ => {}
            },
            Err(err) => {
                tracing::warn!(error = %err, "Failed to check session table");
            }
        }

        if needs_replay {
            if let Err(err) = rebuild_from_events(&db) {
                tracing::warn!(error = %err, "Failed to rebuild session state from events");
            }
        }

        let shell_state = match db.load_shell_state() {
            Ok(state) if !state.shells.is_empty() => state,
            Ok(state) => match db.rebuild_shell_state_from_events() {
                Ok(rebuilt) if !rebuilt.shells.is_empty() => rebuilt,
                Ok(_) => state,
                Err(err) => {
                    tracing::warn!(error = %err, "Failed to rebuild shell_state from events");
                    state
                }
            },
            Err(err) => {
                tracing::warn!(error = %err, "Failed to load shell_state table");
                db.rebuild_shell_state_from_events().unwrap_or_default()
            }
        };
        if let Err(err) = db.ensure_process_liveness() {
            tracing::warn!(error = %err, "Failed to ensure process liveness table");
        }
        if let Err(err) = db.prune_process_liveness(PROCESS_LIVENESS_MAX_AGE_HOURS) {
            tracing::warn!(error = %err, "Failed to prune process liveness table");
        }
        Self {
            db,
            shell_state: Mutex::new(shell_state),
        }
    }

    pub fn update_from_event(&self, event: &EventEnvelope) {
        if let Err(err) = self.db.insert_event(event) {
            tracing::warn!(error = %err, "Failed to persist daemon event");
            return;
        }

        if let Err(err) = self.db.upsert_process_liveness(event) {
            tracing::warn!(error = %err, "Failed to update process liveness");
        }

        let current_session = match event.session_id.as_ref() {
            Some(session_id) => self.db.get_session(session_id).ok().flatten(),
            None => None,
        };

        match handle_session_event(&self.db, current_session.as_ref(), event) {
            Ok(update) => match update {
                SessionUpdate::Upsert(record) => {
                    if let Err(err) = self.db.upsert_session(&record) {
                        tracing::warn!(error = %err, "Failed to upsert session");
                    }
                    if let Some(entry) = reduce_activity(event) {
                        if let Err(err) = self.db.insert_activity(&entry) {
                            tracing::warn!(error = %err, "Failed to insert activity");
                        }
                    }
                }
                SessionUpdate::Delete { session_id } => {
                    if let Err(err) = self.db.delete_session(&session_id) {
                        tracing::warn!(error = %err, "Failed to delete session");
                    }
                    if let Err(err) = self.db.delete_activity_for_session(&session_id) {
                        tracing::warn!(error = %err, "Failed to delete activity");
                    }
                }
                SessionUpdate::Skip => {}
            },
            Err(err) => {
                tracing::warn!(error = %err, "Failed to apply session event");
            }
        }

        if event.event_type == EventType::ShellCwd {
            if let Err(err) = self.db.upsert_shell_state(event) {
                tracing::warn!(error = %err, "Failed to update shell_state table");
                return;
            }

            self.update_shell_state_cache(event);
        }
    }

    pub fn shell_state_snapshot(&self) -> ShellState {
        self.shell_state
            .lock()
            .map(|state| state.clone())
            .unwrap_or_default()
    }

    pub fn process_liveness_snapshot(&self, pid: u32) -> Result<Option<ProcessLiveness>, String> {
        let row = self.db.get_process_liveness(pid)?;
        Ok(row.map(|row| {
            let current_start = get_process_start_time(pid);
            let stored_start = row.proc_started.map(|value| value as u64);
            let identity_matches = match (stored_start, current_start) {
                (Some(stored), Some(current)) => Some(stored.abs_diff(current) <= 2),
                _ => None,
            };

            ProcessLiveness {
                pid: row.pid,
                proc_started: stored_start,
                last_seen_at: row.last_seen_at,
                current_start_time: current_start,
                is_alive: current_start.is_some(),
                identity_matches,
            }
        }))
    }

    pub fn sessions_snapshot(&self) -> Result<Vec<EnrichedSession>, String> {
        let sessions = self.db.list_sessions()?;
        Ok(sessions
            .into_iter()
            .map(|record| self.enrich_session(record))
            .collect())
    }

    fn enrich_session(&self, record: SessionRecord) -> EnrichedSession {
        let is_alive = self.session_is_alive(record.pid);

        EnrichedSession {
            session_id: record.session_id,
            pid: record.pid,
            state: record.state,
            cwd: record.cwd,
            project_path: record.project_path,
            updated_at: record.updated_at,
            state_changed_at: record.state_changed_at,
            last_event: record.last_event,
            is_alive,
        }
    }

    fn session_is_alive(&self, pid: u32) -> Option<bool> {
        if pid == 0 {
            return None;
        }

        let stored_start = self
            .db
            .get_process_liveness(pid)
            .ok()
            .flatten()
            .and_then(|row| row.proc_started.map(|value| value as u64));
        let current_start = get_process_start_time(pid);

        match (current_start, stored_start) {
            (Some(current), Some(stored)) => Some(stored.abs_diff(current) <= 2),
            (Some(_), None) => Some(true),
            (None, _) => Some(false),
        }
    }

    pub fn activity_snapshot(
        &self,
        session_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ActivityEntry>, String> {
        match session_id {
            Some(id) => self.db.list_activity(id, limit),
            None => self.db.list_activity_all(limit),
        }
    }

    pub fn tombstones_snapshot(&self) -> Result<Vec<TombstoneRow>, String> {
        self.db.list_tombstones()
    }

    fn update_shell_state_cache(&self, event: &EventEnvelope) {
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
pub struct ProcessLivenessRow {
    pub pid: u32,
    pub proc_started: Option<i64>,
    pub last_seen_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProcessLiveness {
    pub pid: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proc_started: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_start_time: Option<u64>,
    pub last_seen_at: String,
    pub is_alive: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub identity_matches: Option<bool>,
}

/// Session record enriched with liveness info for IPC responses.
#[derive(Debug, Clone, Serialize)]
pub struct EnrichedSession {
    pub session_id: String,
    pub pid: u32,
    pub state: crate::reducer::SessionState,
    pub cwd: String,
    pub project_path: String,
    pub updated_at: String,
    pub state_changed_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
    /// Whether the session's process is still alive.
    /// None if pid is 0 (unknown), Some(true) if alive, Some(false) if dead.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_alive: Option<bool>,
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
