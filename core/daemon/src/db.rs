//! SQLite persistence for capacitor-daemon.
//!
//! This is the single-writer store backing the daemon. We keep the schema
//! intentionally small in Phase 3: an append-only events table and a
//! materialized shell_state table for fast reads.

use capacitor_daemon_protocol::EventEnvelope;
use rusqlite::{params, Connection, OpenFlags};
use std::collections::HashMap;
use std::path::PathBuf;

use crate::state::{ShellEntry, ShellState};

pub struct Db {
    path: PathBuf,
}

impl Db {
    pub fn new(path: PathBuf) -> Result<Self, String> {
        let db = Self { path };
        db.init_schema()?;
        Ok(db)
    }

    pub fn insert_event(&self, event: &EventEnvelope) -> Result<(), String> {
        self.with_connection(|conn| {
            let payload = serde_json::to_string(event)
                .map_err(|err| format!("Failed to serialize event payload: {}", err))?;
            let event_type = serde_json::to_string(&event.event_type)
                .unwrap_or_else(|_| "unknown".to_string())
                .trim_matches('"')
                .to_string();

            conn.execute(
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

            Ok(())
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
                let mut stmt = conn
                    .prepare(
                        "SELECT payload FROM events \
                         WHERE event_type = ?1 \
                         ORDER BY rowid ASC",
                    )
                    .map_err(|err| format!("Failed to prepare events replay query: {}", err))?;

                let rows = stmt
                    .query_map(params!["ShellCwd"], |row| row.get::<_, String>(0))
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
                 COMMIT;",
            )
            .map_err(|err| format!("Failed to initialize schema: {}", err))?;
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
