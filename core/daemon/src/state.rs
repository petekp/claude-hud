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
use crate::project_identity::workspace_id;
use crate::reducer::{SessionRecord, SessionUpdate};
use crate::replay::catch_up_sessions_from_events;
use crate::session_store::handle_session_event;

const PROCESS_LIVENESS_MAX_AGE_HOURS: i64 = 24;
const SHELL_MAX_AGE_HOURS: i64 = 24;
const SHELL_RECENT_THRESHOLD_SECS: i64 = 5 * 60; // 5 minutes

// Session TTL policies (seconds).
// These intentionally err on the side of clearing stale states.
const SESSION_TTL_ACTIVE_SECS: i64 = 20 * 60; // Working/Waiting/Compacting
const SESSION_TTL_READY_SECS: i64 = 30 * 60; // Ready
const SESSION_TTL_IDLE_SECS: i64 = 10 * 60; // Idle
                                            // Ready does not auto-idle; it remains until TTL or session end.
const SESSION_AUTO_READY_SECS: i64 = 60; // Auto-ready eligible states -> Ready when inactive and no tools are in flight.
const SESSION_CATCH_UP_MAX_AGE_SECS: i64 = SESSION_TTL_READY_SECS + (5 * 60); // Ready TTL plus margin.

pub struct SharedState {
    db: Db,
    shell_state: Mutex<ShellState>,
}

