//! Session State Detection (v3)
//!
//! Determines whether Claude Code is running and what it's doing for a given project.
//!
//! # Architecture: Sidecar Pattern
//!
//! Claude HUD follows a **sidecar philosophy**: we observe Claude Code without interfering.
//! The hook script is authoritative for state transitions; Rust is a passive reader.
//!
//! ```text
//! Claude Code → Hook Script → State File + Lock Dir → This Module → Swift UI
//!     (user)      (writer)       (storage)              (reader)      (display)
//! ```
//!
//! # Two-Layer Liveness Detection
//!
//! We use two signals to determine if a session is active:
//!
//! 1. **Lock files** (primary): Directories in `~/.claude/sessions/{hash}.lock/` indicate
//!    a running session. The lock holder is a background process that monitors Claude
//!    and releases the lock when it exits.
//!
//! 2. **Fresh record fallback**: If no lock exists but a state record was updated within
//!    30 seconds, trust it. This handles race conditions during session startup.
//!
//! # Module Structure
//!
//! - [`lock`]: Lock file detection and PID verification
//! - [`resolver`]: Fuses lock + state data to answer "is Claude running here?"
//! - [`store`]: Reads/writes the JSON state file (`~/.capacitor/sessions.json`)
//! - [`types`]: Data structures for session records and lock metadata
//!
//! # Key Entry Points
//!
//! - [`is_session_running`]: Quick check for any active session at/under a path
//! - [`resolve_state_with_details`]: Full resolution with session ID and cwd
//! - [`StateStore`]: Low-level access to session records

pub(crate) mod lock;
mod resolver;
mod store;
pub(crate) mod types;

pub use lock::{get_lock_info, is_session_running};
pub use resolver::{resolve_state, resolve_state_with_details, ResolvedState};
pub use store::StateStore;
pub use types::{LastEvent, LockInfo, SessionRecord};
