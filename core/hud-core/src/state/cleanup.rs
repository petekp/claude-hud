//! Startup cleanup for daemon-only mode.
//!
//! Legacy lock-holder and file-based cleanup have been removed.

/// Results from a cleanup operation.
#[derive(Debug, Default, Clone, uniffi::Record)]
pub struct CleanupStats {
    /// Errors encountered during cleanup.
    pub errors: Vec<String>,
}

/// Performs startup cleanup on daemon-era artifacts.
///
/// The daemon is authoritative; no file-based cleanup is performed.
pub fn run_startup_cleanup() -> CleanupStats {
    CleanupStats::default()
}
