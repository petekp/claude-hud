//! In-memory state managed by the daemon.
//!
//! Phase 3 persists an append-only event log plus a materialized shell CWD
//! table, keeping shell state fast to query while other state remains event-only.

use capacitor_daemon_protocol::{EventEnvelope, EventType};
use chrono::{DateTime, Duration, Utc};
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
// Session TTL policies (seconds).
// These intentionally err on the side of clearing stale states.
const SESSION_TTL_ACTIVE_SECS: i64 = 20 * 60; // Working/Waiting/Compacting
const SESSION_TTL_READY_SECS: i64 = 30 * 60; // Ready
const SESSION_TTL_IDLE_SECS: i64 = 10 * 60; // Idle
const ACTIVE_STATE_STALE_SECS: i64 = 8; // Working/Waiting -> Ready when no updates
                                        // Ready does not auto-idle; it remains until TTL or session end.

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
                    tracing::info!(
                        session_id = %record.session_id,
                        state = ?record.state,
                        project_path = %record.project_path,
                        pid = record.pid,
                        "Session upsert"
                    );
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
                    tracing::info!(session_id = %session_id, "Session delete");
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
        let now = Utc::now();
        let mut enriched = Vec::new();

        for record in sessions {
            if self.is_session_expired(&record, now) {
                self.prune_session(&record.session_id)?;
                continue;
            }

            let is_alive = self.session_is_alive(record.pid);
            if is_alive == Some(false) {
                tracing::info!(
                    session_id = %record.session_id,
                    pid = record.pid,
                    "Session pruned (process not alive)"
                );
                self.prune_session(&record.session_id)?;
                continue;
            }

            enriched.push(EnrichedSession {
                session_id: record.session_id,
                pid: record.pid,
                state: record.state,
                cwd: record.cwd,
                project_path: record.project_path,
                updated_at: record.updated_at,
                state_changed_at: record.state_changed_at,
                last_event: record.last_event,
                is_alive,
            });
        }

        Ok(enriched)
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

    pub fn project_states_snapshot(&self) -> Result<Vec<ProjectState>, String> {
        let sessions = self.db.list_sessions()?;
        let now = Utc::now();
        let mut aggregates: HashMap<String, ProjectAggregate> = HashMap::new();

        for record in sessions {
            if record.project_path.trim().is_empty() {
                continue;
            }

            if self.is_session_expired(&record, now) {
                self.prune_session(&record.session_id)?;
                continue;
            }

            let is_alive = self.session_is_alive(record.pid);
            if is_alive == Some(false) {
                self.prune_session(&record.session_id)?;
                continue;
            }

            let effective_state = effective_session_state(&record, now);
            let session_time = session_timestamp(&record).unwrap_or(now);
            let priority = session_state_priority(&effective_state);
            let is_active = session_state_is_active(&effective_state);

            let entry = aggregates
                .entry(record.project_path.clone())
                .or_insert_with(|| {
                    ProjectAggregate::from_record(
                        &record,
                        effective_state.clone(),
                        session_time,
                        priority,
                        is_active,
                    )
                });

            entry.session_count += 1;
            if is_active {
                entry.active_count += 1;
            }

            if session_time > entry.latest_time {
                entry.latest_time = session_time;
                entry.updated_at = record.updated_at.clone();
                entry.session_id = Some(record.session_id.clone());
            }

            if priority > entry.state_priority
                || (priority == entry.state_priority && session_time > entry.state_time)
            {
                entry.state_priority = priority;
                entry.state_time = session_time;
                entry.state = effective_state;
                entry.state_changed_at = record.state_changed_at.clone();
            }
        }

        let mut results = Vec::new();
        for (project_path, aggregate) in aggregates {
            let is_locked = aggregate.state != crate::reducer::SessionState::Idle;
            results.push(ProjectState {
                project_path,
                state: aggregate.state.clone(),
                state_changed_at: aggregate.state_changed_at,
                updated_at: aggregate.updated_at,
                session_id: aggregate.session_id,
                session_count: aggregate.session_count,
                active_count: aggregate.active_count,
                is_locked,
            });
        }

        if !results.is_empty() {
            let summary = results
                .iter()
                .map(|state| {
                    format!(
                        "{} state={} sessions={} active={} updated_at={}",
                        state.project_path,
                        state.state.as_str(),
                        state.session_count,
                        state.active_count,
                        state.updated_at
                    )
                })
                .collect::<Vec<_>>()
                .join(" | ");
            tracing::debug!(summary = %summary, "Project state snapshot summary");
        } else {
            tracing::debug!("Project state snapshot empty");
        }

        Ok(results)
    }

    fn is_session_expired(&self, record: &SessionRecord, now: DateTime<Utc>) -> bool {
        let last_seen = session_timestamp(record);
        let Some(last_seen) = last_seen else {
            tracing::warn!(
                session_id = %record.session_id,
                "Session timestamp missing; skipping TTL expiry"
            );
            return false;
        };

        let ttl_secs = session_ttl_seconds(&record.state);
        let expires_at = last_seen + Duration::seconds(ttl_secs);
        if now > expires_at {
            tracing::info!(
                session_id = %record.session_id,
                state = ?record.state,
                ttl_secs,
                "Session expired by TTL"
            );
            return true;
        }
        false
    }

    fn prune_session(&self, session_id: &str) -> Result<(), String> {
        tracing::info!(session_id = %session_id, "Pruning session");
        self.db.delete_session(session_id)?;
        self.db.delete_activity_for_session(session_id)?;
        Ok(())
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
            tracing::debug!(
                pid,
                cwd = %cwd,
                tty = %tty,
                parent_app = ?event.parent_app,
                "Shell state cache updated"
            );
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ProjectState {
    pub project_path: String,
    pub state: crate::reducer::SessionState,
    pub state_changed_at: String,
    pub updated_at: String,
    pub session_id: Option<String>,
    pub session_count: usize,
    pub active_count: usize,
    pub is_locked: bool,
}

#[derive(Debug, Clone)]
struct ProjectAggregate {
    state: crate::reducer::SessionState,
    state_changed_at: String,
    updated_at: String,
    session_id: Option<String>,
    session_count: usize,
    active_count: usize,
    state_priority: u8,
    state_time: DateTime<Utc>,
    latest_time: DateTime<Utc>,
}

impl ProjectAggregate {
    fn from_record(
        record: &SessionRecord,
        state: crate::reducer::SessionState,
        session_time: DateTime<Utc>,
        priority: u8,
        _is_active: bool,
    ) -> Self {
        Self {
            state,
            state_changed_at: record.state_changed_at.clone(),
            updated_at: record.updated_at.clone(),
            session_id: Some(record.session_id.clone()),
            session_count: 0,
            active_count: 0,
            state_priority: priority,
            state_time: session_time,
            latest_time: session_time,
        }
    }
}

fn session_state_priority(state: &crate::reducer::SessionState) -> u8 {
    match state {
        crate::reducer::SessionState::Working => 4,
        crate::reducer::SessionState::Waiting => 3,
        crate::reducer::SessionState::Compacting => 2,
        crate::reducer::SessionState::Ready => 1,
        crate::reducer::SessionState::Idle => 0,
    }
}

fn session_state_is_active(state: &crate::reducer::SessionState) -> bool {
    matches!(
        state,
        crate::reducer::SessionState::Working
            | crate::reducer::SessionState::Waiting
            | crate::reducer::SessionState::Compacting
    )
}

fn effective_session_state(
    record: &SessionRecord,
    now: DateTime<Utc>,
) -> crate::reducer::SessionState {
    let mut state = record.state.clone();

    if matches!(
        state,
        crate::reducer::SessionState::Working | crate::reducer::SessionState::Waiting
    ) {
        if let Some(last_seen) = parse_rfc3339(&record.updated_at) {
            let age = now.signed_duration_since(last_seen).num_seconds();
            if age > ACTIVE_STATE_STALE_SECS {
                state = crate::reducer::SessionState::Ready;
            }
        }
    }

    state
}

fn session_ttl_seconds(state: &crate::reducer::SessionState) -> i64 {
    match state {
        crate::reducer::SessionState::Working
        | crate::reducer::SessionState::Waiting
        | crate::reducer::SessionState::Compacting => SESSION_TTL_ACTIVE_SECS,
        crate::reducer::SessionState::Ready => SESSION_TTL_READY_SECS,
        crate::reducer::SessionState::Idle => SESSION_TTL_IDLE_SECS,
    }
}

fn session_timestamp(record: &SessionRecord) -> Option<DateTime<Utc>> {
    parse_rfc3339(&record.updated_at).or_else(|| parse_rfc3339(&record.state_changed_at))
}

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;
    use crate::reducer::SessionState;

    fn make_record(
        session_id: &str,
        project_path: &str,
        state: SessionState,
        updated_at: String,
    ) -> SessionRecord {
        SessionRecord {
            session_id: session_id.to_string(),
            pid: 0,
            state,
            cwd: project_path.to_string(),
            project_path: project_path.to_string(),
            updated_at: updated_at.clone(),
            state_changed_at: updated_at,
            last_event: None,
        }
    }

    #[test]
    fn project_states_downgrade_stale_working_to_ready() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let stale_time = (Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS + 5)).to_rfc3339();
        let record = make_record("session-stale", "/repo", SessionState::Working, stale_time);
        state.db.upsert_session(&record).expect("insert session");

        let aggregates = state.project_states_snapshot().expect("project states");
        assert_eq!(aggregates.len(), 1);
        assert_eq!(aggregates[0].state, SessionState::Ready);
    }

    #[test]
    fn ready_state_does_not_auto_idle_after_short_inactivity() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let stale_time = (Utc::now() - Duration::seconds(120)).to_rfc3339();
        let record = make_record("session-ready", "/repo", SessionState::Ready, stale_time);
        state.db.upsert_session(&record).expect("insert session");

        let aggregates = state.project_states_snapshot().expect("project states");
        assert_eq!(aggregates.len(), 1);
        assert_eq!(aggregates[0].state, SessionState::Ready);
    }

    #[test]
    fn ttl_expires_stale_sessions() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let stale_time = (Utc::now() - Duration::seconds(SESSION_TTL_READY_SECS + 5)).to_rfc3339();
        let record = make_record("session-stale", "/repo", SessionState::Ready, stale_time);
        state.db.upsert_session(&record).expect("insert session");

        let sessions = state.sessions_snapshot().expect("snapshot");
        assert!(sessions.is_empty());
        let remaining = state.db.list_sessions().expect("list sessions");
        assert!(remaining.is_empty());
    }

    #[test]
    fn aggregates_project_state() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let now = Utc::now().to_rfc3339();
        let ready = make_record("session-ready", "/repo", SessionState::Ready, now.clone());
        let working = make_record(
            "session-working",
            "/repo",
            SessionState::Working,
            now.clone(),
        );
        state.db.upsert_session(&ready).expect("insert ready");
        state.db.upsert_session(&working).expect("insert working");

        let aggregates = state.project_states_snapshot().expect("project states");
        assert_eq!(aggregates.len(), 1);
        let aggregate = &aggregates[0];
        assert_eq!(aggregate.project_path, "/repo");
        assert_eq!(aggregate.state, SessionState::Working);
        assert_eq!(aggregate.session_count, 2);
        assert_eq!(aggregate.active_count, 1);
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
