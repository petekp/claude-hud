use chrono::{DateTime, Utc};

use crate::reducer::SessionState;

#[derive(Debug, Clone)]
pub struct SessionProjection {
    pub session_id: String,
    pub project_id: String,
    pub state: SessionState,
    pub session_time: DateTime<Utc>,
    pub updated_at: String,
    pub state_changed_at: String,
}

#[derive(Debug, Clone)]
pub struct ReducedProjectState {
    pub project_id: String,
    pub state: SessionState,
    pub representative_session_id: Option<String>,
    pub latest_session_id: Option<String>,
    pub state_changed_at: String,
    pub updated_at: String,
    pub session_count: usize,
    pub active_count: usize,
}

pub fn state_priority(state: &SessionState) -> u8 {
    match state {
        SessionState::Waiting => 4,
        SessionState::Compacting => 3,
        SessionState::Working => 2,
        SessionState::Ready => 1,
        SessionState::Idle => 0,
    }
}

pub fn session_state_is_active(state: &SessionState) -> bool {
    matches!(
        state,
        SessionState::Working | SessionState::Waiting | SessionState::Compacting
    )
}

pub fn reduce_project_sessions(sessions: &[SessionProjection]) -> Option<ReducedProjectState> {
    // Representative selects which session "owns" the project state badge.
    // Latest tracks recency for ordering/focus logic when that differs from state ownership.
    let representative = sessions.iter().max_by(|left, right| {
        state_priority(&left.state)
            .cmp(&state_priority(&right.state))
            .then_with(|| left.session_time.cmp(&right.session_time))
            .then_with(|| left.session_id.cmp(&right.session_id))
    })?;

    let latest = sessions.iter().max_by(|left, right| {
        left.session_time
            .cmp(&right.session_time)
            .then_with(|| left.session_id.cmp(&right.session_id))
    })?;

    let project_id = if !representative.project_id.is_empty() {
        representative.project_id.clone()
    } else if !latest.project_id.is_empty() {
        latest.project_id.clone()
    } else {
        sessions
            .iter()
            .find(|candidate| !candidate.project_id.is_empty())
            .map(|candidate| candidate.project_id.clone())
            .unwrap_or_default()
    };

    let active_count = sessions
        .iter()
        .filter(|session| session_state_is_active(&session.state))
        .count();

    Some(ReducedProjectState {
        project_id,
        state: representative.state.clone(),
        representative_session_id: Some(representative.session_id.clone()),
        latest_session_id: Some(latest.session_id.clone()),
        state_changed_at: representative.state_changed_at.clone(),
        updated_at: latest.updated_at.clone(),
        session_count: sessions.len(),
        active_count,
    })
}
