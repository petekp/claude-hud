//! Error types for hud-core operations.

use std::path::PathBuf;

/// All errors that can occur in hud-core operations.
#[derive(Debug, thiserror::Error)]
pub enum HudError {
    // ─────────────────────────────────────────────────────────────────────
    // Configuration Errors
    // ─────────────────────────────────────────────────────────────────────
    #[error("Claude directory not found at {0}")]
    ClaudeDirNotFound(PathBuf),

    #[error("Configuration file malformed: {path}: {details}")]
    ConfigMalformed { path: PathBuf, details: String },

    #[error("Configuration write failed: {path}: {source}")]
    ConfigWriteFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    // ─────────────────────────────────────────────────────────────────────
    // Project Errors
    // ─────────────────────────────────────────────────────────────────────
    #[error("Project not found: {0}")]
    ProjectNotFound(String),

    #[error("Project already pinned: {0}")]
    ProjectAlreadyPinned(String),

    #[error("Invalid project path: {path}: {reason}")]
    InvalidProjectPath { path: String, reason: String },

    // ─────────────────────────────────────────────────────────────────────
    // I/O Errors
    // ─────────────────────────────────────────────────────────────────────
    #[error("File not found: {0}")]
    FileNotFound(PathBuf),

    #[error("I/O error: {context}: {source}")]
    Io {
        context: String,
        #[source]
        source: std::io::Error,
    },

    #[error("JSON parsing error: {context}: {source}")]
    Json {
        context: String,
        #[source]
        source: serde_json::Error,
    },

    // ─────────────────────────────────────────────────────────────────────
    // Action Errors
    // ─────────────────────────────────────────────────────────────────────
    #[error("Command execution failed: {command}: {details}")]
    CommandFailed { command: String, details: String },

    #[error("Platform not supported for this operation: {0}")]
    UnsupportedPlatform(String),

    #[error("Not running inside tmux session")]
    NotInTmux,
}

/// Convenience type alias for Results using HudError.
pub type Result<T> = std::result::Result<T, HudError>;

// Conversion for Tauri compatibility (commands return Result<T, String>)
impl From<HudError> for String {
    fn from(err: HudError) -> String {
        err.to_string()
    }
}