impl SharedState {
    pub fn new(db: Db) -> Self {
        let mut catch_up_since: Option<DateTime<Utc>> = None;
        let mut needs_catch_up = false;
        match db.has_sessions() {
            Ok(false) => match db.has_events() {
                Ok(true) => {
                    needs_catch_up = true;
                    catch_up_since = None;
                }
                Ok(false) => {}
                Err(err) => {
                    tracing::warn!(error = %err, "Failed to check event log for replay");
                }
            },
            Ok(true) => match (
                db.latest_session_affecting_event_time(),
                db.latest_session_time(),
            ) {
                (Ok(Some(latest_event)), Ok(latest_session)) => {
                    if latest_session.map(|ts| latest_event > ts).unwrap_or(true) {
                        needs_catch_up = true;
                        catch_up_since = latest_session;
                    }
                }
                (Err(err), _) => {
                    tracing::warn!(
                        error = %err,
                        "Failed to read latest session-affecting event timestamp"
                    );
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

        if needs_catch_up {
            let catch_up_start = clamp_catch_up_since(catch_up_since, Utc::now());
            if let Err(err) = catch_up_sessions_from_events(&db, Some(catch_up_start)) {
                tracing::warn!(
                    error = %err,
                    "Failed to catch up session state from recent events"
                );
            }
        }

        let mut shell_state = match db.load_shell_state() {
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

        // Prune stale shells (TTL)
        let pruned_ttl = db.prune_stale_shells(SHELL_MAX_AGE_HOURS).unwrap_or(0);
        if pruned_ttl > 0 {
            tracing::info!(count = pruned_ttl, "Pruned stale shells (>24h)");
        }

        // Liveness sweep on remaining shells
        let dead_pids: Vec<String> = shell_state
            .shells
            .keys()
            .filter(|pid_str| {
                pid_str
                    .parse::<u32>()
                    .ok()
                    .is_some_and(|pid| get_process_start_time(pid).is_none())
            })
            .cloned()
            .collect();

        if !dead_pids.is_empty() {
            let count = dead_pids.len();
            for pid in &dead_pids {
                shell_state.shells.remove(pid);
            }
            if let Err(err) = db.delete_shells(&dead_pids) {
                tracing::warn!(error = %err, "Failed to delete dead shells from DB");
            }
            tracing::info!(count, "Pruned dead shells at startup (process not running)");
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
        let now = Utc::now();
        let threshold = now - Duration::seconds(SHELL_RECENT_THRESHOLD_SECS);

        // Clone cache for inspection (release lock quickly)
        let snapshot = self
            .shell_state
            .lock()
            .map(|state| state.clone())
            .unwrap_or_default();

        // Find dead shells among stale entries
        let dead_pids: Vec<String> = snapshot
            .shells
            .iter()
            .filter(|(_, entry)| {
                // Recently updated shells are almost certainly alive — skip them
                DateTime::parse_from_rfc3339(&entry.updated_at)
                    .map(|dt| dt < threshold)
                    .unwrap_or(true) // Unparseable timestamp → check liveness
            })
            .filter(|(pid_str, _)| {
                pid_str
                    .parse::<u32>()
                    .ok()
                    .is_some_and(|pid| self.session_is_alive(pid) == Some(false))
            })
            .map(|(pid_str, _)| pid_str.clone())
            .collect();

        if dead_pids.is_empty() {
            return snapshot;
        }

        // Remove dead shells from cache
        if let Ok(mut cache) = self.shell_state.lock() {
            for pid in &dead_pids {
                cache.shells.remove(pid);
            }
        }

        // Remove from DB (best-effort, don't fail the snapshot)
        if let Err(err) = self.db.delete_shells(&dead_pids) {
            tracing::warn!(error = %err, "Failed to delete dead shells from DB");
        }
        tracing::debug!(
            count = dead_pids.len(),
            "Pruned dead shells during snapshot"
        );

        // Return filtered snapshot
        let mut filtered = snapshot;
        for pid in &dead_pids {
            filtered.shells.remove(pid);
        }
        filtered
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

            let project_id = record.project_id.clone();
            let computed_workspace_id = workspace_id(&project_id, &record.project_path);

            enriched.push(EnrichedSession {
                session_id: record.session_id,
                pid: record.pid,
                state: record.state,
                cwd: record.cwd,
                project_id,
                workspace_id: computed_workspace_id,
                project_path: record.project_path,
                updated_at: record.updated_at,
                state_changed_at: record.state_changed_at,
                last_event: record.last_event,
                last_activity_at: record.last_activity_at,
                tools_in_flight: record.tools_in_flight,
                ready_reason: record.ready_reason,
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

            if entry.project_id.is_empty() && !record.project_id.is_empty() {
                entry.project_id = record.project_id.clone();
            }

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
            let has_session = aggregate.state != crate::reducer::SessionState::Idle;
            let computed_workspace_id = workspace_id(&aggregate.project_id, &project_path);
            results.push(ProjectState {
                project_id: aggregate.project_id.clone(),
                workspace_id: computed_workspace_id,
                project_path,
                state: aggregate.state.clone(),
                state_changed_at: aggregate.state_changed_at,
                updated_at: aggregate.updated_at,
                session_id: aggregate.session_id,
                session_count: aggregate.session_count,
                active_count: aggregate.active_count,
                has_session,
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
    pub project_id: String,
    pub workspace_id: String,
    pub project_path: String,
    pub state: crate::reducer::SessionState,
    pub state_changed_at: String,
    pub updated_at: String,
    pub session_id: Option<String>,
    pub session_count: usize,
    pub active_count: usize,
    pub has_session: bool,
}

#[derive(Debug, Clone)]
struct ProjectAggregate {
    project_id: String,
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
            project_id: record.project_id.clone(),
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
    if let Some(state) = inactivity_fallback_state(record, now) {
        return state;
    }
    record.state.clone()
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

#[derive(Clone, Copy)]
enum InactivityFallbackGuard {
    RequireLastEvent(&'static [&'static str]),
    InactivityOnly,
}

fn inactivity_fallback_policy(
    state: &crate::reducer::SessionState,
) -> Option<(crate::reducer::SessionState, InactivityFallbackGuard)> {
    match state {
        crate::reducer::SessionState::Working => Some((
            crate::reducer::SessionState::Ready,
            InactivityFallbackGuard::RequireLastEvent(&["task_completed"]),
        )),
        crate::reducer::SessionState::Compacting => Some((
            crate::reducer::SessionState::Ready,
            InactivityFallbackGuard::InactivityOnly,
        )),
        _ => None,
    }
}

fn inactivity_fallback_state(
    record: &SessionRecord,
    now: DateTime<Utc>,
) -> Option<crate::reducer::SessionState> {
    let (target_state, fallback_guard) = inactivity_fallback_policy(&record.state)?;
    if should_apply_inactivity_fallback(record, fallback_guard, now) {
        return Some(target_state);
    }
    None
}

fn should_apply_inactivity_fallback(
    record: &SessionRecord,
    fallback_guard: InactivityFallbackGuard,
    now: DateTime<Utc>,
) -> bool {
    match fallback_guard {
        InactivityFallbackGuard::RequireLastEvent(expected_events) => {
            let last_event = record.last_event.as_deref().unwrap_or_default();
            // Working auto-ready should only run after an explicit completion marker.
            // PostToolUse can occur repeatedly during an active working session and
            // causes false Ready transitions when activity is sparse.
            if !expected_events.contains(&last_event) {
                return false;
            }
        }
        InactivityFallbackGuard::InactivityOnly => {}
    }

    if record.tools_in_flight > 0 {
        return false;
    }

    let Some(last_activity) = record.last_activity_at.as_deref().and_then(parse_rfc3339) else {
        return false;
    };

    if now.signed_duration_since(last_activity).num_seconds() < SESSION_AUTO_READY_SECS {
        return false;
    }

    let Some(last_session_update) = parse_rfc3339(&record.updated_at) else {
        return false;
    };

    now.signed_duration_since(last_session_update).num_seconds() >= SESSION_AUTO_READY_SECS
}

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn clamp_catch_up_since(since: Option<DateTime<Utc>>, now: DateTime<Utc>) -> DateTime<Utc> {
    let cutoff = now - Duration::seconds(SESSION_CATCH_UP_MAX_AGE_SECS);
    match since {
        Some(value) if value > cutoff => value,
        _ => cutoff,
    }
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
            project_id: format!("{}/.git", project_path),
            project_path: project_path.to_string(),
            updated_at: updated_at.clone(),
            state_changed_at: updated_at,
            last_event: None,
            last_activity_at: None,
            tools_in_flight: 0,
            ready_reason: None,
        }
    }

    #[test]
    fn project_states_do_not_auto_ready_without_stop() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let stale_time = (Utc::now() - Duration::seconds(120)).to_rfc3339();
        let record = make_record("session-stale", "/repo", SessionState::Working, stale_time);
        state.db.upsert_session(&record).expect("insert session");

        let aggregates = state.project_states_snapshot().expect("project states");
        assert_eq!(aggregates.len(), 1);
        assert_eq!(aggregates[0].state, SessionState::Working);
    }

    #[test]
    fn project_states_keep_working_when_recent() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let fresh_time = (Utc::now() - Duration::seconds(2)).to_rfc3339();
        let record = make_record("session-fresh", "/repo", SessionState::Working, fresh_time);
        state.db.upsert_session(&record).expect("insert session");

        let aggregates = state.project_states_snapshot().expect("project states");
        assert_eq!(aggregates.len(), 1);
        assert_eq!(aggregates[0].state, SessionState::Working);
    }

    #[test]
    fn project_states_do_not_auto_ready_after_inactive_tool() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let stale_time = (Utc::now() - Duration::seconds(SESSION_AUTO_READY_SECS + 5)).to_rfc3339();
        let mut record = make_record("session-stale", "/repo", SessionState::Working, stale_time);
        record.last_activity_at = Some(record.updated_at.clone());
        record.last_event = Some("post_tool_use".to_string());
        record.tools_in_flight = 0;
        state.db.upsert_session(&record).expect("insert session");

        let aggregates = state.project_states_snapshot().expect("project states");
        assert_eq!(aggregates.len(), 1);
        assert_eq!(aggregates[0].state, SessionState::Working);
    }

    #[test]
    fn project_states_keep_working_after_inactive_tool_when_session_still_working() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let stale_activity =
            (Utc::now() - Duration::seconds(SESSION_AUTO_READY_SECS + 5)).to_rfc3339();
        let fresh_update = (Utc::now() - Duration::seconds(2)).to_rfc3339();
        let mut record = make_record(
            "session-stale",
            "/repo",
            SessionState::Working,
            fresh_update,
        );
        record.last_activity_at = Some(stale_activity);
        record.last_event = Some("post_tool_use".to_string());
        record.tools_in_flight = 0;
        state.db.upsert_session(&record).expect("insert session");

        let aggregates = state.project_states_snapshot().expect("project states");
        assert_eq!(aggregates.len(), 1);
        assert_eq!(aggregates[0].state, SessionState::Working);
    }

    #[test]
    fn project_states_keep_working_when_tools_in_flight() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let stale_time = (Utc::now() - Duration::seconds(SESSION_AUTO_READY_SECS + 5)).to_rfc3339();
        let mut record = make_record("session-stale", "/repo", SessionState::Working, stale_time);
        record.last_activity_at = Some(record.updated_at.clone());
        record.last_event = Some("post_tool_use".to_string());
        record.tools_in_flight = 1;
        state.db.upsert_session(&record).expect("insert session");

        let aggregates = state.project_states_snapshot().expect("project states");
        assert_eq!(aggregates.len(), 1);
        assert_eq!(aggregates[0].state, SessionState::Working);
    }

    #[test]
    fn project_states_auto_ready_after_inactive_task_completed() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let stale_time = (Utc::now() - Duration::seconds(SESSION_AUTO_READY_SECS + 5)).to_rfc3339();
        let mut record = make_record(
            "session-working",
            "/repo",
            SessionState::Working,
            stale_time,
        );
        record.last_activity_at = Some(record.updated_at.clone());
        record.last_event = Some("task_completed".to_string());
        record.tools_in_flight = 0;
        state.db.upsert_session(&record).expect("insert session");

        let aggregates = state.project_states_snapshot().expect("project states");
        assert_eq!(aggregates.len(), 1);
        assert_eq!(aggregates[0].state, SessionState::Ready);
    }

    #[test]
    fn project_states_auto_ready_after_inactive_compacting() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let stale_time = (Utc::now() - Duration::seconds(SESSION_AUTO_READY_SECS + 5)).to_rfc3339();
        let mut record = make_record(
            "session-compacting",
            "/repo",
            SessionState::Compacting,
            stale_time,
        );
        record.last_activity_at = Some(record.updated_at.clone());
        record.last_event = Some("pre_compact".to_string());
        record.tools_in_flight = 0;
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
        let expected_workspace = workspace_id(&aggregate.project_id, &aggregate.project_path);
        assert_eq!(aggregate.workspace_id, expected_workspace);
        assert_eq!(aggregate.state, SessionState::Working);
        assert_eq!(aggregate.session_count, 2);
        assert_eq!(aggregate.active_count, 1);
    }

    #[test]
    fn startup_does_not_replay_from_shell_cwd_only_newer_event() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let session_time = "2026-02-11T22:00:00Z".to_string();
        let session = make_record(
            "session-keep",
            "/Users/petepetrash/Code/writing",
            SessionState::Ready,
            session_time,
        );
        db.upsert_session(&session).expect("insert session");

        let shell_event = EventEnvelope {
            event_id: "evt-shell-newer".to_string(),
            recorded_at: "2026-02-11T22:00:30Z".to_string(),
            event_type: EventType::ShellCwd,
            session_id: Some("session-keep".to_string()),
            pid: Some(1234),
            cwd: Some("/Users/petepetrash/Code/writing".to_string()),
            tool: None,
            file_path: None,
            parent_app: None,
            tty: Some("/dev/ttys001".to_string()),
            tmux_session: None,
            tmux_client_tty: None,
            notification_type: None,
            stop_hook_active: None,
            metadata: None,
        };
        db.insert_event(&shell_event)
            .expect("insert shell cwd event");

        let state = SharedState::new(db);
        let sessions = state.db.list_sessions().expect("list sessions");
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "session-keep");
        assert_eq!(sessions[0].state, SessionState::Ready);
    }

    #[test]
    fn startup_catch_up_keeps_existing_sessions_when_newer_session_events_exist() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let now = Utc::now();
        let old_time = (now - Duration::days(9)).to_rfc3339();
        let newer_stop_at = (now - Duration::minutes(5)).to_rfc3339();

        let preserved = make_record(
            "session-preserved",
            "/Users/petepetrash/Code/preserved",
            SessionState::Ready,
            old_time.clone(),
        );
        db.upsert_session(&preserved)
            .expect("insert preserved session");

        let stale = make_record(
            "session-stale",
            "/Users/petepetrash/Code/writing",
            SessionState::Working,
            old_time,
        );
        db.upsert_session(&stale).expect("insert stale session");

        let newer_stop = EventEnvelope {
            event_id: "evt-stop-newer".to_string(),
            recorded_at: newer_stop_at,
            event_type: EventType::Stop,
            session_id: Some("session-stale".to_string()),
            pid: Some(1234),
            cwd: Some("/Users/petepetrash/Code/writing".to_string()),
            tool: None,
            file_path: None,
            parent_app: None,
            tty: Some("/dev/ttys001".to_string()),
            tmux_session: None,
            tmux_client_tty: None,
            notification_type: None,
            stop_hook_active: Some(false),
            metadata: None,
        };
        db.insert_event(&newer_stop).expect("insert newer stop");

        let state = SharedState::new(db);
        let sessions = state.db.list_sessions().expect("list sessions");

        assert_eq!(sessions.len(), 2);
        assert!(sessions
            .iter()
            .any(|session| session.session_id == "session-preserved"));
        let stale_after = sessions
            .iter()
            .find(|session| session.session_id == "session-stale")
            .expect("stale session exists");
        assert_eq!(stale_after.state, SessionState::Ready);
        assert_eq!(stale_after.updated_at, newer_stop.recorded_at);
    }

    #[test]
    fn sessions_snapshot_keeps_recent_session_when_pid_not_alive() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let mut record = make_record(
            "session-dead-pid",
            "/Users/petepetrash/Code/writing",
            SessionState::Working,
            Utc::now().to_rfc3339(),
        );
        record.pid = 999_999;
        state.db.upsert_session(&record).expect("insert session");

        let sessions = state.sessions_snapshot().expect("sessions snapshot");
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "session-dead-pid");
        assert_eq!(sessions[0].state, SessionState::Working);
    }

    #[test]
    fn project_states_keep_recent_session_when_pid_not_alive() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let mut record = make_record(
            "session-dead-pid",
            "/Users/petepetrash/Code/writing",
            SessionState::Working,
            Utc::now().to_rfc3339(),
        );
        record.pid = 999_999;
        state.db.upsert_session(&record).expect("insert session");

        let projects = state.project_states_snapshot().expect("project states");
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].project_path, "/Users/petepetrash/Code/writing");
        assert_eq!(projects[0].state, SessionState::Working);
    }

    #[test]
    fn startup_with_no_sessions_does_not_replay_old_history() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let old_event = EventEnvelope {
            event_id: "evt-old-prompt".to_string(),
            recorded_at: "2026-02-02T19:11:20.686907+00:00".to_string(),
            event_type: EventType::UserPromptSubmit,
            session_id: Some("session-old".to_string()),
            pid: Some(1234),
            cwd: Some("/Users/petepetrash/Code/writing".to_string()),
            tool: None,
            file_path: None,
            parent_app: None,
            tty: Some("/dev/ttys001".to_string()),
            tmux_session: None,
            tmux_client_tty: None,
            notification_type: None,
            stop_hook_active: None,
            metadata: None,
        };
        db.insert_event(&old_event).expect("insert old event");

        let state = SharedState::new(db);
        let sessions = state.db.list_sessions().expect("list sessions");
        assert!(sessions.is_empty());
    }

    #[test]
    fn catch_up_since_clamps_old_timestamp_to_recent_window() {
        let now = parse_rfc3339("2026-02-11T22:00:00Z").expect("parse now");
        let old = parse_rfc3339("2026-02-02T19:11:20.686907+00:00").expect("parse old");

        let clamped = clamp_catch_up_since(Some(old), now);
        let expected = now - Duration::seconds(SESSION_CATCH_UP_MAX_AGE_SECS);
        assert_eq!(clamped, expected);
    }

    #[test]
    fn catch_up_since_keeps_recent_timestamp() {
        let now = parse_rfc3339("2026-02-11T22:00:00Z").expect("parse now");
        let recent = parse_rfc3339("2026-02-11T21:30:00Z").expect("parse recent");

        let clamped = clamp_catch_up_since(Some(recent), now);
        assert_eq!(clamped, recent);
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
    pub project_id: String,
    pub workspace_id: String,
    pub project_path: String,
    pub updated_at: String,
    pub state_changed_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_activity_at: Option<String>,
    pub tools_in_flight: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ready_reason: Option<String>,
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
