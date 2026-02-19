//! SQLite persistence for capacitor-daemon.
//!
//! This is the single-writer store backing the daemon. We keep the schema
//! intentionally small in Phase 3: an append-only events table and a
//! materialized shell_state table for fast reads.

use capacitor_daemon_protocol::{EventEnvelope, EventType};
use chrono::{DateTime, Duration, Utc};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use std::collections::HashMap;
use std::path::PathBuf;

use crate::activity::ActivityEntry;
use crate::are::metrics::PersistedRoutingRolloutState;
use crate::process::get_process_start_time;
use crate::reducer::{SessionRecord, SessionState};
use crate::state::{ProcessLivenessRow, ShellEntry, ShellState};

pub struct Db {
    path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct TombstoneRow {
    pub session_id: String,
    pub created_at: String,
    pub expires_at: String,
}

#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct HemShadowMismatch {
    pub observed_at: String,
    pub event_id: Option<String>,
    pub session_id: Option<String>,
    pub project_id: Option<String>,
    pub project_path: Option<String>,
    pub category: String,
    pub reducer_state: Option<String>,
    pub hem_state: Option<String>,
    pub confidence_delta: Option<f64>,
    pub detail_json: Option<String>,
}

impl Db {
    pub fn new(path: PathBuf) -> Result<Self, String> {
        let db = Self { path };
        db.init_schema()?;
        Ok(db)
    }

    #[cfg(test)]
    pub fn insert_event(&self, event: &EventEnvelope) -> Result<bool, String> {
        self.insert_event_with_rowid(event)
            .map(|rowid| rowid.is_some())
    }

    pub fn insert_event_with_rowid(&self, event: &EventEnvelope) -> Result<Option<i64>, String> {
        self.with_connection(|conn| {
            let payload = serde_json::to_string(event)
                .map_err(|err| format!("Failed to serialize event payload: {}", err))?;
            let event_type = serde_json::to_string(&event.event_type)
                .unwrap_or_else(|_| "unknown".to_string())
                .trim_matches('"')
                .to_string();

            let rows_affected = conn
                .execute(
                    "INSERT INTO events (id, recorded_at, event_type, session_id, pid, payload)\
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)\
                 ON CONFLICT(id) DO NOTHING",
                    params![
                        event.event_id,
                        event.recorded_at,
                        event_type,
                        event.session_id,
                        event.pid,
                        payload
                    ],
                )
                .map_err(|err| format!("Failed to insert event: {}", err))?;

            if rows_affected > 0 {
                Ok(Some(conn.last_insert_rowid()))
            } else {
                Ok(None)
            }
        })
    }

