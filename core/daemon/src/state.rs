//! In-memory state managed by the daemon.
//!
//! Phase 3 persists an append-only event log plus a materialized shell CWD
//! table, keeping shell state fast to query while other state remains event-only.

use capacitor_daemon_protocol::{
    EventEnvelope, EventType, RoutingConfigView, RoutingDiagnostics, RoutingSnapshot,
    RoutingStatus, RoutingTarget, RoutingTargetKind,
};
use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Mutex;

use crate::activity::{reduce_activity, ActivityEntry};
use crate::db::{Db, HemShadowMismatch, TombstoneRow};
use crate::hem::{
    HemCapabilityStatus, HemCapabilityTracker, HemEffectiveCapabilities, HemMode, HemProjectState,
    HemRuntimeConfig,
};
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
const STOP_GATE_WORKING_GRACE_SECS: i64 = 20; // Short-lived guard for false Stop->Ready while session is still actively finishing.
const SESSION_CATCH_UP_MAX_AGE_SECS: i64 = SESSION_TTL_READY_SECS + (5 * 60); // Ready TTL plus margin.
const HEM_SHADOW_MISMATCH_RETENTION_DAYS: i64 = 14;
const HEM_SHADOW_MISMATCH_PERSIST_LIMIT_PER_EVENT: usize = 4;
const HEM_STABLE_STATE_TRANSITION_EXCLUSION_SECS: i64 = 20;
const HEM_STABLE_STATE_AGREEMENT_GATE_TARGET: f64 = 0.995;

pub struct SharedState {
    db: Db,
    hem_config: HemRuntimeConfig,
    routing_config: crate::are::state::RoutingConfig,
    shell_state: Mutex<ShellState>,
    routing_state: Mutex<crate::are::state::RoutingState>,
    routing_metrics: Mutex<crate::are::metrics::RoutingMetrics>,
    routing_shell_registry: Mutex<crate::are::registry::ShellRegistry>,
    routing_tmux_registry: Mutex<crate::are::registry::TmuxRegistry>,
    routing_process_registry: Mutex<crate::are::registry::ProcessRegistry>,
    dead_session_reconcile: Mutex<HashMap<String, DeadSessionReconcileMetrics>>,
    hem_shadow_metrics: Mutex<HemShadowMetrics>,
    hem_capability_tracker: Mutex<HemCapabilityTracker>,
    mutation_lock: Mutex<()>,
}

impl SharedState {
    #[allow(dead_code)]
    pub fn new(db: Db) -> Self {
        Self::new_with_hem_config(db, HemRuntimeConfig::default())
    }

