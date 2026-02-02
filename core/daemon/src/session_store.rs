use chrono::{DateTime, Duration, Utc};

use capacitor_daemon_protocol::{EventEnvelope, EventType};
use tracing::debug;

use crate::db::Db;
use crate::reducer::{reduce_session, SessionRecord, SessionUpdate};

const TOMBSTONE_TTL_SECS: i64 = 60;

pub fn handle_session_event(
    db: &Db,
    current: Option<&SessionRecord>,
    event: &EventEnvelope,
) -> Result<SessionUpdate, String> {
    let session_id = match event.session_id.as_ref() {
        Some(value) => value.as_str(),
        None => return Ok(SessionUpdate::Skip),
    };

    let tombstone = db.get_tombstone(session_id)?;
    let tombstone_active = tombstone
        .as_ref()
        .and_then(|row| parse_rfc3339(&row.expires_at))
        .and_then(|expires| parse_rfc3339(&event.recorded_at).map(|now| now < expires))
        .unwrap_or(false);

    if event.event_type != EventType::SessionStart
        && event.event_type != EventType::SessionEnd
        && tombstone_active
    {
        debug!(
            session_id = %session_id,
            event_type = ?event.event_type,
            "Skipping event due to active tombstone"
        );
        return Ok(SessionUpdate::Skip);
    }

    if event.event_type == EventType::SessionStart && tombstone.is_some() {
        debug!(session_id = %session_id, "Clearing tombstone on SessionStart");
        db.delete_tombstone(session_id)?;
    }

    if event.event_type == EventType::SessionEnd {
        if let Some(recorded_at) = parse_rfc3339(&event.recorded_at) {
            let expires_at = recorded_at + Duration::seconds(TOMBSTONE_TTL_SECS);
            debug!(
                session_id = %session_id,
                expires_at = %expires_at.to_rfc3339(),
                "Creating tombstone on SessionEnd"
            );
            db.upsert_tombstone(
                session_id,
                &recorded_at.to_rfc3339(),
                &expires_at.to_rfc3339(),
            )?;
        }
    }

    Ok(reduce_session(current, event))
}

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event_base(event_type: EventType, recorded_at: &str) -> EventEnvelope {
        EventEnvelope {
            event_id: "evt-1".to_string(),
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
    fn skips_events_when_tombstone_active() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        db.upsert_tombstone("session-1", "2026-01-31T00:00:00Z", "2026-01-31T00:01:00Z")
            .expect("insert tombstone");

        let event = event_base(EventType::UserPromptSubmit, "2026-01-31T00:00:30Z");
        let update = handle_session_event(&db, None, &event).expect("handle event");
        assert_eq!(update, SessionUpdate::Skip);
    }

    #[test]
    fn session_start_clears_tombstone() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        db.upsert_tombstone("session-1", "2026-01-31T00:00:00Z", "2026-01-31T00:01:00Z")
            .expect("insert tombstone");

        let event = event_base(EventType::SessionStart, "2026-01-31T00:00:30Z");
        let update = handle_session_event(&db, None, &event).expect("handle event");

        assert!(matches!(update, SessionUpdate::Upsert(_)));
        assert!(db
            .get_tombstone("session-1")
            .expect("fetch tombstone")
            .is_none());
    }

    #[test]
    fn session_end_creates_tombstone() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let event = event_base(EventType::SessionEnd, "2026-01-31T00:00:00Z");
        let update = handle_session_event(&db, None, &event).expect("handle event");
        assert_eq!(
            update,
            SessionUpdate::Delete {
                session_id: "session-1".to_string()
            }
        );

        let tombstone = db
            .get_tombstone("session-1")
            .expect("fetch tombstone")
            .expect("tombstone exists");
        let created = parse_rfc3339(&tombstone.created_at).expect("parse created_at");
        let expires = parse_rfc3339(&tombstone.expires_at).expect("parse expires_at");
        assert_eq!(created.to_rfc3339(), "2026-01-31T00:00:00+00:00");
        assert_eq!(expires.to_rfc3339(), "2026-01-31T00:01:00+00:00");
    }
}