    #[cfg(test)]
    pub fn list_events(&self) -> Result<Vec<EventEnvelope>, String> {
        self.with_connection(|conn| {
            let mut stmt = conn
                .prepare(
                    "SELECT payload FROM events \
                     ORDER BY julianday(recorded_at) ASC, id ASC",
                )
                .map_err(|err| format!("Failed to prepare events query: {}", err))?;

            let rows = stmt
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|err| format!("Failed to read event rows: {}", err))?;

            let mut events = Vec::new();
            for row in rows {
                let payload = row.map_err(|err| format!("Failed to decode event row: {}", err))?;
                let event: EventEnvelope = serde_json::from_str(&payload)
                    .map_err(|err| format!("Failed to parse event payload: {}", err))?;
                events.push(event);
            }

            Ok(events)
        })
    }

    #[cfg(test)]
    pub fn list_session_affecting_events_since(
        &self,
        since: Option<DateTime<Utc>>,
    ) -> Result<Vec<EventEnvelope>, String> {
        self.with_connection(|conn| {
            let since_param = since.map(|value| value.to_rfc3339());
            let mut stmt = conn
                .prepare(
                    "SELECT payload FROM events \
                     WHERE session_id IS NOT NULL \
                       AND event_type NOT IN ('shell_cwd', 'subagent_start', 'subagent_stop', 'teammate_idle') \
                       AND (?1 IS NULL OR julianday(recorded_at) >= julianday(?1)) \
                     ORDER BY julianday(recorded_at) ASC, id ASC",
                )
                .map_err(|err| {
                    format!(
                        "Failed to prepare session-affecting events query: {}",
                        err
                    )
                })?;

            let rows = stmt
                .query_map(params![since_param], |row| row.get::<_, String>(0))
                .map_err(|err| {
                    format!("Failed to read session-affecting event rows: {}", err)
                })?;

            let mut events = Vec::new();
            for row in rows {
                let payload = row
                    .map_err(|err| format!("Failed to decode session event row: {}", err))?;
                let event: EventEnvelope = serde_json::from_str(&payload)
                    .map_err(|err| format!("Failed to parse session event payload: {}", err))?;
                events.push(event);
            }

            Ok(events)
        })
    }

    pub fn list_session_affecting_events_after_rowid(
        &self,
        after_rowid: Option<i64>,
    ) -> Result<Vec<(i64, EventEnvelope)>, String> {
        self.with_connection(|conn| {
            let mut stmt = conn
                .prepare(
                    "SELECT rowid, payload FROM events \
                     WHERE session_id IS NOT NULL \
                       AND event_type NOT IN ('shell_cwd', 'subagent_start', 'subagent_stop', 'teammate_idle') \
                       AND (?1 IS NULL OR rowid > ?1) \
                     ORDER BY rowid ASC",
                )
                .map_err(|err| {
                    format!(
                        "Failed to prepare session-affecting events by rowid query: {}",
                        err
                    )
                })?;

            let rows = stmt
                .query_map(params![after_rowid], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                })
                .map_err(|err| {
                    format!(
                        "Failed to read session-affecting event rows by rowid: {}",
                        err
                    )
                })?;

            let mut events = Vec::new();
            for row in rows {
                let (rowid, payload) = row.map_err(|err| {
                    format!("Failed to decode session event row by rowid: {}", err)
                })?;
                let event: EventEnvelope = serde_json::from_str(&payload)
                    .map_err(|err| format!("Failed to parse session event payload: {}", err))?;
                events.push((rowid, event));
            }
            Ok(events)
        })
    }

    pub fn max_event_rowid(&self) -> Result<Option<i64>, String> {
        self.with_connection(|conn| {
            conn.query_row("SELECT MAX(rowid) FROM events", [], |row| {
                row.get::<_, Option<i64>>(0)
            })
            .map_err(|err| format!("Failed to read max event rowid: {}", err))
        })
    }

    pub fn session_affecting_rowid_at_or_before(
        &self,
        timestamp: DateTime<Utc>,
    ) -> Result<Option<i64>, String> {
        self.with_connection(|conn| {
            conn.query_row(
                "SELECT rowid FROM events \
                 WHERE session_id IS NOT NULL \
                   AND event_type NOT IN ('shell_cwd', 'subagent_start', 'subagent_stop', 'teammate_idle') \
                   AND julianday(recorded_at) <= julianday(?1) \
                 ORDER BY rowid DESC LIMIT 1",
                params![timestamp.to_rfc3339()],
                |row| row.get::<_, i64>(0),
            )
            .optional()
            .map_err(|err| {
                format!(
                    "Failed to query session-affecting rowid at-or-before timestamp: {}",
                    err
                )
            })
        })
    }

    pub fn last_applied_event_rowid(&self) -> Result<Option<i64>, String> {
        self.with_connection(|conn| {
            let raw: Option<String> = conn
                .query_row(
                    "SELECT value FROM daemon_meta WHERE key = 'last_applied_event_rowid'",
                    [],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|err| format!("Failed to query daemon cursor: {}", err))?;

            match raw {
                Some(value) => value.parse::<i64>().map(Some).map_err(|err| {
                    format!("Failed to parse daemon cursor value '{}': {}", value, err)
                }),
                None => Ok(None),
            }
        })
    }

    pub fn set_last_applied_event_rowid(&self, rowid: i64) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute(
                "INSERT INTO daemon_meta (key, value) VALUES ('last_applied_event_rowid', ?1) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![rowid.to_string()],
            )
            .map_err(|err| format!("Failed to persist daemon cursor: {}", err))?;
            Ok(())
        })
    }

    #[cfg(test)]
    pub fn latest_session_affecting_event_time(&self) -> Result<Option<DateTime<Utc>>, String> {
        self.with_connection(|conn| {
            let recorded_at: Option<String> = conn
                .query_row(
                    "SELECT recorded_at FROM events \
                     WHERE session_id IS NOT NULL \
                       AND event_type NOT IN ('shell_cwd', 'subagent_start', 'subagent_stop', 'teammate_idle') \
                     ORDER BY julianday(recorded_at) DESC, id DESC LIMIT 1",
                    [],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|err| {
                    format!(
                        "Failed to query latest session-affecting event timestamp: {}",
                        err
                    )
                })?;
            Ok(recorded_at.and_then(parse_rfc3339))
        })
    }

    pub fn upsert_shell_state(&self, event: &EventEnvelope) -> Result<(), String> {
        let (pid, cwd, tty) = match (event.pid, &event.cwd, &event.tty) {
            (Some(pid), Some(cwd), Some(tty)) => (pid, cwd, tty),
            _ => return Ok(()),
        };

        self.with_connection(|conn| {
            conn.execute(
                "INSERT INTO shell_state \
                    (pid, cwd, tty, parent_app, tmux_session, tmux_client_tty, updated_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) \
                 ON CONFLICT(pid) DO UPDATE SET \
                    cwd = excluded.cwd, \
                    tty = excluded.tty, \
                    parent_app = excluded.parent_app, \
                    tmux_session = excluded.tmux_session, \
                    tmux_client_tty = excluded.tmux_client_tty, \
                    updated_at = excluded.updated_at",
                params![
                    pid,
                    cwd,
                    tty,
                    event.parent_app,
                    event.tmux_session,
                    event.tmux_client_tty,
                    event.recorded_at
                ],
            )
            .map_err(|err| format!("Failed to upsert shell state: {}", err))?;

            Ok(())
        })
    }

    pub fn upsert_process_liveness(&self, event: &EventEnvelope) -> Result<(), String> {
        let pid = match event.pid {
            Some(pid) => pid,
            None => return Ok(()),
        };

        let proc_started = get_process_start_time(pid).map(|value| value as i64);

        self.with_connection(|conn| {
            conn.execute(
                "INSERT INTO process_liveness (pid, proc_started, last_seen_at) \
                 VALUES (?1, ?2, ?3) \
                 ON CONFLICT(pid) DO UPDATE SET \
                    proc_started = COALESCE(excluded.proc_started, process_liveness.proc_started), \
                    last_seen_at = excluded.last_seen_at",
                params![pid as i64, proc_started, event.recorded_at],
            )
            .map_err(|err| format!("Failed to upsert process liveness: {}", err))?;

            Ok(())
        })
    }

    pub fn get_process_liveness(&self, pid: u32) -> Result<Option<ProcessLivenessRow>, String> {
        self.with_connection(|conn| {
            conn.query_row(
                "SELECT pid, proc_started, last_seen_at FROM process_liveness WHERE pid = ?1",
                params![pid as i64],
                |row| {
                    Ok(ProcessLivenessRow {
                        pid: row.get::<_, i64>(0)? as u32,
                        proc_started: row.get::<_, Option<i64>>(1)?,
                        last_seen_at: row.get::<_, String>(2)?,
                    })
                },
            )
            .optional()
            .map_err(|err| format!("Failed to query process liveness: {}", err))
        })
    }

    pub fn upsert_tombstone(
        &self,
        session_id: &str,
        created_at: &str,
        expires_at: &str,
    ) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute(
                "INSERT INTO tombstones (session_id, created_at, expires_at) \
                 VALUES (?1, ?2, ?3) \
                 ON CONFLICT(session_id) DO UPDATE SET \
                    created_at = excluded.created_at, \
                    expires_at = excluded.expires_at",
                params![session_id, created_at, expires_at],
            )
            .map_err(|err| format!("Failed to upsert tombstone: {}", err))?;
            Ok(())
        })
    }

    pub fn get_tombstone(&self, session_id: &str) -> Result<Option<TombstoneRow>, String> {
        self.with_connection(|conn| {
            conn.query_row(
                "SELECT session_id, created_at, expires_at FROM tombstones WHERE session_id = ?1",
                params![session_id],
                |row| {
                    Ok(TombstoneRow {
                        session_id: row.get(0)?,
                        created_at: row.get(1)?,
                        expires_at: row.get(2)?,
                    })
                },
            )
            .optional()
            .map_err(|err| format!("Failed to query tombstone: {}", err))
        })
    }

    pub fn delete_tombstone(&self, session_id: &str) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute(
                "DELETE FROM tombstones WHERE session_id = ?1",
                params![session_id],
            )
            .map_err(|err| format!("Failed to delete tombstone: {}", err))?;
            Ok(())
        })
    }

    #[allow(dead_code)]
    pub fn insert_hem_shadow_mismatch(&self, mismatch: &HemShadowMismatch) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute(
                "INSERT INTO hem_shadow_mismatches \
                    (observed_at, event_id, session_id, project_id, project_path, category, reducer_state, hem_state, confidence_delta, detail_json) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    mismatch.observed_at,
                    mismatch.event_id,
                    mismatch.session_id,
                    mismatch.project_id,
                    mismatch.project_path,
                    mismatch.category,
                    mismatch.reducer_state,
                    mismatch.hem_state,
                    mismatch.confidence_delta,
                    mismatch.detail_json
                ],
            )
            .map_err(|err| format!("Failed to insert hem shadow mismatch: {}", err))?;
            Ok(())
        })
    }

    pub fn prune_hem_shadow_mismatches(&self, retention_days: i64) -> Result<usize, String> {
        let days = retention_days.max(0);
        let modifier = format!("-{} days", days);
        self.with_connection(|conn| {
            conn.execute(
                "DELETE FROM hem_shadow_mismatches \
                 WHERE julianday(observed_at) < julianday('now', ?1)",
                params![modifier],
            )
            .map_err(|err| format!("Failed to prune hem shadow mismatches: {}", err))
        })
    }

    #[cfg(test)]
    pub fn clear_tombstones(&self) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute("DELETE FROM tombstones", [])
                .map_err(|err| format!("Failed to clear tombstones: {}", err))?;
            Ok(())
        })
    }

    #[cfg(test)]
    pub fn count_hem_shadow_mismatches_by_category(&self, category: &str) -> Result<u64, String> {
        self.with_connection(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM hem_shadow_mismatches WHERE category = ?1",
                params![category],
                |row| row.get::<_, i64>(0),
            )
            .map(|count| count as u64)
            .map_err(|err| format!("Failed to count hem_shadow_mismatches by category: {}", err))
        })
    }

    pub fn upsert_session(&self, record: &SessionRecord) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute(
                "INSERT INTO sessions \
                    (session_id, pid, state, cwd, project_id, project_path, updated_at, state_changed_at, last_event, last_activity_at, tools_in_flight, ready_reason) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12) \
                 ON CONFLICT(session_id) DO UPDATE SET \
                    pid = excluded.pid, \
                    state = excluded.state, \
                    cwd = excluded.cwd, \
                    project_id = excluded.project_id, \
                    project_path = excluded.project_path, \
                    updated_at = excluded.updated_at, \
                    state_changed_at = excluded.state_changed_at, \
                    last_event = excluded.last_event, \
                    last_activity_at = excluded.last_activity_at, \
                    tools_in_flight = excluded.tools_in_flight, \
                    ready_reason = excluded.ready_reason",
                params![
                    record.session_id,
                    record.pid,
                    record.state.as_str(),
                    record.cwd,
                    record.project_id,
                    record.project_path,
                    record.updated_at,
                    record.state_changed_at,
                    record.last_event,
                    record.last_activity_at,
                    record.tools_in_flight,
                    record.ready_reason
                ],
            )
            .map_err(|err| format!("Failed to upsert session: {}", err))?;
            Ok(())
        })
    }

    pub fn get_session(&self, session_id: &str) -> Result<Option<SessionRecord>, String> {
        self.with_connection(|conn| {
            conn.query_row(
                "SELECT session_id, COALESCE(pid, 0), state, cwd, \
                        COALESCE(project_id, project_path, cwd), \
                        COALESCE(project_path, cwd), \
                        updated_at, state_changed_at, last_event, last_activity_at, \
                        COALESCE(tools_in_flight, 0), ready_reason \
                 FROM sessions WHERE session_id = ?1",
                params![session_id],
                |row| {
                    let state_raw: String = row.get(2)?;
                    let state = SessionState::from_str(&state_raw).ok_or_else(|| {
                        rusqlite::Error::FromSqlConversionFailure(
                            state_raw.len(),
                            rusqlite::types::Type::Text,
                            Box::new(std::io::Error::new(
                                std::io::ErrorKind::InvalidData,
                                format!("Unknown session state: {}", state_raw),
                            )),
                        )
                    })?;

                    Ok(SessionRecord {
                        session_id: row.get(0)?,
                        pid: row.get(1)?,
                        state,
                        cwd: row.get(3)?,
                        project_id: row.get(4)?,
                        project_path: row.get(5)?,
                        updated_at: row.get(6)?,
                        state_changed_at: row.get(7)?,
                        last_event: row.get(8)?,
                        last_activity_at: row.get(9)?,
                        tools_in_flight: row.get(10)?,
                        ready_reason: row.get(11)?,
                    })
                },
            )
            .optional()
            .map_err(|err| format!("Failed to query session: {}", err))
        })
    }

    pub fn list_sessions(&self) -> Result<Vec<SessionRecord>, String> {
        self.with_connection(|conn| {
            let mut stmt = conn
                .prepare(
                    "SELECT session_id, COALESCE(pid, 0), state, cwd, \
                            COALESCE(project_id, project_path, cwd), \
                            COALESCE(project_path, cwd), \
                            updated_at, state_changed_at, last_event, last_activity_at, \
                            COALESCE(tools_in_flight, 0), ready_reason \
                     FROM sessions ORDER BY updated_at DESC",
                )
                .map_err(|err| format!("Failed to prepare sessions query: {}", err))?;

            let rows = stmt
                .query_map([], |row| {
                    let state_raw: String = row.get(2)?;
                    let state = SessionState::from_str(&state_raw).ok_or_else(|| {
                        rusqlite::Error::FromSqlConversionFailure(
                            state_raw.len(),
                            rusqlite::types::Type::Text,
                            Box::new(std::io::Error::new(
                                std::io::ErrorKind::InvalidData,
                                format!("Unknown session state: {}", state_raw),
                            )),
                        )
                    })?;
                    Ok(SessionRecord {
                        session_id: row.get(0)?,
                        pid: row.get(1)?,
                        state,
                        cwd: row.get(3)?,
                        project_id: row.get(4)?,
                        project_path: row.get(5)?,
                        updated_at: row.get(6)?,
                        state_changed_at: row.get(7)?,
                        last_event: row.get(8)?,
                        last_activity_at: row.get(9)?,
                        tools_in_flight: row.get(10)?,
                        ready_reason: row.get(11)?,
                    })
                })
                .map_err(|err| format!("Failed to query sessions: {}", err))?;

            let mut sessions = Vec::new();
            for row in rows {
                sessions.push(row.map_err(|err| format!("Failed to decode session row: {}", err))?);
            }
            Ok(sessions)
        })
    }

    pub fn delete_session(&self, session_id: &str) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute(
                "DELETE FROM sessions WHERE session_id = ?1",
                params![session_id],
            )
            .map_err(|err| format!("Failed to delete session: {}", err))?;
            Ok(())
        })
    }

    #[cfg(test)]
    pub fn clear_sessions(&self) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute("DELETE FROM sessions", [])
                .map_err(|err| format!("Failed to clear sessions: {}", err))?;
            Ok(())
        })
    }

    pub fn has_sessions(&self) -> Result<bool, String> {
        let count = self.with_connection(|conn| {
            conn.query_row("SELECT COUNT(*) FROM sessions", [], |row| {
                row.get::<_, i64>(0)
            })
            .map_err(|err| format!("Failed to count sessions: {}", err))
        })?;
        Ok(count > 0)
    }

    pub fn latest_session_time(&self) -> Result<Option<DateTime<Utc>>, String> {
        self.with_connection(|conn| {
            let updated_at: Option<String> = conn
                .query_row(
                    "SELECT updated_at FROM sessions ORDER BY updated_at DESC, session_id DESC LIMIT 1",
                    [],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|err| format!("Failed to query latest session timestamp: {}", err))?;
            Ok(updated_at.and_then(parse_rfc3339))
        })
    }

    pub fn insert_activity(&self, entry: &ActivityEntry) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute(
                "INSERT INTO activity (session_id, project_path, file_path, tool_name, recorded_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    entry.session_id,
                    entry.project_path,
                    entry.file_path,
                    entry.tool_name,
                    entry.recorded_at
                ],
            )
            .map_err(|err| format!("Failed to insert activity: {}", err))?;
            Ok(())
        })
    }

    pub fn list_activity(
        &self,
        session_id: &str,
        limit: usize,
    ) -> Result<Vec<ActivityEntry>, String> {
        self.with_connection(|conn| {
            let mut stmt = conn
                .prepare(
                    "SELECT session_id, project_path, file_path, tool_name, recorded_at \
                     FROM activity WHERE session_id = ?1 \
                     ORDER BY recorded_at DESC \
                     LIMIT ?2",
                )
                .map_err(|err| format!("Failed to prepare activity query: {}", err))?;

            let rows = stmt
                .query_map(params![session_id, limit as i64], |row| {
                    Ok(ActivityEntry {
                        session_id: row.get(0)?,
                        project_path: row.get(1)?,
                        file_path: row.get(2)?,
                        tool_name: row.get(3)?,
                        recorded_at: row.get(4)?,
                    })
                })
                .map_err(|err| format!("Failed to query activity rows: {}", err))?;

            let mut entries = Vec::new();
            for row in rows {
                entries.push(row.map_err(|err| format!("Failed to decode activity row: {}", err))?);
            }
            Ok(entries)
        })
    }

    pub fn list_activity_all(&self, limit: usize) -> Result<Vec<ActivityEntry>, String> {
        self.with_connection(|conn| {
            let mut stmt = conn
                .prepare(
                    "SELECT session_id, project_path, file_path, tool_name, recorded_at \
                     FROM activity ORDER BY recorded_at DESC LIMIT ?1",
                )
                .map_err(|err| format!("Failed to prepare activity query: {}", err))?;

            let rows = stmt
                .query_map(params![limit as i64], |row| {
                    Ok(ActivityEntry {
                        session_id: row.get(0)?,
                        project_path: row.get(1)?,
                        file_path: row.get(2)?,
                        tool_name: row.get(3)?,
                        recorded_at: row.get(4)?,
                    })
                })
                .map_err(|err| format!("Failed to query activity rows: {}", err))?;

            let mut entries = Vec::new();
            for row in rows {
                entries.push(row.map_err(|err| format!("Failed to decode activity row: {}", err))?);
            }
            Ok(entries)
        })
    }

    pub fn list_tombstones(&self) -> Result<Vec<TombstoneRow>, String> {
        self.with_connection(|conn| {
            let mut stmt = conn
                .prepare(
                    "SELECT session_id, created_at, expires_at FROM tombstones ORDER BY created_at DESC",
                )
                .map_err(|err| format!("Failed to prepare tombstones query: {}", err))?;

            let rows = stmt
                .query_map([], |row| {
                    Ok(TombstoneRow {
                        session_id: row.get(0)?,
                        created_at: row.get(1)?,
                        expires_at: row.get(2)?,
                    })
                })
                .map_err(|err| format!("Failed to query tombstones: {}", err))?;

            let mut tombstones = Vec::new();
            for row in rows {
                tombstones
                    .push(row.map_err(|err| format!("Failed to decode tombstone row: {}", err))?);
            }
            Ok(tombstones)
        })
    }

    pub fn delete_activity_for_session(&self, session_id: &str) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute(
                "DELETE FROM activity WHERE session_id = ?1",
                params![session_id],
            )
            .map_err(|err| format!("Failed to delete activity: {}", err))?;
            Ok(())
        })
    }

    #[cfg(test)]
    pub fn clear_activity(&self) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute("DELETE FROM activity", [])
                .map_err(|err| format!("Failed to clear activity: {}", err))?;
            Ok(())
        })
    }

    pub fn ensure_process_liveness(&self) -> Result<(), String> {
        let count = self.with_connection(|conn| {
            conn.query_row("SELECT COUNT(*) FROM process_liveness", [], |row| {
                row.get::<_, i64>(0)
            })
            .map_err(|err| format!("Failed to count process_liveness rows: {}", err))
        })?;

        if count == 0 {
            self.rebuild_process_liveness_from_events()?;
        }

        Ok(())
    }

    pub fn prune_process_liveness(&self, max_age_hours: i64) -> Result<u64, String> {
        let cutoff = (Utc::now() - Duration::hours(max_age_hours)).to_rfc3339();
        self.with_connection(|conn| {
            conn.execute(
                "DELETE FROM process_liveness WHERE last_seen_at < ?1",
                params![cutoff],
            )
            .map(|count| count as u64)
            .map_err(|err| format!("Failed to prune process_liveness: {}", err))
        })
    }

    pub fn prune_stale_shells(&self, max_age_hours: i64) -> Result<u64, String> {
        let cutoff = (Utc::now() - Duration::hours(max_age_hours)).to_rfc3339();
        self.with_connection(|conn| {
            conn.execute(
                "DELETE FROM shell_state WHERE updated_at < ?1",
                params![cutoff],
            )
            .map(|count| count as u64)
            .map_err(|err| format!("Failed to prune stale shells: {}", err))
        })
    }

    pub fn delete_shells(&self, pids: &[String]) -> Result<u64, String> {
        if pids.is_empty() {
            return Ok(0);
        }
        self.with_connection(|conn| {
            let placeholders: Vec<String> = (1..=pids.len()).map(|i| format!("?{}", i)).collect();
            let sql = format!(
                "DELETE FROM shell_state WHERE pid IN ({})",
                placeholders.join(", ")
            );
            let params: Vec<&dyn rusqlite::types::ToSql> = pids
                .iter()
                .map(|p| p as &dyn rusqlite::types::ToSql)
                .collect();
            conn.execute(&sql, params.as_slice())
                .map(|count| count as u64)
                .map_err(|err| format!("Failed to delete shells: {}", err))
        })
    }

    pub fn rebuild_process_liveness_from_events(&self) -> Result<(), String> {
        self.with_connection(|conn| {
            let entries: Vec<(i64, Option<i64>, String)> = {
                let mut stmt = conn
                    .prepare(
                        "SELECT pid, MAX(recorded_at) \
                         FROM events \
                         WHERE pid IS NOT NULL \
                         GROUP BY pid",
                    )
                    .map_err(|err| format!("Failed to prepare process replay query: {}", err))?;

                let rows = stmt
                    .query_map([], |row| {
                        Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                    })
                    .map_err(|err| format!("Failed to read process replay rows: {}", err))?;

                let mut entries: Vec<(i64, Option<i64>, String)> = Vec::new();
                for row in rows {
                    let (pid, last_seen_at) =
                        row.map_err(|err| format!("Failed to decode process replay row: {}", err))?;
                    let proc_started = get_process_start_time(pid as u32).map(|value| value as i64);
                    entries.push((pid, proc_started, last_seen_at));
                }

                entries
            };

            let tx = conn
                .transaction()
                .map_err(|err| format!("Failed to start process replay transaction: {}", err))?;
            tx.execute("DELETE FROM process_liveness", [])
                .map_err(|err| format!("Failed to clear process_liveness table: {}", err))?;
            for (pid, proc_started, last_seen_at) in entries {
                tx.execute(
                    "INSERT INTO process_liveness (pid, proc_started, last_seen_at) \
                     VALUES (?1, ?2, ?3)",
                    params![pid, proc_started, last_seen_at],
                )
                .map_err(|err| format!("Failed to rebuild process_liveness table: {}", err))?;
            }
            tx.commit()
                .map_err(|err| format!("Failed to commit process replay: {}", err))?;

            Ok(())
        })
    }
    pub fn load_shell_state(&self) -> Result<ShellState, String> {
        self.with_connection(|conn| {
            let mut stmt = conn
                .prepare(
                    "SELECT pid, cwd, tty, parent_app, tmux_session, tmux_client_tty, updated_at \
                     FROM shell_state",
                )
                .map_err(|err| format!("Failed to prepare shell_state query: {}", err))?;

            let rows = stmt
                .query_map([], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        ShellEntry {
                            cwd: row.get(1)?,
                            tty: row.get(2)?,
                            parent_app: row.get(3)?,
                            tmux_session: row.get(4)?,
                            tmux_client_tty: row.get(5)?,
                            updated_at: row.get(6)?,
                        },
                    ))
                })
                .map_err(|err| format!("Failed to read shell_state rows: {}", err))?;

            let mut state = ShellState::default();
            for row in rows {
                let (pid, entry) =
                    row.map_err(|err| format!("Failed to decode shell row: {}", err))?;
                state.shells.insert(pid.to_string(), entry);
            }

            Ok(state)
        })
    }

    pub fn rebuild_shell_state_from_events(&self) -> Result<ShellState, String> {
        self.with_connection(|conn| {
            let by_pid: HashMap<i64, ShellEntry> = {
                let shell_type = serde_json::to_string(&EventType::ShellCwd)
                    .unwrap_or_else(|_| "shell_cwd".to_string())
                    .trim_matches('"')
                    .to_string();

                let mut stmt = conn
                    .prepare(
                        "SELECT payload FROM events \
                     WHERE event_type = ?1 \
                     ORDER BY rowid ASC",
                    )
                    .map_err(|err| format!("Failed to prepare events replay query: {}", err))?;

                let rows = stmt
                    .query_map(params![shell_type], |row| row.get::<_, String>(0))
                    .map_err(|err| format!("Failed to read event payloads: {}", err))?;

                let mut by_pid: HashMap<i64, ShellEntry> = HashMap::new();
                for row in rows {
                    let payload =
                        row.map_err(|err| format!("Failed to decode event payload: {}", err))?;
                    let event: EventEnvelope = match serde_json::from_str(&payload) {
                        Ok(event) => event,
                        Err(err) => {
                            tracing::warn!(
                                error = %err,
                                "Skipping malformed event payload during replay"
                            );
                            continue;
                        }
                    };

                    let (pid, cwd, tty) = match (event.pid, event.cwd.as_ref(), event.tty.as_ref())
                    {
                        (Some(pid), Some(cwd), Some(tty)) => (pid as i64, cwd, tty),
                        _ => continue,
                    };

                    let entry = ShellEntry {
                        cwd: cwd.clone(),
                        tty: tty.clone(),
                        parent_app: event.parent_app.clone(),
                        tmux_session: event.tmux_session.clone(),
                        tmux_client_tty: event.tmux_client_tty.clone(),
                        updated_at: event.recorded_at.clone(),
                    };

                    by_pid.insert(pid, entry);
                }

                by_pid
            };

            let mut state = ShellState::default();
            for (pid, entry) in &by_pid {
                state.shells.insert(pid.to_string(), entry.clone());
            }

            let tx = conn.transaction().map_err(|err| {
                format!("Failed to start shell_state replay transaction: {}", err)
            })?;
            tx.execute("DELETE FROM shell_state", [])
                .map_err(|err| format!("Failed to clear shell_state table: {}", err))?;
            for (pid, entry) in by_pid {
                tx.execute(
                    "INSERT INTO shell_state \
                        (pid, cwd, tty, parent_app, tmux_session, tmux_client_tty, updated_at) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![
                        pid,
                        entry.cwd,
                        entry.tty,
                        entry.parent_app,
                        entry.tmux_session,
                        entry.tmux_client_tty,
                        entry.updated_at
                    ],
                )
                .map_err(|err| format!("Failed to rebuild shell_state table: {}", err))?;
            }
            tx.commit()
                .map_err(|err| format!("Failed to commit shell_state replay: {}", err))?;

            Ok(state)
        })
    }

    pub fn load_routing_rollout_state(
        &self,
    ) -> Result<Option<PersistedRoutingRolloutState>, String> {
        self.with_connection(|conn| {
            conn.query_row(
                "SELECT \
                    dual_run_comparisons, \
                    legacy_vs_are_status_mismatch, \
                    legacy_vs_are_target_mismatch, \
                    first_comparison_at, \
                    last_comparison_at, \
                    last_snapshot_at \
                 FROM routing_rollout_state \
                 WHERE id = 1",
                [],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, Option<String>>(5)?,
                    ))
                },
            )
            .optional()
            .map_err(|err| format!("Failed to query routing rollout state: {}", err))
            .and_then(|row| {
                row.map(
                    |(
                        dual_run_comparisons,
                        legacy_vs_are_status_mismatch,
                        legacy_vs_are_target_mismatch,
                        first_comparison_at,
                        last_comparison_at,
                        last_snapshot_at,
                    )| {
                        Ok(PersistedRoutingRolloutState {
                            dual_run_comparisons: i64_to_u64(
                                dual_run_comparisons,
                                "dual_run_comparisons",
                            )?,
                            legacy_vs_are_status_mismatch: i64_to_u64(
                                legacy_vs_are_status_mismatch,
                                "legacy_vs_are_status_mismatch",
                            )?,
                            legacy_vs_are_target_mismatch: i64_to_u64(
                                legacy_vs_are_target_mismatch,
                                "legacy_vs_are_target_mismatch",
                            )?,
                            first_comparison_at,
                            last_comparison_at,
                            last_snapshot_at,
                        })
                    },
                )
                .transpose()
            })
        })
    }

    pub fn upsert_routing_rollout_state(
        &self,
        state: &PersistedRoutingRolloutState,
    ) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute(
                "INSERT INTO routing_rollout_state \
                    (id, dual_run_comparisons, legacy_vs_are_status_mismatch, legacy_vs_are_target_mismatch, first_comparison_at, last_comparison_at, last_snapshot_at) \
                 VALUES \
                    (1, ?1, ?2, ?3, ?4, ?5, ?6) \
                 ON CONFLICT(id) DO UPDATE SET \
                    dual_run_comparisons = excluded.dual_run_comparisons, \
                    legacy_vs_are_status_mismatch = excluded.legacy_vs_are_status_mismatch, \
                    legacy_vs_are_target_mismatch = excluded.legacy_vs_are_target_mismatch, \
                    first_comparison_at = excluded.first_comparison_at, \
                    last_comparison_at = excluded.last_comparison_at, \
                    last_snapshot_at = excluded.last_snapshot_at",
                params![
                    u64_to_i64(state.dual_run_comparisons, "dual_run_comparisons")?,
                    u64_to_i64(
                        state.legacy_vs_are_status_mismatch,
                        "legacy_vs_are_status_mismatch"
                    )?,
                    u64_to_i64(
                        state.legacy_vs_are_target_mismatch,
                        "legacy_vs_are_target_mismatch"
                    )?,
                    state.first_comparison_at,
                    state.last_comparison_at,
                    state.last_snapshot_at
                ],
            )
            .map_err(|err| format!("Failed to upsert routing rollout state: {}", err))?;
            Ok(())
        })
    }

    fn init_schema(&self) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute_batch(
                "BEGIN;
                 CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY,
                    recorded_at TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    session_id TEXT,
                    pid INTEGER,
                    payload TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS shell_state (
                    pid INTEGER PRIMARY KEY,
                    cwd TEXT NOT NULL,
                    tty TEXT NOT NULL,
                    parent_app TEXT,
                    tmux_session TEXT,
                    tmux_client_tty TEXT,
                    updated_at TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS process_liveness (
                    pid INTEGER PRIMARY KEY,
                    proc_started INTEGER,
                    last_seen_at TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS sessions (
                    session_id TEXT PRIMARY KEY,
                    pid INTEGER NOT NULL DEFAULT 0,
                    state TEXT NOT NULL,
                    cwd TEXT NOT NULL,
                    project_id TEXT,
                    project_path TEXT,
                    updated_at TEXT NOT NULL,
                    state_changed_at TEXT NOT NULL,
                    last_event TEXT,
                    last_activity_at TEXT,
                    tools_in_flight INTEGER NOT NULL DEFAULT 0,
                    ready_reason TEXT
                 );
                 CREATE TABLE IF NOT EXISTS activity (
                    session_id TEXT NOT NULL,
                    project_path TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    tool_name TEXT,
                    recorded_at TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS tombstones (
                    session_id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    expires_at TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS hem_shadow_mismatches (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    observed_at TEXT NOT NULL,
                    event_id TEXT,
                    session_id TEXT,
                    project_id TEXT,
                    project_path TEXT,
                    category TEXT NOT NULL,
                    reducer_state TEXT,
                    hem_state TEXT,
                    confidence_delta REAL,
                    detail_json TEXT
                 );
                 CREATE TABLE IF NOT EXISTS routing_rollout_state (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    dual_run_comparisons INTEGER NOT NULL,
                    legacy_vs_are_status_mismatch INTEGER NOT NULL,
                    legacy_vs_are_target_mismatch INTEGER NOT NULL,
                    first_comparison_at TEXT,
                    last_comparison_at TEXT,
                    last_snapshot_at TEXT
                 );
                 CREATE TABLE IF NOT EXISTS daemon_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                 );
                 CREATE INDEX IF NOT EXISTS idx_hem_shadow_mismatches_observed_at
                    ON hem_shadow_mismatches(observed_at);
                 CREATE INDEX IF NOT EXISTS idx_hem_shadow_mismatches_category
                    ON hem_shadow_mismatches(category);
                 COMMIT;",
            )
            .map_err(|err| format!("Failed to initialize schema: {}", err))?;
            ensure_sessions_columns(conn)?;
            Ok(())
        })
    }

    fn with_connection<T>(
        &self,
        op: impl FnOnce(&mut Connection) -> Result<T, String>,
    ) -> Result<T, String> {
        let mut conn = self.open()?;
        op(&mut conn)
    }

    fn open(&self) -> Result<Connection, String> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|err| format!("Failed to create daemon data dir: {}", err))?;
        }

        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_FULL_MUTEX;

        let conn = Connection::open_with_flags(&self.path, flags)
            .map_err(|err| format!("Failed to open sqlite db: {}", err))?;

        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|err| format!("Failed to enable WAL: {}", err))?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(|err| format!("Failed to set synchronous: {}", err))?;
        conn.pragma_update(None, "busy_timeout", 5000)
            .map_err(|err| format!("Failed to set busy_timeout: {}", err))?;

        Ok(conn)
    }
}

