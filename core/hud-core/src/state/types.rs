//! Serialized state types used by the hook/state pipeline.
//!
//! **Breaking changes are allowed** (single-user project). Current on-disk format is v3.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::types::SessionState;

/// Records older than this are considered stale and untrusted without a lock.
pub const STALE_THRESHOLD_SECS: i64 = 300; // 5 minutes

// -----------------------------------------------------------------------------
// Canonical hook→state mapping (implemented in scripts/hud-state-tracker.sh)
//
// SessionStart                -> ready
// UserPromptSubmit            -> working
// PreToolUse                  -> working
// PostToolUse                 -> working
// PermissionRequest           -> waiting
// Notification idle_prompt    -> ready
// Notification permission_prompt|elicitation_dialog -> waiting
// PreCompact (trigger=auto|manual|missing) -> compacting
// Stop (stop_hook_active=true) -> no state change (metadata only)
// Stop (otherwise)            -> ready
// SessionEnd                  -> remove session record
// SubagentStop                -> no state change (metadata only)
// -----------------------------------------------------------------------------

/// Most recent hook event observed for this session (captured for debugging + future features).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct LastEvent {
    #[serde(default)]
    pub hook_event_name: Option<String>,
    #[serde(default)]
    pub at: Option<DateTime<Utc>>,

    // Common event-specific fields (all optional)
    #[serde(default)]
    pub tool_name: Option<String>,
    #[serde(default)]
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub notification_type: Option<String>,
    #[serde(default)]
    pub trigger: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub stop_hook_active: Option<bool>,
    #[serde(default)]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub agent_transcript_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionRecord {
    pub session_id: String,
    pub state: SessionState,
    pub cwd: String,
    pub updated_at: DateTime<Utc>,
    pub state_changed_at: DateTime<Utc>,
    #[serde(default)]
    pub working_on: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
    #[serde(default)]
    pub project_dir: Option<String>,
    #[serde(default)]
    pub last_event: Option<LastEvent>,
    #[serde(default)]
    pub active_subagent_count: u32,
}

impl SessionRecord {
    /// Returns true if this record is stale (not updated in last 5 minutes)
    pub fn is_stale(&self) -> bool {
        let now = Utc::now();
        let age = now.signed_duration_since(self.updated_at);
        age.num_seconds() > STALE_THRESHOLD_SECS
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LockInfo {
    pub pid: u32,
    pub path: String,
    /// Process start time (Unix timestamp) for PID identity verification.
    /// None for legacy locks created before PID verification was added.
    #[serde(default)]
    pub proc_started: Option<u64>,
    /// Lock creation time (Unix timestamp) for "newest lock wins" selection.
    /// Uses the old field name "started" for backward compatibility with reading old locks.
    /// New locks write to "created" field instead.
    #[serde(default, alias = "started")]
    pub created: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn make_record(updated_at: DateTime<Utc>) -> SessionRecord {
        SessionRecord {
            session_id: "test".to_string(),
            state: crate::types::SessionState::Ready,
            cwd: "/test".to_string(),
            updated_at,
            state_changed_at: updated_at,
            working_on: None,
            transcript_path: None,
            permission_mode: None,
            project_dir: None,
            last_event: None,
            active_subagent_count: 0,
        }
    }

    #[test]
    fn test_is_stale_fresh_record() {
        let record = make_record(Utc::now());
        assert!(!record.is_stale());
    }

    #[test]
    fn test_is_stale_old_record() {
        let old_time = Utc::now() - Duration::seconds(STALE_THRESHOLD_SECS + 1);
        let record = make_record(old_time);
        assert!(record.is_stale());
    }

    #[test]
    fn test_is_stale_boundary() {
        // Exactly at threshold should NOT be stale (uses >)
        let boundary_time = Utc::now() - Duration::seconds(STALE_THRESHOLD_SECS);
        let record = make_record(boundary_time);
        assert!(!record.is_stale());
    }
}
