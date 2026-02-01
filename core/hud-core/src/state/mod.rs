//! Session State Detection (v4)
//!
//! Determines whether Claude Code is running and what it's doing for a given project.
//!
//! # Architecture: Sidecar Pattern
//!
//! Claude HUD follows a **sidecar philosophy**: we observe Claude Code without interfering.
//! The hook handler (`core/hud-hook/`) is authoritative for state transitions;
//! this module is a passive reader that applies staleness heuristics.
//!
//! ```text
//! Claude Code → Hook Script → Daemon → This Module → Swift UI
//!     (user)      (writer)    (storage)   (reader)      (display)
//! ```
//!
//! # Liveness Detection
//!
//! Liveness is sourced from daemon snapshots (`is_alive` + `state_changed_at`).
//!
//! # Module Structure
//!
//! - [`daemon`]: Daemon IPC helpers for session/activity snapshots
//! - [`types`]: Data structures, canonical state mapping
//!
//! # Key Entry Points
//!
mod cleanup;
pub(crate) mod daemon;
mod path_utils;
pub(crate) mod types;

// Re-export path utilities for use across the crate
pub use path_utils::{
    normalize_path_for_comparison, normalize_path_for_hashing, normalize_path_for_matching,
};

pub use cleanup::{run_startup_cleanup, CleanupStats};
pub use types::{HookEvent, HookInput, LastEvent, SessionRecord, ToolInput, ToolResponse};
