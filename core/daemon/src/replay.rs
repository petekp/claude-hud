use crate::activity::reduce_activity;
use crate::db::Db;
use crate::reducer::SessionUpdate;
use crate::session_store::handle_session_event;
use chrono::{DateTime, Utc};

#[cfg(test)]
pub fn rebuild_from_events(db: &Db) -> Result<(), String> {
    db.clear_sessions()?;
    db.clear_activity()?;
    db.clear_tombstones()?;

    let events = db.list_events()?;
    apply_events(db, events)
}

pub fn catch_up_sessions_from_events(db: &Db, since: Option<DateTime<Utc>>) -> Result<(), String> {
    let events = db.list_session_affecting_events_since(since)?;
    apply_events(db, events)
}

fn apply_events(
    db: &Db,
    events: Vec<capacitor_daemon_protocol::EventEnvelope>,
) -> Result<(), String> {
    for event in events {
        let current = match event.session_id.as_ref() {
            Some(session_id) => db.get_session(session_id)?,
            None => None,
        };

        let update = handle_session_event(db, current.as_ref(), &event)?;

        match update {
            SessionUpdate::Upsert(record) => {
                db.upsert_session(&record)?;
                if let Some(entry) = reduce_activity(&event) {
                    db.insert_activity(&entry)?;
                }
            }
            SessionUpdate::Delete { session_id } => {
                db.delete_session(&session_id)?;
                db.delete_activity_for_session(&session_id)?;
            }
            SessionUpdate::Skip => {}
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use capacitor_daemon_protocol::{EventEnvelope, EventType};

    fn make_event(event_id: &str, event_type: EventType, recorded_at: &str) -> EventEnvelope {
        EventEnvelope {
            event_id: event_id.to_string(),
            recorded_at: recorded_at.to_string(),
            event_type,
            session_id: Some("session-1".to_string()),
            pid: Some(1234),
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
        }
    }

    #[test]
    fn rebuild_removes_session_and_activity_on_end() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let start = make_event("evt-1", EventType::SessionStart, "2026-01-31T00:00:00Z");
        let mut post = make_event("evt-2", EventType::PostToolUse, "2026-01-31T00:00:10Z");
        post.file_path = Some("src/main.rs".to_string());
        post.tool = Some("Edit".to_string());
        let end = make_event("evt-3", EventType::SessionEnd, "2026-01-31T00:00:20Z");

        db.insert_event(&start).expect("insert start");
        db.insert_event(&post).expect("insert post");
        db.insert_event(&end).expect("insert end");

        rebuild_from_events(&db).expect("rebuild");

        let session = db.get_session("session-1").expect("fetch session");
        assert!(session.is_none());

        let activity = db.list_activity("session-1", 10).expect("list activity");
        assert!(activity.is_empty());

        let tombstone = db
            .get_tombstone("session-1")
            .expect("fetch tombstone")
            .expect("tombstone exists");
        assert_eq!(tombstone.expires_at, "2026-01-31T00:01:20+00:00");
    }

    #[test]
    fn rebuild_keeps_active_session_state() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let start = make_event("evt-1", EventType::SessionStart, "2026-01-31T00:00:00Z");
        let post = make_event("evt-2", EventType::PostToolUse, "2026-01-31T00:00:10Z");

        db.insert_event(&start).expect("insert start");
        db.insert_event(&post).expect("insert post");

        rebuild_from_events(&db).expect("rebuild");

        let session = db
            .get_session("session-1")
            .expect("fetch session")
            .expect("session exists");
        assert_eq!(session.state.as_str(), "working");
        assert_eq!(session.state_changed_at, "2026-01-31T00:00:10Z");
        assert_eq!(session.updated_at, "2026-01-31T00:00:10Z");
    }

    #[test]
    fn catch_up_uses_temporal_order_for_mixed_rfc3339_formats() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        // 13:00+01:00 == 12:00Z (older than 12:30Z), but lexical string order is greater.
        let older_start = make_event(
            "evt-1",
            EventType::SessionStart,
            "2026-01-31T13:00:00+01:00",
        );
        let newer_end = make_event("evt-2", EventType::SessionEnd, "2026-01-31T12:30:00Z");

        db.insert_event(&older_start).expect("insert start");
        db.insert_event(&newer_end).expect("insert end");

        catch_up_sessions_from_events(&db, None).expect("catch up");

        let session = db.get_session("session-1").expect("get session");
        assert!(
            session.is_none(),
            "session should remain deleted after catch-up"
        );
    }
}