    pub fn new_with_hem_config(db: Db, hem_config: HemRuntimeConfig) -> Self {
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
        if let Err(err) = db.prune_hem_shadow_mismatches(HEM_SHADOW_MISMATCH_RETENTION_DAYS) {
            tracing::warn!(error = %err, "Failed to prune HEM shadow mismatches");
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

        let routing_config = hem_config.routing_config();
        let routing_shell_registry = build_routing_shell_registry(&shell_state);

        let shared = Self {
            db,
            hem_config: hem_config.clone(),
            routing_config: routing_config.clone(),
            shell_state: Mutex::new(shell_state),
            routing_state: Mutex::new(crate::are::state::RoutingState::default()),
            routing_metrics: Mutex::new(crate::are::metrics::RoutingMetrics::new(&routing_config)),
            routing_shell_registry: Mutex::new(routing_shell_registry),
            routing_tmux_registry: Mutex::new(crate::are::registry::TmuxRegistry::default()),
            routing_process_registry: Mutex::new(crate::are::registry::ProcessRegistry::default()),
            dead_session_reconcile: Mutex::new(HashMap::new()),
            hem_shadow_metrics: Mutex::new(HemShadowMetrics::new(&hem_config)),
            hem_capability_tracker: Mutex::new(HemCapabilityTracker::new()),
            mutation_lock: Mutex::new(()),
        };

        if let Err(err) = shared.reconcile_dead_non_idle_sessions("startup") {
            tracing::warn!(
                error = %err,
                "Failed to reconcile dead non-idle sessions at startup"
            );
        }

        shared
    }

    pub fn update_from_event(&self, event: &EventEnvelope) {
        let _mutation_guard = self
            .mutation_lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        match self.db.insert_event(event) {
            Ok(true) => {}
            Ok(false) => {
                tracing::debug!(event_id = %event.event_id, "Skipping duplicate daemon event");
                return;
            }
            Err(err) => {
                tracing::warn!(error = %err, "Failed to persist daemon event");
                return;
            }
        }

        if let Err(err) = self.db.upsert_process_liveness(event) {
            tracing::warn!(error = %err, "Failed to update process liveness");
        }
        self.update_routing_process_registry(event);

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
            self.update_routing_shell_registry(event);
        }

        self.evaluate_hem_shadow(event);
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

    pub fn reconcile_dead_non_idle_sessions(&self, source: &str) -> Result<usize, String> {
        let _mutation_guard = self
            .mutation_lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let mut sessions = self.db.list_sessions()?;
        let now = Utc::now().to_rfc3339();
        let marker = format!("dead_pid_reconcile_{}", source);
        let mut repaired = 0usize;

        for record in &mut sessions {
            if record.state == crate::reducer::SessionState::Idle {
                continue;
            }
            if self.session_is_alive(record.pid) != Some(false) {
                continue;
            }

            record.state = crate::reducer::SessionState::Idle;
            record.updated_at = now.clone();
            record.state_changed_at = now.clone();
            record.last_event = Some(marker.clone());
            record.tools_in_flight = 0;
            record.ready_reason = None;
            self.db.upsert_session(record)?;
            repaired += 1;
        }

        if repaired > 0 {
            tracing::info!(
                count = repaired,
                source = %source,
                "Reconciled dead non-idle sessions to idle"
            );
        }

        self.record_dead_session_reconcile(source, repaired as u64, &now);

        Ok(repaired)
    }

    pub fn dead_session_reconcile_snapshot(&self) -> HashMap<String, DeadSessionReconcileMetrics> {
        self.dead_session_reconcile
            .lock()
            .map(|metrics| metrics.clone())
            .unwrap_or_default()
    }

    pub fn hem_shadow_metrics_snapshot(&self) -> HemShadowMetrics {
        self.hem_shadow_metrics
            .lock()
            .map(|metrics| metrics.clone())
            .unwrap_or_default()
    }

    pub fn routing_metrics_snapshot(&self) -> crate::are::metrics::RoutingMetrics {
        self.routing_metrics
            .lock()
            .map(|metrics| metrics.clone())
            .unwrap_or_default()
    }

    pub fn routing_config_view(&self) -> RoutingConfigView {
        self.routing_config.view()
    }

    pub fn routing_poller_enabled(&self) -> bool {
        self.routing_config.enabled || self.routing_config.feature_flags.dual_run
    }

    pub fn routing_tmux_poll_interval_ms(&self) -> u64 {
        self.routing_config.tmux_poll_interval_ms.max(100)
    }

    pub fn routing_snapshot(
        &self,
        project_path: &str,
        workspace_id_param: Option<&str>,
    ) -> Result<RoutingSnapshot, String> {
        let diagnostics = self.resolve_routing(project_path, workspace_id_param)?;
        self.emit_routing_observability(&diagnostics);
        let snapshot = diagnostics.snapshot.clone();

        if let Ok(mut state) = self.routing_state.lock() {
            state.cache_snapshot(snapshot.clone());
        }

        if let Ok(mut metrics) = self.routing_metrics.lock() {
            metrics.record_snapshot(&snapshot);
            if self.routing_config.feature_flags.dual_run {
                let legacy = self.legacy_routing_decision(project_path);
                metrics.record_divergence(&legacy, &snapshot);
            }
        } else {
            tracing::warn!("Failed to update routing metrics (poisoned lock)");
        }

        Ok(snapshot)
    }

    pub fn routing_diagnostics(
        &self,
        project_path: &str,
        workspace_id_param: Option<&str>,
    ) -> Result<RoutingDiagnostics, String> {
        self.resolve_routing(project_path, workspace_id_param)
    }

    pub fn apply_tmux_snapshot(
        &self,
        snapshot: crate::are::tmux_poller::TmuxSnapshot,
        diff: crate::are::tmux_poller::TmuxDiff,
    ) {
        if let Ok(mut tmux_registry) = self.routing_tmux_registry.lock() {
            tmux_registry.replace_snapshot(snapshot.clients, snapshot.sessions);
        } else {
            tracing::warn!("Failed to update tmux registry from poller (poisoned lock)");
            return;
        }

        tracing::debug!(
            clients_added = diff.clients_added,
            clients_removed = diff.clients_removed,
            clients_updated = diff.clients_updated,
            sessions_added = diff.sessions_added,
            sessions_removed = diff.sessions_removed,
            sessions_updated = diff.sessions_updated,
            "ARE tmux poll diff applied"
        );
    }

    fn resolve_routing(
        &self,
        project_path: &str,
        workspace_id_param: Option<&str>,
    ) -> Result<RoutingDiagnostics, String> {
        let normalized_project_path = project_path.trim();
        if normalized_project_path.is_empty() {
            return Err("project_path is required".to_string());
        }
        let resolved_workspace_id =
            normalize_workspace_id(workspace_id_param).unwrap_or_else(|| {
                crate::project_identity::resolve_project_identity(normalized_project_path)
                    .map(|identity| workspace_id(&identity.project_id, &identity.project_path))
                    .unwrap_or_else(|| {
                        workspace_id(normalized_project_path, normalized_project_path)
                    })
            });
        let shell_registry = self
            .routing_shell_registry
            .lock()
            .map(|registry| registry.clone())
            .unwrap_or_default();
        let tmux_registry = self
            .routing_tmux_registry
            .lock()
            .map(|registry| registry.clone())
            .unwrap_or_default();
        Ok(crate::are::resolver::resolve(
            crate::are::resolver::ResolveInput {
                project_path: normalized_project_path,
                workspace_id: &resolved_workspace_id,
                now: Utc::now(),
                config: &self.routing_config,
                shell_registry: &shell_registry,
                tmux_registry: &tmux_registry,
            },
        ))
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
        if self.hem_config.engine.enabled && matches!(self.hem_config.engine.mode, HemMode::Primary)
        {
            return self.project_states_snapshot_hem_primary();
        }

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
            let effective_state = effective_session_state(&record, now, is_alive);
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
        results.sort_by(|left, right| {
            left.project_path
                .cmp(&right.project_path)
                .then_with(|| left.session_id.cmp(&right.session_id))
        });

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

    fn project_states_snapshot_hem_primary(&self) -> Result<Vec<ProjectState>, String> {
        let sessions = self.db.list_sessions()?;
        let now = Utc::now();
        let mut eligible_sessions = Vec::new();

        for record in sessions {
            if record.project_path.trim().is_empty() {
                continue;
            }
            if self.is_session_expired(&record, now) {
                self.prune_session(&record.session_id)?;
                continue;
            }
            let is_alive = self.session_is_alive(record.pid);
            let mut normalized = record;
            normalized.state = effective_session_state(&normalized, now, is_alive);
            eligible_sessions.push(normalized);
        }

        let hem_states =
            crate::hem::synthesize_project_states_shadow(&eligible_sessions, now, &self.hem_config);

        let mut results = Vec::new();
        for hem_state in hem_states {
            let related_sessions = eligible_sessions
                .iter()
                .filter(|record| {
                    record.project_path == hem_state.project_path
                        || record.cwd == hem_state.project_path
                })
                .collect::<Vec<_>>();

            let mut session_count = 0usize;
            let mut active_count = 0usize;
            let mut latest: Option<(&SessionRecord, DateTime<Utc>)> = None;
            for record in &related_sessions {
                session_count += 1;
                if session_state_is_active(&record.state) {
                    active_count += 1;
                }
                if let Some(ts) = session_timestamp(record) {
                    match latest {
                        Some((_, current_ts)) if ts <= current_ts => {}
                        _ => latest = Some((record, ts)),
                    }
                }
            }

            let (updated_at, state_changed_at, session_id) = match latest {
                Some((record, _)) => (
                    record.updated_at.clone(),
                    record.state_changed_at.clone(),
                    Some(record.session_id.clone()),
                ),
                None => {
                    let now_rfc3339 = now.to_rfc3339();
                    (now_rfc3339.clone(), now_rfc3339, None)
                }
            };

            let computed_workspace_id =
                workspace_id(&hem_state.project_id, &hem_state.project_path);
            results.push(ProjectState {
                project_id: hem_state.project_id.clone(),
                workspace_id: computed_workspace_id,
                project_path: hem_state.project_path.clone(),
                state: hem_state.state.clone(),
                state_changed_at,
                updated_at,
                session_id,
                session_count: session_count.max(hem_state.evidence_count),
                active_count,
                has_session: hem_state.state != crate::reducer::SessionState::Idle,
            });
        }

        results.sort_by(|left, right| {
            left.project_path
                .cmp(&right.project_path)
                .then_with(|| left.session_id.cmp(&right.session_id))
        });

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
            tracing::debug!(summary = %summary, "Project state snapshot summary (HEM primary)");
        } else {
            tracing::debug!("Project state snapshot empty (HEM primary)");
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

    fn update_routing_process_registry(&self, event: &EventEnvelope) {
        let Some(pid) = event.pid else {
            return;
        };
        let checked_at = parse_rfc3339(&event.recorded_at).unwrap_or_else(Utc::now);
        let proc_start = metadata_proc_start(event.metadata.as_ref());
        let signal = crate::are::registry::ProcessSignal {
            pid,
            proc_start,
            is_alive: true,
            checked_at,
        };
        if let Ok(mut registry) = self.routing_process_registry.lock() {
            registry.upsert(signal);
        }
    }

    fn update_routing_shell_registry(&self, event: &EventEnvelope) {
        let (pid, cwd, tty) = match (event.pid, &event.cwd, &event.tty) {
            (Some(pid), Some(cwd), Some(tty)) => (pid, cwd, tty),
            _ => return,
        };
        let recorded_at = parse_rfc3339(&event.recorded_at).unwrap_or_else(Utc::now);
        let signal = crate::are::registry::ShellSignal {
            pid,
            proc_start: metadata_proc_start(event.metadata.as_ref()),
            cwd: cwd.clone(),
            tty: tty.clone(),
            parent_app: event.parent_app.clone(),
            tmux_session: event.tmux_session.clone(),
            tmux_client_tty: event.tmux_client_tty.clone(),
            tmux_pane: metadata_tmux_pane(event.metadata.as_ref()),
            recorded_at,
        };
        if let Ok(mut registry) = self.routing_shell_registry.lock() {
            registry.upsert(signal.clone());
        }

        if let (Some(client_tty), Some(session_name)) = (
            signal.tmux_client_tty.as_ref(),
            signal.tmux_session.as_ref(),
        ) {
            if let Ok(mut tmux_registry) = self.routing_tmux_registry.lock() {
                tmux_registry.upsert_client(crate::are::registry::TmuxClientSignal {
                    client_tty: client_tty.clone(),
                    session_name: session_name.clone(),
                    pane_current_path: Some(signal.cwd.clone()),
                    captured_at: signal.recorded_at,
                });
                tmux_registry.upsert_session(crate::are::registry::TmuxSessionSignal {
                    session_name: session_name.clone(),
                    pane_paths: vec![signal.cwd.clone()],
                    captured_at: signal.recorded_at,
                });
            }
        }
    }

    fn legacy_routing_decision(
        &self,
        project_path: &str,
    ) -> crate::are::metrics::LegacyRoutingDecision {
        let project_path = normalize_routing_path(project_path);
        let now = Utc::now();
        let shell_registry = self
            .routing_shell_registry
            .lock()
            .map(|registry| registry.clone())
            .unwrap_or_default();

        let mut best: Option<(u8, u64, crate::are::registry::ShellSignal)> = None;
        for shell in shell_registry.all() {
            let shell_path = normalize_routing_path(&shell.cwd);
            let path_quality = path_match_quality(&project_path, &shell_path);
            if path_quality == 0 {
                continue;
            }
            let age = routing_age_ms(now, shell.recorded_at);
            let shell_owned = shell.clone();
            match &best {
                Some((best_quality, best_age, best_shell)) => {
                    if path_quality > *best_quality
                        || (path_quality == *best_quality
                            && (age < *best_age
                                || (age == *best_age
                                    && shell_owned.tty.as_str().cmp(best_shell.tty.as_str())
                                        == std::cmp::Ordering::Less)))
                    {
                        best = Some((path_quality, age, shell_owned));
                    }
                }
                None => best = Some((path_quality, age, shell_owned)),
            }
        }

        let Some((_, age, shell)) = best else {
            return crate::are::metrics::LegacyRoutingDecision {
                status: RoutingStatus::Unavailable,
                target: RoutingTarget {
                    kind: RoutingTargetKind::None,
                    value: None,
                },
            };
        };

        let target = if let Some(session_name) = shell.tmux_session.as_ref() {
            RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some(session_name.clone()),
            }
        } else if let Some(parent_app) = sanitize_parent_app(shell.parent_app.as_deref()) {
            RoutingTarget {
                kind: RoutingTargetKind::TerminalApp,
                value: Some(parent_app.to_string()),
            }
        } else {
            RoutingTarget {
                kind: RoutingTargetKind::None,
                value: None,
            }
        };

        if target.kind == RoutingTargetKind::None {
            return crate::are::metrics::LegacyRoutingDecision {
                status: RoutingStatus::Unavailable,
                target,
            };
        }

        let is_fresh = age <= self.routing_config.shell_signal_fresh_ms;
        let attached = shell
            .tmux_client_tty
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty());
        let status = if attached && is_fresh {
            RoutingStatus::Attached
        } else {
            RoutingStatus::Detached
        };
        crate::are::metrics::LegacyRoutingDecision { status, target }
    }

    fn emit_routing_observability(&self, diagnostics: &RoutingDiagnostics) {
        let target_kind = match diagnostics.snapshot.target.kind {
            RoutingTargetKind::TmuxSession => "tmux_session",
            RoutingTargetKind::TerminalApp => "terminal_app",
            RoutingTargetKind::None => "none",
        };
        let confidence = match diagnostics.snapshot.confidence {
            capacitor_daemon_protocol::RoutingConfidence::High => "high",
            capacitor_daemon_protocol::RoutingConfidence::Medium => "medium",
            capacitor_daemon_protocol::RoutingConfidence::Low => "low",
        };
        tracing::info!(
            event = "routing_snapshot_emitted",
            workspace_id = %diagnostics.snapshot.workspace_id,
            reason_code = %diagnostics.snapshot.reason_code,
            confidence = confidence,
            target_kind = target_kind,
            target_value = ?diagnostics.snapshot.target.value,
            signal_ages_ms = ?diagnostics.signal_ages_ms,
            "Routing snapshot emitted"
        );

        let shell_stale = diagnostics
            .signal_ages_ms
            .get("shell_cwd")
            .is_some_and(|age| *age > self.routing_config.shell_signal_fresh_ms);
        let tmux_stale = diagnostics
            .signal_ages_ms
            .get("tmux_client")
            .is_some_and(|age| *age > self.routing_config.tmux_signal_fresh_ms);
        if shell_stale || tmux_stale {
            tracing::warn!(
                event = "routing_signal_stale",
                workspace_id = %diagnostics.snapshot.workspace_id,
                signal_ages_ms = ?diagnostics.signal_ages_ms,
                "Routing signals stale"
            );
        }
        if !diagnostics.conflicts.is_empty() {
            tracing::warn!(
                event = "routing_conflict_detected",
                workspace_id = %diagnostics.snapshot.workspace_id,
                conflicts = ?diagnostics.conflicts,
                "Routing conflict detected"
            );
        }
        if diagnostics.scope_resolution == "workspace_ambiguous" {
            tracing::warn!(
                event = "routing_scope_ambiguous",
                workspace_id = %diagnostics.snapshot.workspace_id,
                "Routing scope ambiguous"
            );
        }
    }

    fn record_dead_session_reconcile(&self, source: &str, repaired: u64, now: &str) {
        if let Ok(mut metrics) = self.dead_session_reconcile.lock() {
            let entry = metrics
                .entry(source.to_string())
                .or_insert_with(DeadSessionReconcileMetrics::default);
            entry.runs = entry.runs.saturating_add(1);
            entry.last_run_at = Some(now.to_string());
            if repaired > 0 {
                entry.repaired_sessions = entry.repaired_sessions.saturating_add(repaired);
                entry.last_repair_at = Some(now.to_string());
            }
        } else {
            tracing::warn!("Failed to record dead-session reconciliation metrics (poisoned lock)");
        }
    }

    fn evaluate_hem_shadow(&self, event: &EventEnvelope) {
        let enabled = self
            .hem_shadow_metrics
            .lock()
            .map(|metrics| metrics.enabled)
            .unwrap_or(false);
        if !enabled {
            return;
        }
        if !should_evaluate_hem_shadow_for_event(event.event_type) {
            return;
        }

        let capability_assessment = if let Ok(mut tracker) = self.hem_capability_tracker.lock() {
            tracker.observe_event(event);
            tracker.assess(&self.hem_config, event.recorded_at.as_str())
        } else {
            crate::hem::HemCapabilityAssessment::from_config(&self.hem_config)
        };
        if capability_assessment.status.warning_count > 0 && capability_assessment.warnings_changed
        {
            tracing::warn!(
                strategy = %capability_assessment.status.strategy,
                handshake_seen = capability_assessment.status.handshake_seen,
                unknown_count = capability_assessment.status.unknown_count,
                misdeclared_count = capability_assessment.status.misdeclared_count,
                confidence_penalty_factor = capability_assessment.status.confidence_penalty_factor,
                warnings = ?capability_assessment.status.warnings,
                "HEM capability profile degraded by runtime assessment"
            );
        }

        let reducer_states = match self.project_states_snapshot() {
            Ok(states) => states,
            Err(err) => {
                tracing::warn!(error = %err, "Failed to build reducer project snapshot for HEM shadow");
                return;
            }
        };
        let sessions = match self.db.list_sessions() {
            Ok(sessions) => sessions,
            Err(err) => {
                tracing::warn!(error = %err, "Failed to load sessions for HEM shadow synthesis");
                return;
            }
        };
        let effective_capabilities = HemEffectiveCapabilities {
            confidence_penalty_factor: capability_assessment.confidence_penalty_factor,
            notification_matcher_support: capability_assessment.notification_matcher_support,
        };
        let hem_states = crate::hem::synthesize_project_states_shadow_with_capabilities(
            &sessions,
            Utc::now(),
            &self.hem_config,
            &effective_capabilities,
        );
        let mismatches = build_hem_shadow_mismatches(event, &reducer_states, &hem_states);
        let stable_state_agreement = compute_stable_state_agreement(
            event.recorded_at.as_str(),
            &reducer_states,
            &hem_states,
        );

        for mismatch in select_mismatches_for_persistence(
            &mismatches,
            HEM_SHADOW_MISMATCH_PERSIST_LIMIT_PER_EVENT,
        ) {
            if let Err(err) = self.db.insert_hem_shadow_mismatch(mismatch) {
                tracing::warn!(error = %err, "Failed to persist HEM shadow mismatch");
            }
        }
        self.record_hem_shadow_metrics(
            event.recorded_at.as_str(),
            reducer_states.len(),
            &mismatches,
            stable_state_agreement,
            capability_assessment.status,
        );
    }

    fn record_hem_shadow_metrics(
        &self,
        observed_at: &str,
        projects_evaluated: usize,
        mismatches: &[HemShadowMismatch],
        stable_state_agreement: StableStateAgreementSample,
        capability_status: HemCapabilityStatus,
    ) {
        if let Ok(mut metrics) = self.hem_shadow_metrics.lock() {
            metrics.events_evaluated = metrics.events_evaluated.saturating_add(1);
            metrics.projects_evaluated = metrics
                .projects_evaluated
                .saturating_add(projects_evaluated as u64);
            metrics.capability_status = capability_status;
            metrics.stable_state_samples = metrics
                .stable_state_samples
                .saturating_add(stable_state_agreement.samples);
            metrics.stable_state_matches = metrics
                .stable_state_matches
                .saturating_add(stable_state_agreement.matches);
            metrics.last_evaluated_at = Some(observed_at.to_string());
            if mismatches.is_empty() {
                metrics.refresh_cutover_summary();
                return;
            }

            metrics.mismatches_total = metrics
                .mismatches_total
                .saturating_add(mismatches.len() as u64);
            metrics.last_mismatch_at = Some(observed_at.to_string());
            for mismatch in mismatches {
                let entry = metrics
                    .mismatches_by_category
                    .entry(mismatch.category.clone())
                    .or_insert(0);
                *entry = entry.saturating_add(1);
                let severity = mismatch_severity(&mismatch.category);
                let severity_entry = metrics
                    .mismatches_by_severity
                    .entry(severity.to_string())
                    .or_insert(0);
                *severity_entry = severity_entry.saturating_add(1);
                match severity {
                    "critical" => {
                        metrics.gate_critical_mismatches =
                            metrics.gate_critical_mismatches.saturating_add(1);
                        metrics.gate_blocking_mismatches =
                            metrics.gate_blocking_mismatches.saturating_add(1);
                        metrics.last_blocking_mismatch_at = Some(observed_at.to_string());
                    }
                    "important" => {
                        metrics.gate_important_mismatches =
                            metrics.gate_important_mismatches.saturating_add(1);
                        metrics.gate_blocking_mismatches =
                            metrics.gate_blocking_mismatches.saturating_add(1);
                        metrics.last_blocking_mismatch_at = Some(observed_at.to_string());
                    }
                    _ => {}
                }
            }
            metrics.refresh_cutover_summary();
        } else {
            tracing::warn!("Failed to record HEM shadow metrics (poisoned lock)");
        }
    }
}

fn should_evaluate_hem_shadow_for_event(event_type: EventType) -> bool {
    matches!(
        event_type,
        EventType::SessionEnd
            | EventType::TaskCompleted
            | EventType::Stop
            | EventType::ShellCwd
            | EventType::Notification
    )
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct DeadSessionReconcileMetrics {
    pub runs: u64,
    pub repaired_sessions: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_run_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_repair_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HemShadowMetrics {
    pub enabled: bool,
    pub mode: String,
    pub capability_status: HemCapabilityStatus,
    pub events_evaluated: u64,
    pub projects_evaluated: u64,
    pub mismatches_total: u64,
    pub mismatches_by_category: HashMap<String, u64>,
    pub mismatches_by_severity: HashMap<String, u64>,
    pub gate_blocking_mismatches: u64,
    pub gate_critical_mismatches: u64,
    pub gate_important_mismatches: u64,
    pub stable_state_samples: u64,
    pub stable_state_matches: u64,
    pub stable_state_agreement_rate: f64,
    pub stable_state_agreement_gate_target: f64,
    pub stable_state_agreement_gate_met: bool,
    pub shadow_gate_ready: bool,
    pub blocking_mismatch_rate: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_evaluated_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_mismatch_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_blocking_mismatch_at: Option<String>,
}

impl HemShadowMetrics {
    fn new(config: &HemRuntimeConfig) -> Self {
        Self {
            enabled: config.engine.enabled && matches!(config.engine.mode, HemMode::Shadow),
            mode: match config.engine.mode {
                HemMode::Shadow => "shadow".to_string(),
                HemMode::Primary => "primary".to_string(),
            },
            capability_status: HemCapabilityStatus::from_strategy(
                &config.capability_detection.strategy,
            ),
            events_evaluated: 0,
            projects_evaluated: 0,
            mismatches_total: 0,
            mismatches_by_category: HashMap::new(),
            mismatches_by_severity: HashMap::new(),
            gate_blocking_mismatches: 0,
            gate_critical_mismatches: 0,
            gate_important_mismatches: 0,
            stable_state_samples: 0,
            stable_state_matches: 0,
            stable_state_agreement_rate: 0.0,
            stable_state_agreement_gate_target: HEM_STABLE_STATE_AGREEMENT_GATE_TARGET,
            stable_state_agreement_gate_met: false,
            shadow_gate_ready: false,
            blocking_mismatch_rate: 0.0,
            last_evaluated_at: None,
            last_mismatch_at: None,
            last_blocking_mismatch_at: None,
        }
    }

    fn refresh_cutover_summary(&mut self) {
        self.shadow_gate_ready =
            self.enabled && self.events_evaluated > 0 && self.gate_blocking_mismatches == 0;
        if self.stable_state_samples == 0 {
            self.stable_state_agreement_rate = 0.0;
        } else {
            self.stable_state_agreement_rate =
                self.stable_state_matches as f64 / self.stable_state_samples as f64;
        }
        self.stable_state_agreement_gate_met = self.stable_state_samples > 0
            && self.stable_state_agreement_rate >= self.stable_state_agreement_gate_target;
        if self.projects_evaluated == 0 {
            self.blocking_mismatch_rate = 0.0;
        } else {
            self.blocking_mismatch_rate =
                self.gate_blocking_mismatches as f64 / self.projects_evaluated as f64;
        }
    }
}

impl Default for HemShadowMetrics {
    fn default() -> Self {
        Self {
            enabled: false,
            mode: "shadow".to_string(),
            capability_status: HemCapabilityStatus::default(),
            events_evaluated: 0,
            projects_evaluated: 0,
            mismatches_total: 0,
            mismatches_by_category: HashMap::new(),
            mismatches_by_severity: HashMap::new(),
            gate_blocking_mismatches: 0,
            gate_critical_mismatches: 0,
            gate_important_mismatches: 0,
            stable_state_samples: 0,
            stable_state_matches: 0,
            stable_state_agreement_rate: 0.0,
            stable_state_agreement_gate_target: HEM_STABLE_STATE_AGREEMENT_GATE_TARGET,
            stable_state_agreement_gate_met: false,
            shadow_gate_ready: false,
            blocking_mismatch_rate: 0.0,
            last_evaluated_at: None,
            last_mismatch_at: None,
            last_blocking_mismatch_at: None,
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

fn build_hem_shadow_mismatches(
    event: &EventEnvelope,
    reducer_states: &[ProjectState],
    hem_states: &[HemProjectState],
) -> Vec<HemShadowMismatch> {
    let mut reducer_by_path: HashMap<&str, &ProjectState> = HashMap::new();
    for state in reducer_states {
        reducer_by_path.insert(state.project_path.as_str(), state);
    }

    let mut hem_by_path: HashMap<&str, &HemProjectState> = HashMap::new();
    for state in hem_states {
        hem_by_path.insert(state.project_path.as_str(), state);
    }

    let mut mismatches = Vec::new();
    for (project_path, reducer_state) in &reducer_by_path {
        match hem_by_path.remove(project_path) {
            Some(hem_state) => {
                if reducer_state.state != hem_state.state {
                    mismatches.push(HemShadowMismatch {
                        observed_at: event.recorded_at.clone(),
                        event_id: Some(event.event_id.clone()),
                        session_id: event.session_id.clone(),
                        project_id: Some(reducer_state.project_id.clone()),
                        project_path: Some((*project_path).to_string()),
                        category: "state_mismatch".to_string(),
                        reducer_state: Some(reducer_state.state.as_str().to_string()),
                        hem_state: Some(hem_state.state.as_str().to_string()),
                        confidence_delta: Some((1.0 - hem_state.confidence).max(0.0)),
                        detail_json: Some(
                            serde_json::json!({
                                "hem_confidence": hem_state.confidence,
                                "hem_evidence_count": hem_state.evidence_count
                            })
                            .to_string(),
                        ),
                    });
                }
            }
            None => mismatches.push(HemShadowMismatch {
                observed_at: event.recorded_at.clone(),
                event_id: Some(event.event_id.clone()),
                session_id: event.session_id.clone(),
                project_id: Some(reducer_state.project_id.clone()),
                project_path: Some((*project_path).to_string()),
                category: "missing_in_hem".to_string(),
                reducer_state: Some(reducer_state.state.as_str().to_string()),
                hem_state: None,
                confidence_delta: None,
                detail_json: Some(serde_json::json!({"reason": "no_hem_projection"}).to_string()),
            }),
        }
    }

    for (project_path, hem_state) in hem_by_path {
        mismatches.push(HemShadowMismatch {
            observed_at: event.recorded_at.clone(),
            event_id: Some(event.event_id.clone()),
            session_id: event.session_id.clone(),
            project_id: Some(hem_state.project_id.clone()),
            project_path: Some(project_path.to_string()),
            category: "extra_in_hem".to_string(),
            reducer_state: None,
            hem_state: Some(hem_state.state.as_str().to_string()),
            confidence_delta: Some((1.0 - hem_state.confidence).max(0.0)),
            detail_json: Some(
                serde_json::json!({
                    "hem_confidence": hem_state.confidence,
                    "hem_evidence_count": hem_state.evidence_count
                })
                .to_string(),
            ),
        });
    }

    mismatches
}

#[derive(Debug, Clone, Copy, Default)]
struct StableStateAgreementSample {
    samples: u64,
    matches: u64,
}

fn compute_stable_state_agreement(
    observed_at: &str,
    reducer_states: &[ProjectState],
    hem_states: &[HemProjectState],
) -> StableStateAgreementSample {
    let Some(observed_at) = parse_rfc3339(observed_at) else {
        return StableStateAgreementSample::default();
    };

    let mut hem_by_path: HashMap<&str, &HemProjectState> = HashMap::new();
    for state in hem_states {
        hem_by_path.insert(state.project_path.as_str(), state);
    }

    let mut sample = StableStateAgreementSample::default();
    for reducer_state in reducer_states {
        if !is_operationally_stable_state(&reducer_state.state) {
            continue;
        }
        let Some(changed_at) = parse_rfc3339(&reducer_state.state_changed_at) else {
            continue;
        };
        let age_secs = observed_at.signed_duration_since(changed_at).num_seconds();
        if age_secs < HEM_STABLE_STATE_TRANSITION_EXCLUSION_SECS {
            continue;
        }
        sample.samples = sample.samples.saturating_add(1);
        if hem_by_path
            .get(reducer_state.project_path.as_str())
            .is_some_and(|hem_state| hem_state.state == reducer_state.state)
        {
            sample.matches = sample.matches.saturating_add(1);
        }
    }
    sample
}

fn is_operationally_stable_state(state: &crate::reducer::SessionState) -> bool {
    matches!(
        state,
        crate::reducer::SessionState::Ready | crate::reducer::SessionState::Idle
    )
}

fn mismatch_severity(category: &str) -> &'static str {
    match category {
        "state_mismatch" => "critical",
        "missing_in_hem" | "extra_in_hem" => "important",
        _ => "info",
    }
}

fn mismatch_severity_rank(category: &str) -> u8 {
    match mismatch_severity(category) {
        "critical" => 0,
        "important" => 1,
        _ => 2,
    }
}

fn select_mismatches_for_persistence<'a>(
    mismatches: &'a [HemShadowMismatch],
    limit: usize,
) -> Vec<&'a HemShadowMismatch> {
    if limit == 0 || mismatches.is_empty() {
        return Vec::new();
    }
    let mut selected = mismatches.iter().collect::<Vec<_>>();
    selected.sort_by(|left, right| {
        mismatch_severity_rank(&left.category)
            .cmp(&mismatch_severity_rank(&right.category))
            .then_with(|| left.project_path.cmp(&right.project_path))
            .then_with(|| left.category.cmp(&right.category))
            .then_with(|| left.reducer_state.cmp(&right.reducer_state))
            .then_with(|| left.hem_state.cmp(&right.hem_state))
    });
    selected.truncate(limit);
    selected
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
    is_alive: Option<bool>,
) -> crate::reducer::SessionState {
    if matches!(record.state, crate::reducer::SessionState::Ready)
        && record.ready_reason.as_deref() == Some("stop_gate")
        && is_alive == Some(true)
    {
        if let Some(stop_time) = parse_rfc3339(&record.updated_at) {
            if now.signed_duration_since(stop_time).num_seconds() <= STOP_GATE_WORKING_GRACE_SECS {
                return crate::reducer::SessionState::Working;
            }
        }
    }

    if matches!(record.state, crate::reducer::SessionState::Ready) && is_alive == Some(false) {
        return crate::reducer::SessionState::Idle;
    }

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
}

fn inactivity_fallback_policy(
    state: &crate::reducer::SessionState,
) -> Option<(crate::reducer::SessionState, InactivityFallbackGuard)> {
    match state {
        crate::reducer::SessionState::Working => Some((
            crate::reducer::SessionState::Ready,
            InactivityFallbackGuard::RequireLastEvent(&["task_completed"]),
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
    let InactivityFallbackGuard::RequireLastEvent(expected_events) = fallback_guard;
    let last_event = record.last_event.as_deref().unwrap_or_default();
    // Working auto-ready should only run after an explicit completion marker.
    // PostToolUse can occur repeatedly during an active working session and
    // causes false Ready transitions when activity is sparse.
    if !expected_events.contains(&last_event) {
        return false;
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

fn build_routing_shell_registry(shell_state: &ShellState) -> crate::are::registry::ShellRegistry {
    let mut registry = crate::are::registry::ShellRegistry::default();
    for (pid, shell) in &shell_state.shells {
        let Ok(pid) = pid.parse::<u32>() else {
            continue;
        };
        let recorded_at = parse_rfc3339(&shell.updated_at).unwrap_or_else(Utc::now);
        registry.upsert(crate::are::registry::ShellSignal {
            pid,
            proc_start: None,
            cwd: shell.cwd.clone(),
            tty: shell.tty.clone(),
            parent_app: shell.parent_app.clone(),
            tmux_session: shell.tmux_session.clone(),
            tmux_client_tty: shell.tmux_client_tty.clone(),
            tmux_pane: None,
            recorded_at,
        });
    }
    registry
}

fn normalize_workspace_id(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn metadata_proc_start(metadata: Option<&serde_json::Value>) -> Option<u64> {
    metadata
        .and_then(|value| value.get("proc_start"))
        .and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|raw| raw.parse::<u64>().ok()))
        })
}

fn metadata_tmux_pane(metadata: Option<&serde_json::Value>) -> Option<String> {
    metadata
        .and_then(|value| value.get("tmux_pane"))
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn normalize_routing_path(value: &str) -> String {
    if value == "/" {
        "/".to_string()
    } else {
        value.trim_end_matches('/').to_string()
    }
}

fn path_match_quality(project_path: &str, shell_path: &str) -> u8 {
    if project_path == shell_path {
        return 3;
    }
    if shell_path.starts_with(&(project_path.to_string() + "/"))
        || project_path.starts_with(&(shell_path.to_string() + "/"))
    {
        return 2;
    }
    0
}

fn sanitize_parent_app(value: Option<&str>) -> Option<&str> {
    value.and_then(|candidate| {
        let normalized = candidate.trim();
        if normalized.is_empty() || normalized.eq_ignore_ascii_case("unknown") {
            None
        } else {
            Some(normalized)
        }
    })
}

fn routing_age_ms(now: DateTime<Utc>, observed_at: DateTime<Utc>) -> u64 {
    now.signed_duration_since(observed_at)
        .num_milliseconds()
        .max(0) as u64
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

    fn event_base(event_id: &str, event_type: EventType, recorded_at: &str) -> EventEnvelope {
        EventEnvelope {
            event_id: event_id.to_string(),
            recorded_at: recorded_at.to_string(),
            event_type,
            session_id: Some("session-1".to_string()),
            pid: Some(1234),
            cwd: Some("/repo".to_string()),
            tool: Some("Read".to_string()),
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

    fn make_project_state(project_path: &str, state: SessionState) -> ProjectState {
        ProjectState {
            project_id: project_path.to_string(),
            workspace_id: workspace_id(project_path, project_path),
            project_path: project_path.to_string(),
            state,
            state_changed_at: "2026-02-13T12:00:00Z".to_string(),
            updated_at: "2026-02-13T12:00:00Z".to_string(),
            session_id: Some(format!("session-{}", project_path)),
            session_count: 1,
            active_count: 0,
            has_session: true,
        }
    }

    fn make_hem_project_state(project_path: &str, state: SessionState) -> HemProjectState {
        HemProjectState {
            project_id: project_path.to_string(),
            project_path: project_path.to_string(),
            state,
            confidence: 0.9,
            evidence_count: 1,
        }
    }

    #[test]
    fn routing_snapshot_uses_polled_tmux_snapshot_as_authoritative_signal() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let captured_at = Utc::now();
        state.apply_tmux_snapshot(
            crate::are::tmux_poller::TmuxSnapshot {
                captured_at,
                clients: vec![crate::are::registry::TmuxClientSignal {
                    client_tty: "/dev/ttys015".to_string(),
                    session_name: "caps".to_string(),
                    pane_current_path: Some("/repo".to_string()),
                    captured_at,
                }],
                sessions: vec![crate::are::registry::TmuxSessionSignal {
                    session_name: "caps".to_string(),
                    pane_paths: vec!["/repo".to_string()],
                    captured_at,
                }],
            },
            crate::are::tmux_poller::TmuxDiff {
                clients_added: 1,
                sessions_added: 1,
                ..Default::default()
            },
        );

        let snapshot = state
            .routing_snapshot("/repo", Some("workspace-1"))
            .expect("routing snapshot");
        assert_eq!(snapshot.status, RoutingStatus::Attached);
        assert_eq!(snapshot.reason_code, "TMUX_CLIENT_ATTACHED");
        assert_eq!(snapshot.target.kind, RoutingTargetKind::TmuxSession);
        assert_eq!(snapshot.target.value.as_deref(), Some("caps"));
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
    fn project_states_keep_compacting_after_inactive_compacting() {
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
        assert_eq!(aggregates[0].state, SessionState::Compacting);
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
    fn stop_gate_ready_state_treated_as_working_while_pid_alive() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let now = Utc::now().to_rfc3339();
        let mut record = make_record("session-stop-gate", "/repo", SessionState::Ready, now);
        record.pid = std::process::id();
        record.last_event = Some("stop".to_string());
        record.ready_reason = Some("stop_gate".to_string());
        state.db.upsert_session(&record).expect("insert session");

        let aggregates = state.project_states_snapshot().expect("project states");
        assert_eq!(aggregates.len(), 1);
        assert_eq!(aggregates[0].state, SessionState::Working);
    }

    #[test]
    fn stop_gate_ready_state_reverts_to_ready_after_grace() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let old_stop =
            (Utc::now() - Duration::seconds(STOP_GATE_WORKING_GRACE_SECS + 5)).to_rfc3339();
        let mut record = make_record(
            "session-stop-gate-old",
            "/repo",
            SessionState::Ready,
            old_stop,
        );
        record.pid = std::process::id();
        record.last_event = Some("stop".to_string());
        record.ready_reason = Some("stop_gate".to_string());
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
            pid: Some(std::process::id()),
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
    fn project_states_demote_ready_to_idle_when_pid_not_alive() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let mut record = make_record(
            "session-dead-ready",
            "/Users/petepetrash/Code/pete-2025",
            SessionState::Ready,
            Utc::now().to_rfc3339(),
        );
        record.pid = 999_999;
        state.db.upsert_session(&record).expect("insert session");

        let projects = state.project_states_snapshot().expect("project states");
        assert_eq!(projects.len(), 1);
        assert_eq!(
            projects[0].project_path,
            "/Users/petepetrash/Code/pete-2025"
        );
        assert_eq!(projects[0].state, SessionState::Idle);
        assert!(!projects[0].has_session);
    }

    #[test]
    fn project_states_keep_ready_when_pid_unknown() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let record = make_record(
            "session-ready-unknown-pid",
            "/Users/petepetrash/Code/unknown-pid",
            SessionState::Ready,
            Utc::now().to_rfc3339(),
        );
        state.db.upsert_session(&record).expect("insert session");

        let projects = state.project_states_snapshot().expect("project states");
        assert_eq!(projects.len(), 1);
        assert_eq!(
            projects[0].project_path,
            "/Users/petepetrash/Code/unknown-pid"
        );
        assert_eq!(projects[0].state, SessionState::Ready);
        assert!(projects[0].has_session);
    }

    #[test]
    fn project_states_keep_working_when_pid_unknown() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let record = make_record(
            "session-working-unknown-pid",
            "/Users/petepetrash/Code/unknown-pid-working",
            SessionState::Working,
            Utc::now().to_rfc3339(),
        );
        state.db.upsert_session(&record).expect("insert session");

        let projects = state.project_states_snapshot().expect("project states");
        assert_eq!(projects.len(), 1);
        assert_eq!(
            projects[0].project_path,
            "/Users/petepetrash/Code/unknown-pid-working"
        );
        assert_eq!(projects[0].state, SessionState::Working);
        assert!(projects[0].has_session);
    }

    #[test]
    fn startup_repairs_dead_ready_sessions_to_idle_in_store() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let mut record = make_record(
            "session-dead-ready-startup",
            "/Users/petepetrash/Code/pete-2025",
            SessionState::Ready,
            Utc::now().to_rfc3339(),
        );
        record.pid = 999_999;
        db.upsert_session(&record).expect("insert session");

        let state = SharedState::new(db);
        let sessions = state.db.list_sessions().expect("list sessions");
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].state, SessionState::Idle);
        assert_eq!(
            sessions[0].last_event.as_deref(),
            Some("dead_pid_reconcile_startup")
        );

        let metrics = state.dead_session_reconcile_snapshot();
        let startup = metrics.get("startup").expect("startup metrics");
        assert_eq!(startup.runs, 1);
        assert_eq!(startup.repaired_sessions, 1);
        assert!(startup.last_run_at.is_some());
        assert!(startup.last_repair_at.is_some());
    }

    #[test]
    fn periodic_reconcile_demotes_dead_working_sessions_to_idle() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let mut record = make_record(
            "session-dead-working-periodic",
            "/Users/petepetrash/Code/pete-2025",
            SessionState::Working,
            Utc::now().to_rfc3339(),
        );
        record.pid = 999_999;
        record.tools_in_flight = 2;
        state.db.upsert_session(&record).expect("insert session");

        let repaired = state
            .reconcile_dead_non_idle_sessions("periodic")
            .expect("reconcile");
        assert_eq!(repaired, 1);

        let sessions = state.db.list_sessions().expect("list sessions");
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].state, SessionState::Idle);
        assert_eq!(
            sessions[0].last_event.as_deref(),
            Some("dead_pid_reconcile_periodic")
        );
        assert_eq!(sessions[0].tools_in_flight, 0);

