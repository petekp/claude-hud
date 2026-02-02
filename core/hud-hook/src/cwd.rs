//! Shell CWD tracking for ambient project awareness.
//!
//! Called by shell precmd hooks to report the current working directory.
//! Sends shell CWD events to the daemon (single writer).
//!
//! ## Usage
//!
//! ```bash
//! hud-hook cwd /path/to/project 12345 /dev/ttys003
//! ```
//!
//! ## Performance
//!
//! Target: < 15ms total execution time.
//! The shell spawns this in the background, so users never wait.

use chrono::{DateTime, Utc};
use hud_core::ParentApp;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum CwdError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Daemon unavailable: {0}")]
    DaemonUnavailable(String),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct ShellEntry {
    pub cwd: String,
    pub tty: String,
    #[serde(default)]
    pub parent_app: ParentApp,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_client_tty: Option<String>,
    pub updated_at: DateTime<Utc>,
}

impl ShellEntry {
    fn new(cwd: String, tty: String, parent_app: ParentApp) -> Self {
        let (tmux_session, tmux_client_tty) = if parent_app == ParentApp::Tmux {
            detect_tmux_context().map_or((None, None), |(s, t)| (Some(s), Some(t)))
        } else {
            (None, None)
        };

        Self {
            cwd,
            tty,
            parent_app,
            tmux_session,
            tmux_client_tty,
            updated_at: Utc::now(),
        }
    }
}

// MARK: - Public API

pub fn run(path: &str, pid: u32, tty: &str) -> Result<(), CwdError> {
    let normalized_path = normalize_path(path);
    let parent_app = detect_parent_app(pid);
    let resolved_tty = resolve_tty(tty)?;
    let entry = ShellEntry::new(normalized_path.clone(), resolved_tty.clone(), parent_app);

    if !crate::daemon_client::daemon_enabled() {
        return Err(CwdError::DaemonUnavailable("Daemon disabled".to_string()));
    }

    match crate::daemon_client::send_shell_cwd_event(
        pid,
        &normalized_path,
        &resolved_tty,
        parent_app,
        entry.tmux_session.clone(),
        entry.tmux_client_tty.clone(),
    ) {
        Ok(()) => Ok(()),
        Err(err) => Err(CwdError::DaemonUnavailable(err)),
    }
}

fn normalize_path(path: &str) -> String {
    if path == "/" {
        "/".to_string()
    } else {
        path.trim_end_matches('/').to_string()
    }
}

fn resolve_tty(tty: &str) -> Result<String, CwdError> {
    let provided = tty.trim();
    if !provided.is_empty() {
        return Ok(provided.to_string());
    }

    if let Ok(env_tty) = std::env::var("TTY") {
        let env_tty = env_tty.trim();
        if !env_tty.is_empty() {
            return Ok(env_tty.to_string());
        }
    }

    let fallback = std::process::Command::new("tty")
        .output()
        .ok()
        .and_then(|out| {
            if out.status.success() {
                Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
            } else {
                None
            }
        })
        .filter(|value| !value.is_empty());

    match fallback {
        Some(value) => Ok(value),
        None => Err(CwdError::DaemonUnavailable(
            "Missing TTY for shell cwd event".to_string(),
        )),
    }
}

fn detect_parent_app(_pid: u32) -> ParentApp {
    if std::env::var("TMUX").is_ok() {
        return ParentApp::Tmux;
    }
    if let Ok(term_program) = std::env::var("TERM_PROGRAM") {
        let normalized = term_program.to_lowercase();
        match normalized.as_str() {
            "iterm.app" | "iterm2" => return ParentApp::ITerm,
            "apple_terminal" | "terminal.app" | "terminal" => return ParentApp::Terminal,
            "warpterminal" | "warp" => return ParentApp::Warp,
            "ghostty" => return ParentApp::Ghostty,
            "vscode" => return ParentApp::VSCode,
            "vscode-insiders" => return ParentApp::VSCodeInsiders,
            "cursor" => return ParentApp::Cursor,
            "zed" => return ParentApp::Zed,
            _ => {}
        }
    }

    if let Ok(term) = std::env::var("TERM") {
        let normalized = term.to_lowercase();
        if normalized.contains("kitty") {
            return ParentApp::Kitty;
        }
        if normalized.contains("alacritty") {
            return ParentApp::Alacritty;
        }
    }

    ParentApp::Unknown
}

fn detect_tmux_context() -> Option<(String, String)> {
    if std::env::var("TMUX").is_err() {
        return None;
    }

    let session = std::process::Command::new("tmux")
        .args(["display-message", "-p", "#S"])
        .output()
        .ok()
        .and_then(|out| {
            if out.status.success() {
                Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
            } else {
                None
            }
        })
        .filter(|value| !value.is_empty());

    let client_tty = std::process::Command::new("tmux")
        .args(["display-message", "-p", "#{client_tty}"])
        .output()
        .ok()
        .and_then(|out| {
            if out.status.success() {
                Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
            } else {
                None
            }
        })
        .filter(|value| !value.is_empty());

    match (session, client_tty) {
        (Some(session), Some(client_tty)) => Some((session, client_tty)),
        _ => None,
    }
}