fn ensure_sessions_columns(conn: &Connection) -> Result<(), String> {
    let mut stmt = conn
        .prepare("PRAGMA table_info(sessions)")
        .map_err(|err| format!("Failed to read sessions schema: {}", err))?;
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|err| format!("Failed to read sessions schema rows: {}", err))?;

    let mut columns = Vec::new();
    for row in rows {
        columns.push(row.map_err(|err| format!("Failed to decode schema row: {}", err))?);
    }

    if !columns.iter().any(|name| name == "project_path") {
        conn.execute("ALTER TABLE sessions ADD COLUMN project_path TEXT", [])
            .map_err(|err| format!("Failed to add project_path column: {}", err))?;
    }

    if !columns.iter().any(|name| name == "project_id") {
        conn.execute("ALTER TABLE sessions ADD COLUMN project_id TEXT", [])
            .map_err(|err| format!("Failed to add project_id column: {}", err))?;
    }

    if !columns.iter().any(|name| name == "pid") {
        conn.execute(
            "ALTER TABLE sessions ADD COLUMN pid INTEGER NOT NULL DEFAULT 0",
            [],
        )
        .map_err(|err| format!("Failed to add pid column: {}", err))?;
    }

    if !columns.iter().any(|name| name == "last_activity_at") {
        conn.execute("ALTER TABLE sessions ADD COLUMN last_activity_at TEXT", [])
            .map_err(|err| format!("Failed to add last_activity_at column: {}", err))?;
    }

    if !columns.iter().any(|name| name == "tools_in_flight") {
        conn.execute(
            "ALTER TABLE sessions ADD COLUMN tools_in_flight INTEGER NOT NULL DEFAULT 0",
            [],
        )
        .map_err(|err| format!("Failed to add tools_in_flight column: {}", err))?;
    }

    if !columns.iter().any(|name| name == "ready_reason") {
        conn.execute("ALTER TABLE sessions ADD COLUMN ready_reason TEXT", [])
            .map_err(|err| format!("Failed to add ready_reason column: {}", err))?;
    }

    Ok(())
}