        let metrics = state.dead_session_reconcile_snapshot();
        let startup = metrics.get("startup").expect("startup metrics");
        assert_eq!(startup.runs, 1);
        let periodic = metrics.get("periodic").expect("periodic metrics");
        assert_eq!(periodic.runs, 1);
        assert_eq!(periodic.repaired_sessions, 1);
        assert!(periodic.last_run_at.is_some());
        assert!(periodic.last_repair_at.is_some());
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

    #[test]
    fn update_from_event_does_not_reapply_duplicate_event_id() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let start = event_base("evt-start", EventType::SessionStart, "2026-02-13T12:00:00Z");
        let pre_tool = event_base("evt-pretool", EventType::PreToolUse, "2026-02-13T12:00:01Z");

        state.update_from_event(&start);
        state.update_from_event(&pre_tool);
        state.update_from_event(&pre_tool);

        let session = state
            .db
            .get_session("session-1")
            .expect("query session")
            .expect("session exists");
        assert_eq!(session.tools_in_flight, 1);

        let events = state.db.list_events().expect("list events");
        assert_eq!(events.len(), 2);
    }

    #[test]
    fn project_states_snapshot_is_sorted_by_project_path() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new(db);

        let now = Utc::now().to_rfc3339();
        let z_record = make_record(
            "session-z",
            "/Users/petepetrash/Code/zeta",
            SessionState::Ready,
            now.clone(),
        );
        let a_record = make_record(
            "session-a",
            "/Users/petepetrash/Code/alpha",
            SessionState::Ready,
            now,
        );
        state.db.upsert_session(&z_record).expect("insert z");
        state.db.upsert_session(&a_record).expect("insert a");

        let projects = state.project_states_snapshot().expect("project states");
        let project_paths: Vec<String> = projects
            .into_iter()
            .map(|project| project.project_path)
            .collect();
        assert_eq!(
            project_paths,
            vec![
                "/Users/petepetrash/Code/alpha".to_string(),
                "/Users/petepetrash/Code/zeta".to_string()
            ]
        );
    }

    #[test]
    fn project_states_snapshot_uses_hem_when_primary_mode_enabled() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let mut hem_config = crate::hem::HemRuntimeConfig::default();
        hem_config.engine.enabled = true;
        hem_config.engine.mode = crate::hem::HemMode::Primary;
        hem_config.source_reliability.hook_event = 0.20;
        hem_config
            .weights
            .session_to_project
            .project_boundary_from_file_path = 0.0;
        hem_config
            .weights
            .session_to_project
            .project_boundary_from_cwd = 0.0;
        hem_config.weights.session_to_project.recent_tool_activity = 0.0;
        hem_config.weights.session_to_project.notification_signal = 0.0;
        hem_config.weights.shell_to_project.exact_path_match = 0.0;
        hem_config.weights.shell_to_project.parent_path_match = 1.0;
        hem_config.weights.shell_to_project.terminal_focus_signal = 1.0;
        hem_config.weights.shell_to_project.tmux_client_signal = 0.0;
        hem_config.thresholds.working_min_confidence = 0.30;

        let state = SharedState::new_with_hem_config(db, hem_config);
        let now = Utc::now().to_rfc3339();
        let mut record = make_record(
            "session-primary-hem",
            "/Users/petepetrash/Code/project-a",
            SessionState::Working,
            now,
        );
        record.cwd = "/Users/petepetrash/Code/project-a/subdir".to_string();
        state.db.upsert_session(&record).expect("insert session");

        let projects = state.project_states_snapshot().expect("project states");
        assert_eq!(projects.len(), 1);
        assert_eq!(
            projects[0].project_path,
            "/Users/petepetrash/Code/project-a/subdir"
        );
        assert_eq!(projects[0].state, SessionState::Working);
    }

    #[test]
    fn hem_shadow_metrics_track_event_evaluation_when_enabled() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let mut hem_config = crate::hem::HemRuntimeConfig::default();
        hem_config.engine.enabled = true;
        hem_config.engine.mode = crate::hem::HemMode::Shadow;

        let state = SharedState::new_with_hem_config(db, hem_config);
        let now = Utc::now().to_rfc3339();
        let record = make_record(
            "session-metrics",
            "/Users/petepetrash/Code/metrics",
            SessionState::Working,
            now.clone(),
        );
        state.db.upsert_session(&record).expect("insert session");

        let mut event = event_base("evt-hem-shadow", EventType::TaskCompleted, &now);
        event.session_id = Some("session-metrics".to_string());
        event.cwd = Some("/Users/petepetrash/Code/metrics".to_string());
        event.pid = Some(std::process::id());
        state.update_from_event(&event);

        let metrics = state.hem_shadow_metrics_snapshot();
        assert!(metrics.enabled);
        assert_eq!(metrics.mode, "shadow");
        assert_eq!(metrics.events_evaluated, 1);
        assert!(metrics.projects_evaluated >= 1);
        assert_eq!(metrics.mismatches_total, 0);
        assert_eq!(metrics.stable_state_samples, 0);
        assert_eq!(metrics.stable_state_matches, 0);
        assert!((metrics.stable_state_agreement_rate - 0.0).abs() < f64::EPSILON);
        assert!(!metrics.stable_state_agreement_gate_met);
        assert!(
            (metrics.stable_state_agreement_gate_target - HEM_STABLE_STATE_AGREEMENT_GATE_TARGET)
                .abs()
                < f64::EPSILON
        );
        assert!(metrics.shadow_gate_ready);
        assert!((metrics.blocking_mismatch_rate - 0.0).abs() < f64::EPSILON);
        assert!(metrics.last_blocking_mismatch_at.is_none());
        assert!(metrics.last_evaluated_at.is_some());
        assert!(metrics.last_mismatch_at.is_none());
    }

    #[test]
    fn hem_shadow_skips_non_transition_events_for_evaluation() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let mut hem_config = crate::hem::HemRuntimeConfig::default();
        hem_config.engine.enabled = true;
        hem_config.engine.mode = crate::hem::HemMode::Shadow;

        let state = SharedState::new_with_hem_config(db, hem_config);
        let now = Utc::now().to_rfc3339();
        let record = make_record(
            "session-no-eval",
            "/Users/petepetrash/Code/no-eval",
            SessionState::Working,
            now.clone(),
        );
        state.db.upsert_session(&record).expect("insert session");

        let mut event = event_base("evt-no-eval", EventType::SessionStart, &now);
        event.session_id = Some("session-no-eval".to_string());
        event.cwd = Some("/Users/petepetrash/Code/no-eval".to_string());
        event.pid = Some(std::process::id());
        state.update_from_event(&event);

        let mut event = event_base("evt-no-eval-2", EventType::PostToolUse, &now);
        event.session_id = Some("session-no-eval".to_string());
        event.cwd = Some("/Users/petepetrash/Code/no-eval".to_string());
        event.pid = Some(std::process::id());
        state.update_from_event(&event);

        let metrics = state.hem_shadow_metrics_snapshot();
        assert_eq!(metrics.events_evaluated, 0);
    }

    #[test]
    fn hem_shadow_metrics_include_capability_status_and_penalty() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let mut hem_config = crate::hem::HemRuntimeConfig::default();
        hem_config.engine.enabled = true;
        hem_config.engine.mode = crate::hem::HemMode::Shadow;
        hem_config.capabilities.notification_matcher_support = true;
        hem_config.capability_detection.strategy =
            crate::hem::HemCapabilityDetectionStrategy::RuntimeHandshake;
        hem_config.capability_detection.misdeclared_penalty = 0.8;

        let state = SharedState::new_with_hem_config(db, hem_config);
        let now = Utc::now().to_rfc3339();
        let record = make_record(
            "session-capability-status",
            "/Users/petepetrash/Code/capability-status",
            SessionState::Working,
            now.clone(),
        );
        state.db.upsert_session(&record).expect("insert session");

        let mut event = event_base("evt-capability-status", EventType::TaskCompleted, &now);
        event.session_id = Some("session-capability-status".to_string());
        event.cwd = Some("/Users/petepetrash/Code/capability-status".to_string());
        event.pid = Some(std::process::id());
        event.metadata = Some(serde_json::json!({
            "capabilities": {
                "notification_matcher_support": false
            }
        }));
        state.update_from_event(&event);

        let metrics = state.hem_shadow_metrics_snapshot();
        assert!(metrics.capability_status.handshake_seen);
        assert_eq!(metrics.capability_status.misdeclared_count, 1);
        assert_eq!(metrics.capability_status.unknown_count, 0);
        assert_eq!(metrics.capability_status.warning_count, 1);
        assert!(metrics.capability_status.confidence_penalty_factor < 1.0);
    }

    #[test]
    fn hem_shadow_mismatch_taxonomy_covers_state_missing_and_extra_cases() {
        let event = event_base(
            "evt-shadow-taxonomy",
            EventType::PostToolUse,
            "2026-02-13T12:00:00Z",
        );
        let reducer = vec![
            make_project_state("/Users/petepetrash/Code/alpha", SessionState::Working),
            make_project_state("/Users/petepetrash/Code/beta", SessionState::Ready),
        ];
        let hem = vec![
            make_hem_project_state("/Users/petepetrash/Code/alpha", SessionState::Ready),
            make_hem_project_state("/Users/petepetrash/Code/gamma", SessionState::Idle),
        ];

        let mut categories = build_hem_shadow_mismatches(&event, &reducer, &hem)
            .into_iter()
            .map(|mismatch| mismatch.category)
            .collect::<Vec<_>>();
        categories.sort();
        assert_eq!(
            categories,
            vec![
                "extra_in_hem".to_string(),
                "missing_in_hem".to_string(),
                "state_mismatch".to_string()
            ]
        );
    }

    #[test]
    fn hem_shadow_persists_state_mismatch_rows_and_metrics() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let mut hem_config = crate::hem::HemRuntimeConfig::default();
        hem_config.engine.enabled = true;
        hem_config.engine.mode = crate::hem::HemMode::Shadow;
        let state = SharedState::new_with_hem_config(db, hem_config);

        let stale = (Utc::now() - Duration::seconds(SESSION_AUTO_READY_SECS + 5)).to_rfc3339();
        let mut record = make_record(
            "session-shadow-mismatch",
            "/Users/petepetrash/Code/shadow-mismatch",
            SessionState::Working,
            stale.clone(),
        );
        record.last_activity_at = Some(stale);
        record.last_event = Some("task_completed".to_string());
        record.tools_in_flight = 0;
        state.db.upsert_session(&record).expect("insert session");

        let now = Utc::now().to_rfc3339();
        let mut shell = event_base("evt-shadow-mismatch", EventType::ShellCwd, &now);
        shell.session_id = Some("session-shadow-mismatch".to_string());
        shell.pid = Some(4242);
        shell.cwd = Some("/Users/petepetrash/Code/shadow-mismatch".to_string());
        shell.tty = Some("/dev/ttys4242".to_string());
        shell.tool = None;
        state.update_from_event(&shell);

        let metrics = state.hem_shadow_metrics_snapshot();
        assert_eq!(metrics.mismatches_total, 1);
        assert_eq!(
            metrics
                .mismatches_by_category
                .get("state_mismatch")
                .copied()
                .unwrap_or(0),
            1
        );
        assert_eq!(
            metrics
                .mismatches_by_severity
                .get("critical")
                .copied()
                .unwrap_or(0),
            1
        );
        assert_eq!(metrics.gate_critical_mismatches, 1);
        assert_eq!(metrics.gate_important_mismatches, 0);
        assert_eq!(metrics.gate_blocking_mismatches, 1);
        assert!(!metrics.shadow_gate_ready);
        assert!((metrics.blocking_mismatch_rate - 1.0).abs() < f64::EPSILON);
        assert_eq!(metrics.stable_state_samples, 1);
        assert_eq!(metrics.stable_state_matches, 0);
        assert!((metrics.stable_state_agreement_rate - 0.0).abs() < f64::EPSILON);
        assert!(!metrics.stable_state_agreement_gate_met);
        assert_eq!(metrics.last_blocking_mismatch_at, Some(now));
        assert!(metrics.last_mismatch_at.is_some());
        let persisted = state
            .db
            .count_hem_shadow_mismatches_by_category("state_mismatch")
            .expect("count mismatches");
        assert_eq!(persisted, 1);
    }

    #[test]
    fn hem_shadow_gate_counters_include_important_mismatches() {
        let mismatches = vec![
            HemShadowMismatch {
                observed_at: "2026-02-13T12:00:00Z".to_string(),
                event_id: Some("evt-1".to_string()),
                session_id: Some("session-1".to_string()),
                project_id: Some("project-1".to_string()),
                project_path: Some("/Users/petepetrash/Code/project-1".to_string()),
                category: "missing_in_hem".to_string(),
                reducer_state: Some("working".to_string()),
                hem_state: None,
                confidence_delta: None,
                detail_json: None,
            },
            HemShadowMismatch {
                observed_at: "2026-02-13T12:00:00Z".to_string(),
                event_id: Some("evt-1".to_string()),
                session_id: Some("session-2".to_string()),
                project_id: Some("project-2".to_string()),
                project_path: Some("/Users/petepetrash/Code/project-2".to_string()),
                category: "extra_in_hem".to_string(),
                reducer_state: None,
                hem_state: Some("idle".to_string()),
                confidence_delta: None,
                detail_json: None,
            },
        ];
        // Build a minimal SharedState to exercise the same production metrics path.
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let state = SharedState::new_with_hem_config(db, crate::hem::HemRuntimeConfig::default());
        state.record_hem_shadow_metrics(
            "2026-02-13T12:00:00Z",
            2,
            &mismatches,
            StableStateAgreementSample::default(),
            HemCapabilityStatus::default(),
        );

        let snapshot = state.hem_shadow_metrics_snapshot();
        assert_eq!(snapshot.gate_critical_mismatches, 0);
        assert_eq!(snapshot.gate_important_mismatches, 2);
        assert_eq!(snapshot.gate_blocking_mismatches, 2);
        assert!(!snapshot.shadow_gate_ready);
        assert!((snapshot.blocking_mismatch_rate - 1.0).abs() < f64::EPSILON);
        assert_eq!(snapshot.stable_state_samples, 0);
        assert_eq!(snapshot.stable_state_matches, 0);
        assert!((snapshot.stable_state_agreement_rate - 0.0).abs() < f64::EPSILON);
        assert!(!snapshot.stable_state_agreement_gate_met);
        assert_eq!(
            snapshot.last_blocking_mismatch_at,
            Some("2026-02-13T12:00:00Z".to_string())
        );
    }

    #[test]
    fn mismatch_persistence_selection_prioritizes_severity_and_is_deterministic() {
        let mismatches = vec![
            HemShadowMismatch {
                observed_at: "2026-02-13T12:00:00Z".to_string(),
                event_id: Some("evt-1".to_string()),
                session_id: Some("session-1".to_string()),
                project_id: Some("project-c".to_string()),
                project_path: Some("/c".to_string()),
                category: "missing_in_hem".to_string(),
                reducer_state: Some("working".to_string()),
                hem_state: None,
                confidence_delta: None,
                detail_json: None,
            },
            HemShadowMismatch {
                observed_at: "2026-02-13T12:00:00Z".to_string(),
                event_id: Some("evt-1".to_string()),
                session_id: Some("session-2".to_string()),
                project_id: Some("project-a".to_string()),
                project_path: Some("/a".to_string()),
                category: "state_mismatch".to_string(),
                reducer_state: Some("ready".to_string()),
                hem_state: Some("idle".to_string()),
                confidence_delta: Some(0.3),
                detail_json: None,
            },
            HemShadowMismatch {
                observed_at: "2026-02-13T12:00:00Z".to_string(),
                event_id: Some("evt-1".to_string()),
                session_id: Some("session-3".to_string()),
                project_id: Some("project-b".to_string()),
                project_path: Some("/b".to_string()),
                category: "state_mismatch".to_string(),
                reducer_state: Some("ready".to_string()),
                hem_state: Some("idle".to_string()),
                confidence_delta: Some(0.3),
                detail_json: None,
            },
            HemShadowMismatch {
                observed_at: "2026-02-13T12:00:00Z".to_string(),
                event_id: Some("evt-1".to_string()),
                session_id: Some("session-4".to_string()),
                project_id: Some("project-z".to_string()),
                project_path: Some("/z".to_string()),
                category: "extra_in_hem".to_string(),
                reducer_state: None,
                hem_state: Some("idle".to_string()),
                confidence_delta: Some(0.2),
                detail_json: None,
            },
        ];

        let selected = select_mismatches_for_persistence(&mismatches, 3);
        let selected_paths = selected
            .iter()
            .map(|mismatch| mismatch.project_path.clone().unwrap_or_default())
            .collect::<Vec<_>>();
        assert_eq!(selected.len(), 3);
        assert_eq!(selected[0].category, "state_mismatch");
        assert_eq!(selected[1].category, "state_mismatch");
        assert_eq!(
            selected_paths,
            vec!["/a".to_string(), "/b".to_string(), "/c".to_string()]
        );
    }

    #[test]
    fn stable_state_agreement_excludes_recent_transitions_and_non_stable_states() {
        let reducer = vec![
            ProjectState {
                project_id: "alpha".to_string(),
                workspace_id: "alpha".to_string(),
                project_path: "/alpha".to_string(),
                state: SessionState::Ready,
                state_changed_at: "2026-02-13T11:59:30Z".to_string(),
                updated_at: "2026-02-13T11:59:30Z".to_string(),
                session_id: Some("s-alpha".to_string()),
                session_count: 1,
                active_count: 0,
                has_session: true,
            },
            ProjectState {
                project_id: "beta".to_string(),
                workspace_id: "beta".to_string(),
                project_path: "/beta".to_string(),
                state: SessionState::Ready,
                state_changed_at: "2026-02-13T11:59:50Z".to_string(),
                updated_at: "2026-02-13T11:59:50Z".to_string(),
                session_id: Some("s-beta".to_string()),
                session_count: 1,
                active_count: 0,
                has_session: true,
            },
            ProjectState {
                project_id: "gamma".to_string(),
                workspace_id: "gamma".to_string(),
                project_path: "/gamma".to_string(),
                state: SessionState::Working,
                state_changed_at: "2026-02-13T11:58:00Z".to_string(),
                updated_at: "2026-02-13T11:58:00Z".to_string(),
                session_id: Some("s-gamma".to_string()),
                session_count: 1,
                active_count: 1,
                has_session: true,
            },
        ];
        let hem = vec![
            make_hem_project_state("/alpha", SessionState::Ready),
            make_hem_project_state("/beta", SessionState::Ready),
            make_hem_project_state("/gamma", SessionState::Working),
        ];

        let sample = compute_stable_state_agreement("2026-02-13T12:00:00Z", &reducer, &hem);
        assert_eq!(sample.samples, 1);
        assert_eq!(sample.matches, 1);
    }

    #[test]
    fn stable_state_agreement_counts_idle_ready_mismatch_as_disagreement() {
        let reducer = vec![ProjectState {
            project_id: "alpha".to_string(),
            workspace_id: "alpha".to_string(),
            project_path: "/alpha".to_string(),
            state: SessionState::Idle,
            state_changed_at: "2026-02-13T11:59:00Z".to_string(),
            updated_at: "2026-02-13T11:59:00Z".to_string(),
            session_id: Some("s-alpha".to_string()),
            session_count: 1,
            active_count: 0,
            has_session: false,
        }];
        let hem = vec![make_hem_project_state("/alpha", SessionState::Ready)];

        let sample = compute_stable_state_agreement("2026-02-13T12:00:00Z", &reducer, &hem);
        assert_eq!(sample.samples, 1);
        assert_eq!(sample.matches, 0);
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
