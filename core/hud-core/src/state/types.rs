//! Data types for session state tracking.
//!
//! These structs represent the on-disk format written by the hook script and read by Rust.
//! The hook script (`scripts/hud-state-tracker.sh`) is the authoritative writer; we only read.
//!
//! # State File Format (v3)
//!
//! Location: `~/.capacitor/sessions.json`
//!
//! ```json
//! {
//!   "version": 3,
//!   "sessions": {
//!     "session-abc123": {
//!       "session_id": "session-abc123",
//!       "state": "working",
//!       "cwd": "/Users/me/project",
//!       "updated_at": "2026-01-21T10:30:00Z",
//!       "state_changed_at": "2026-01-21T10:29:55Z",
//!       "last_event": { "event": "UserPromptSubmit", "timestamp": "..." }
//!     }
//!   }
//! }
//! ```
//!
//! # Breaking Changes
//!
//! This is a single-user project, so we allow breaking schema changes between versions.
//! The store module rejects mismatched versions and the hook script handles migration.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::types::SessionState;

// =============================================================================
// State Machine Reference
// =============================================================================
//
// The hook script implements this state machine. Rust just reads the results.
//
// Hook Event                    → New State
// ─────────────────────────────────────────────
// SessionStart                  → ready
// UserPromptSubmit              → working
// PreToolUse                    → working
// PostToolUse                   → working
// PermissionRequest             → waiting
// Notification (idle_prompt)    → ready
// Stop                          → ready
// PreCompact (trigger=auto)     → compacting
// SessionEnd                    → (record deleted)
//
// =============================================================================

/// Metadata about the most recent hook event.
///
/// Captured for debugging and potential future features like "show what Claude
/// just did." The hook script populates whichever fields are relevant to the event.
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

/// A session's current state as recorded by the hook script.
///
/// Each active Claude Code session has one record. The hook script creates it on
/// `SessionStart`, updates it on state transitions, and deletes it on `SessionEnd`.
///
/// # Key Fields
///
/// - `state`: What Claude is doing (working, ready, waiting, compacting)
/// - `updated_at`: Last update (including heartbeats from tool use)
/// - `state_changed_at`: When the *state* actually changed (not just heartbeats)
/// - `cwd`: Current working directory (may change if user cd's)
/// - `project_dir`: Stable project root (stays constant even if cwd changes)
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionRecord {
    /// Unique identifier for this session (from Claude Code CLI).
    pub session_id: String,

    /// Current session state. See [`SessionState`] for values.
    pub state: SessionState,

    /// Current working directory. May differ from `project_dir` if user cd'd.
    pub cwd: String,

    /// Last update time (any event, including heartbeats).
    /// Used for "is this record fresh?" checks in the resolver.
    pub updated_at: DateTime<Utc>,

    /// When the state actually changed (ignores heartbeat-only updates).
    /// Used by the UI to show "working for 5 minutes" etc.
    pub state_changed_at: DateTime<Utc>,

    /// User-provided task description (from prompt or context).
    #[serde(default)]
    pub working_on: Option<String>,

    /// Path to the session transcript JSONL file.
    #[serde(default)]
    pub transcript_path: Option<String>,

    /// Permission mode (e.g., "plan", "default").
    #[serde(default)]
    pub permission_mode: Option<String>,

    /// Stable project root directory.
    /// Stays constant even if user cd's into subdirectories.
    #[serde(default)]
    pub project_dir: Option<String>,

    /// Most recent hook event (for debugging).
    #[serde(default)]
    pub last_event: Option<LastEvent>,

    /// Number of active subagents (Task tool invocations).
    #[serde(default)]
    pub active_subagent_count: u32,
}

impl SessionRecord {
    /// Returns true if this record is stale (not updated in last 5 minutes)
    pub fn is_stale(&self) -> bool {
        let now = Utc::now();
        let age = now.signed_duration_since(self.updated_at);
        age.num_seconds() > 300 // 5 minutes
    }
}

/// Metadata from a lock directory.
///
/// Lock directories live at `~/.claude/sessions/{hash}.lock/` where `{hash}` is
/// the MD5 of the normalized project path. Inside each lock directory:
///
/// - `pid`: The Claude process ID (plain text)
/// - `meta.json`: This struct serialized as JSON
///
/// # PID Verification
///
/// PIDs can be reused by the OS. We store `proc_started` (the process start time)
/// to detect when a PID has been recycled. If the current process with that PID
/// has a different start time, the lock is stale.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LockInfo {
    /// Process ID of the Claude Code process.
    pub pid: u32,

    /// Project path this lock represents.
    pub path: String,

    /// Process start time (Unix epoch seconds) for PID identity verification.
    /// If the process with this PID has a different start time, the lock is stale.
    /// `None` for legacy locks created before this field was added.
    #[serde(default)]
    pub proc_started: Option<u64>,

    /// When this lock was created (Unix epoch milliseconds).
    /// Used for "newest lock wins" when multiple locks might exist.
    /// The `alias = "started"` handles old locks that used a different field name.
    #[serde(default, alias = "started")]
    pub created: Option<u64>,
}

#[cfg(test)]
mod tests {
    // Intentionally empty: state machine logic lives in hook scripts and is validated via
    // shell-based integration tests in scripts/test-hook-events.sh.
}