fn parse_rfc3339(value: String) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(&value)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn i64_to_u64(value: i64, field: &str) -> Result<u64, String> {
    u64::try_from(value).map_err(|_| format!("{} contains negative value {}", field, value))
}

fn u64_to_i64(value: u64, field: &str) -> Result<i64, String> {
    i64::try_from(value).map_err(|_| format!("{} overflows sqlite integer: {}", field, value))
}

#[cfg(test)]
mod tests {
    use super::*;
    use capacitor_daemon_protocol::{EventEnvelope, EventType};

    fn shell_event(
        event_id: &str,
        pid: u32,
        cwd: &str,
        tty: &str,
        recorded_at: &str,
    ) -> EventEnvelope {
        EventEnvelope {
            event_id: event_id.to_string(),
            recorded_at: recorded_at.to_string(),
            event_type: EventType::ShellCwd,
            session_id: None,
            pid: Some(pid),
            cwd: Some(cwd.to_string()),
            tool: None,
            file_path: None,
            parent_app: Some("Terminal".to_string()),
            tty: Some(tty.to_string()),
            tmux_session: None,
            tmux_client_tty: None,
            notification_type: None,
            stop_hook_active: None,
            metadata: None,
        }
    }

    fn session_event(event_id: &str, recorded_at: &str, event_type: EventType) -> EventEnvelope {
        EventEnvelope {
            event_id: event_id.to_string(),
            recorded_at: recorded_at.to_string(),
            event_type,
            session_id: Some("session-1".to_string()),
            pid: Some(1234),
            cwd: Some("/repo".to_string()),
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
    fn rebuilds_shell_state_from_events() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        db.insert_event(&shell_event(
            "evt-1",
            123,
            "/repo",
            "/dev/ttys001",
            "2026-01-30T00:00:00Z",
        ))
        .expect("insert evt-1");
        db.insert_event(&shell_event(
            "evt-2",
            123,
            "/repo/app",
            "/dev/ttys001",
            "2026-01-30T00:01:00Z",
        ))
        .expect("insert evt-2");
        db.insert_event(&shell_event(
            "evt-3",
            456,
            "/repo/cli",
            "/dev/ttys002",
            "2026-01-30T00:02:00Z",
        ))
        .expect("insert evt-3");

        let state = db
            .rebuild_shell_state_from_events()
            .expect("rebuild shell state");

        assert_eq!(state.shells.len(), 2);
        let first = state.shells.get("123").expect("pid 123");
        assert_eq!(first.cwd, "/repo/app");
        assert_eq!(first.tty, "/dev/ttys001");
        assert_eq!(first.updated_at, "2026-01-30T00:01:00Z");

        let second = state.shells.get("456").expect("pid 456");
        assert_eq!(second.cwd, "/repo/cli");
        assert_eq!(second.tty, "/dev/ttys002");
        assert_eq!(second.updated_at, "2026-01-30T00:02:00Z");

        let loaded = db.load_shell_state().expect("load shell state");
        assert_eq!(loaded.shells.len(), 2);
        assert_eq!(loaded.shells.get("123").unwrap().cwd, "/repo/app");
        assert_eq!(loaded.shells.get("456").unwrap().cwd, "/repo/cli");
    }

    #[test]
    fn upserts_process_liveness_rows() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let recorded_at = "2026-01-30T00:03:00Z";

        let event = shell_event(
            "evt-4",
            std::process::id(),
            "/tmp",
            "/dev/ttys007",
            recorded_at,
        );
        db.upsert_process_liveness(&event)
            .expect("upsert process liveness");

        let row = db
            .get_process_liveness(std::process::id())
            .expect("query process liveness")
            .expect("process row exists");

        assert_eq!(row.pid, std::process::id());
        assert_eq!(row.last_seen_at, recorded_at);
    }

    #[test]
    fn rebuilds_process_liveness_from_events() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let alive_pid = std::process::id();
        let dead_pid = 999_999_999u32;

        db.insert_event(&shell_event(
            "evt-5",
            alive_pid,
            "/tmp",
            "/dev/ttys011",
            "2026-01-30T00:05:00Z",
        ))
        .expect("insert alive pid");
        db.insert_event(&shell_event(
            "evt-6",
            dead_pid,
            "/tmp",
            "/dev/ttys012",
            "2026-01-30T00:06:00Z",
        ))
        .expect("insert dead pid");

        db.rebuild_process_liveness_from_events()
            .expect("rebuild process liveness");

        let alive = db
            .get_process_liveness(alive_pid)
            .expect("query alive pid")
            .expect("alive pid row");
        assert_eq!(alive.last_seen_at, "2026-01-30T00:05:00Z");
        assert!(alive.proc_started.is_some());

        let dead = db
            .get_process_liveness(dead_pid)
            .expect("query dead pid")
            .expect("dead pid row");
        assert_eq!(dead.last_seen_at, "2026-01-30T00:06:00Z");
        assert!(dead.proc_started.is_none());
    }

    #[test]
    fn prunes_process_liveness_rows() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let stale_time = (Utc::now() - Duration::hours(48)).to_rfc3339();
        let fresh_time = Utc::now().to_rfc3339();

        let stale_event = EventEnvelope {
            event_id: "evt-stale".to_string(),
            recorded_at: stale_time,
            event_type: EventType::SessionStart,
            session_id: Some("session-stale".to_string()),
            pid: Some(11111),
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
        };
        db.upsert_process_liveness(&stale_event)
            .expect("insert stale");

        let fresh_event = EventEnvelope {
            event_id: "evt-fresh".to_string(),
            recorded_at: fresh_time,
            event_type: EventType::SessionStart,
            session_id: Some("session-fresh".to_string()),
            pid: Some(22222),
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
        };
        db.upsert_process_liveness(&fresh_event)
            .expect("insert fresh");

        let removed = db
            .prune_process_liveness(24)
            .expect("prune process_liveness");
        assert_eq!(removed, 1);

        assert!(db.get_process_liveness(11111).unwrap().is_none());
        assert!(db.get_process_liveness(22222).unwrap().is_some());
    }

    #[test]
    fn schema_includes_session_activity_and_tombstone_tables() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let tables = db
            .with_connection(|conn| {
                let mut stmt = conn
                    .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
                    .map_err(|err| format!("Failed to query sqlite_master: {}", err))?;
                let rows = stmt
                    .query_map([], |row| row.get::<_, String>(0))
                    .map_err(|err| format!("Failed to read sqlite_master rows: {}", err))?;
                let mut names = Vec::new();
                for row in rows {
                    names.push(row.map_err(|err| format!("Failed to decode table name: {}", err))?);
                }
                Ok(names)
            })
            .expect("tables");

        assert!(tables.contains(&"sessions".to_string()));
        assert!(tables.contains(&"activity".to_string()));
        assert!(tables.contains(&"tombstones".to_string()));
        assert!(tables.contains(&"hem_shadow_mismatches".to_string()));
        assert!(tables.contains(&"routing_rollout_state".to_string()));
    }

    #[test]
    fn upserts_and_loads_routing_rollout_state() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let input = crate::are::metrics::PersistedRoutingRolloutState {
            dual_run_comparisons: 1_234,
            legacy_vs_are_status_mismatch: 2,
            legacy_vs_are_target_mismatch: 3,
            first_comparison_at: Some("2026-02-01T10:00:00Z".to_string()),
            last_comparison_at: Some("2026-02-14T12:00:00Z".to_string()),
            last_snapshot_at: Some("2026-02-14T12:00:00Z".to_string()),
        };
        db.upsert_routing_rollout_state(&input)
            .expect("upsert routing rollout");

        let loaded = db
            .load_routing_rollout_state()
            .expect("load routing rollout")
            .expect("routing rollout row");

        assert_eq!(loaded, input);
    }

    #[test]
    fn init_schema_creates_routing_rollout_table_for_existing_db() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        {
            let conn = Connection::open(&db_path).expect("open raw sqlite");
            conn.execute_batch(
                "BEGIN;
                 CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY,
                    recorded_at TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    session_id TEXT,
                    pid INTEGER,
                    payload TEXT NOT NULL
                 );
                 COMMIT;",
            )
            .expect("seed legacy schema");
        }

        let db = Db::new(db_path).expect("db init migration");
        let tables = db
            .with_connection(|conn| {
                let mut stmt = conn
                    .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
                    .map_err(|err| format!("Failed to query sqlite_master: {}", err))?;
                let rows = stmt
                    .query_map([], |row| row.get::<_, String>(0))
                    .map_err(|err| format!("Failed to read sqlite_master rows: {}", err))?;
                let mut names = Vec::new();
                for row in rows {
                    names.push(row.map_err(|err| format!("Failed to decode table name: {}", err))?);
                }
                Ok(names)
            })
            .expect("tables");

        assert!(tables.contains(&"routing_rollout_state".to_string()));
    }

    #[test]
    fn inserts_and_prunes_hem_shadow_mismatches() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let old = HemShadowMismatch {
            observed_at: (Utc::now() - Duration::days(30)).to_rfc3339(),
            event_id: Some("evt-old".to_string()),
            session_id: Some("session-1".to_string()),
            project_id: Some("/repo/.git".to_string()),
            project_path: Some("/repo".to_string()),
            category: "state_mismatch".to_string(),
            reducer_state: Some("working".to_string()),
            hem_state: Some("ready".to_string()),
            confidence_delta: Some(0.42),
            detail_json: Some("{\"kind\":\"old\"}".to_string()),
        };
        let recent = HemShadowMismatch {
            observed_at: Utc::now().to_rfc3339(),
            event_id: Some("evt-recent".to_string()),
            session_id: Some("session-2".to_string()),
            project_id: Some("/repo/.git".to_string()),
            project_path: Some("/repo".to_string()),
            category: "state_mismatch".to_string(),
            reducer_state: Some("ready".to_string()),
            hem_state: Some("working".to_string()),
            confidence_delta: Some(0.37),
            detail_json: Some("{\"kind\":\"recent\"}".to_string()),
        };

        db.insert_hem_shadow_mismatch(&old)
            .expect("insert old mismatch");
        db.insert_hem_shadow_mismatch(&recent)
            .expect("insert recent mismatch");

        let removed = db
            .prune_hem_shadow_mismatches(14)
            .expect("prune mismatches");
        assert_eq!(removed, 1);

        let count = db
            .with_connection(|conn| {
                conn.query_row("SELECT COUNT(*) FROM hem_shadow_mismatches", [], |row| {
                    row.get::<_, i64>(0)
                })
                .map_err(|err| format!("Failed to count hem_shadow_mismatches rows: {}", err))
            })
            .expect("count rows");
        assert_eq!(count, 1);
    }

    #[test]
    fn upserts_and_deletes_tombstones() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let created = "2026-01-31T00:00:00Z";
        let expires = "2026-01-31T00:01:00Z";

        db.upsert_tombstone("session-1", created, expires)
            .expect("insert tombstone");
        let row = db
            .get_tombstone("session-1")
            .expect("fetch tombstone")
            .expect("row exists");
        assert_eq!(row.created_at, created);
        assert_eq!(row.expires_at, expires);

        db.delete_tombstone("session-1").expect("delete tombstone");
        let row = db.get_tombstone("session-1").expect("fetch tombstone");
        assert!(row.is_none());
    }

    #[test]
    fn upserts_and_fetches_sessions() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let record = crate::reducer::SessionRecord {
            session_id: "session-1".to_string(),
            pid: 1234,
            state: crate::reducer::SessionState::Ready,
            cwd: "/repo".to_string(),
            project_id: "/repo/.git".to_string(),
            project_path: "/repo".to_string(),
            updated_at: "2026-01-31T00:00:00Z".to_string(),
            state_changed_at: "2026-01-31T00:00:00Z".to_string(),
            last_event: Some("session_start".to_string()),
            last_activity_at: None,
            tools_in_flight: 0,
            ready_reason: None,
        };

        db.upsert_session(&record).expect("upsert session");

        let loaded = db
            .get_session("session-1")
            .expect("fetch session")
            .expect("session row");

        assert_eq!(loaded.session_id, record.session_id);
        assert_eq!(loaded.state, record.state);
        assert_eq!(loaded.cwd, record.cwd);
        assert_eq!(loaded.project_id, record.project_id);
        assert_eq!(loaded.project_path, record.project_path);
        assert_eq!(loaded.last_event, record.last_event);

        let mut updated = record.clone();
        updated.state = crate::reducer::SessionState::Working;
        updated.state_changed_at = "2026-01-31T00:01:00Z".to_string();
        updated.updated_at = "2026-01-31T00:01:00Z".to_string();
        db.upsert_session(&updated).expect("upsert update");

        let loaded = db
            .get_session("session-1")
            .expect("fetch session")
            .expect("session row");
        assert_eq!(loaded.state, crate::reducer::SessionState::Working);
        assert_eq!(loaded.state_changed_at, "2026-01-31T00:01:00Z");
    }

    #[test]
    fn inserts_and_lists_activity() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let entry = crate::activity::ActivityEntry {
            session_id: "session-1".to_string(),
            project_path: "/repo".to_string(),
            file_path: "/repo/src/main.rs".to_string(),
            tool_name: Some("Edit".to_string()),
            recorded_at: "2026-01-31T00:00:00Z".to_string(),
        };

        db.insert_activity(&entry).expect("insert activity");

        let entries = db.list_activity("session-1", 10).expect("list activity");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0], entry);
    }

    #[test]
    fn prunes_stale_shells() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db = Db::new(temp_dir.path().join("state.db")).expect("db init");

        // Insert a recent shell (1 hour ago) and a stale shell (48 hours ago)
        let recent = shell_event(
            "evt-r",
            100,
            "/recent",
            "/dev/ttys001",
            &(Utc::now() - Duration::hours(1)).to_rfc3339(),
        );
        let stale = shell_event(
            "evt-s",
            200,
            "/stale",
            "/dev/ttys002",
            &(Utc::now() - Duration::hours(48)).to_rfc3339(),
        );

        db.insert_event(&recent).unwrap();
        db.upsert_shell_state(&recent).unwrap();
        db.insert_event(&stale).unwrap();
        db.upsert_shell_state(&stale).unwrap();

        assert_eq!(db.load_shell_state().unwrap().shells.len(), 2);

        let pruned = db.prune_stale_shells(24).unwrap();
        assert_eq!(pruned, 1); // Only the 48h-old shell

        let remaining = db.load_shell_state().unwrap();
        assert_eq!(remaining.shells.len(), 1);
        assert!(remaining.shells.contains_key("100")); // Recent kept
        assert!(!remaining.shells.contains_key("200")); // Stale removed
    }

    #[test]
    fn deletes_specific_shells() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db = Db::new(temp_dir.path().join("state.db")).expect("db init");

        for (id, pid) in [("e1", 100), ("e2", 200), ("e3", 300)] {
            let ev = shell_event(id, pid, "/dir", "/dev/ttys001", "2026-02-08T00:00:00Z");
            db.insert_event(&ev).unwrap();
            db.upsert_shell_state(&ev).unwrap();
        }

        assert_eq!(db.load_shell_state().unwrap().shells.len(), 3);

        let deleted = db
            .delete_shells(&["100".to_string(), "300".to_string()])
            .unwrap();
        assert_eq!(deleted, 2);

        let remaining = db.load_shell_state().unwrap();
        assert_eq!(remaining.shells.len(), 1);
        assert!(remaining.shells.contains_key("200"));
    }

    #[test]
    fn list_session_affecting_events_orders_equal_instants_by_id() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db = Db::new(temp_dir.path().join("state.db")).expect("db init");

        let plus_zero = session_event(
            "evt-b",
            "2026-02-01T00:00:00+00:00",
            EventType::SessionStart,
        );
        let zulu = session_event("evt-a", "2026-02-01T00:00:00Z", EventType::SessionStart);

        db.insert_event(&plus_zero).expect("insert plus_zero");
        db.insert_event(&zulu).expect("insert zulu");

        let events = db
            .list_session_affecting_events_since(None)
            .expect("list events");
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].event_id, "evt-a");
        assert_eq!(events[1].event_id, "evt-b");
    }

    #[test]
    fn latest_session_affecting_event_time_uses_temporal_order_not_lexical_order() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db = Db::new(temp_dir.path().join("state.db")).expect("db init");

        // 13:00+01:00 == 12:00Z (older than 12:30Z), but lexical string order is greater.
        let older = session_event(
            "evt-older",
            "2026-01-31T13:00:00+01:00",
            EventType::SessionStart,
        );
        let newer = session_event("evt-newer", "2026-01-31T12:30:00Z", EventType::SessionStart);

        db.insert_event(&older).expect("insert older");
        db.insert_event(&newer).expect("insert newer");

        let latest = db
            .latest_session_affecting_event_time()
            .expect("latest time")
            .expect("has latest");
        assert_eq!(latest.to_rfc3339(), "2026-01-31T12:30:00+00:00");
    }
}
