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

use chrono::{DateTime, Local, NaiveDateTime, TimeZone, Utc};
use hud_core::ParentApp;
use serde::{Deserialize, Serialize};
use std::path::{Component, Path};
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
        let (tmux_session, tmux_client_tty) = if std::env::var("TMUX").is_ok() {
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
    let proc_start = detect_proc_start(pid);
    let tmux_pane = detect_tmux_pane();

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
        proc_start,
        tmux_pane,
    ) {
        Ok(()) => Ok(()),
        Err(err) => Err(CwdError::DaemonUnavailable(err)),
    }
}

fn normalize_path(path: &str) -> String {
    let normalized = if path == "/" {
        "/".to_string()
    } else {
        path.trim_end_matches('/').to_string()
    };

    let normalized_path = Path::new(&normalized);
    if !normalized_path.is_absolute() {
        return normalized;
    }

    let canonical = match std::fs::canonicalize(normalized_path) {
        Ok(path) => path,
        Err(_) => return normalized,
    };

    merge_canonical_case(normalized_path, &canonical)
}

fn merge_canonical_case(original: &Path, canonical: &Path) -> String {
    let original_parts = path_components(original);
    let canonical_parts = path_components(canonical);
    let mut merged_reversed = Vec::with_capacity(original_parts.len());
    let mut canonical_index = canonical_parts.len();

    for original_part in original_parts.iter().rev() {
        if canonical_index > 0
            && original_part.eq_ignore_ascii_case(&canonical_parts[canonical_index - 1])
        {
            merged_reversed.push(canonical_parts[canonical_index - 1].clone());
            canonical_index -= 1;
        } else {
            merged_reversed.push(original_part.clone());
        }
    }

    merged_reversed.reverse();
    if merged_reversed.is_empty() {
        "/".to_string()
    } else {
        format!("/{}", merged_reversed.join("/"))
    }
}

fn path_components(path: &Path) -> Vec<String> {
    path.components()
        .filter_map(|component| match component {
            Component::Normal(part) => Some(part.to_string_lossy().to_string()),
            _ => None,
        })
        .collect()
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

    if std::env::var("TMUX").is_ok() {
        return ParentApp::Tmux;
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

fn detect_tmux_pane() -> Option<String> {
    std::env::var("TMUX_PANE")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn detect_proc_start(pid: u32) -> Option<u64> {
    let output = std::process::Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "lstart="])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let raw = text.trim();
    if raw.is_empty() {
        return None;
    }
    let naive = NaiveDateTime::parse_from_str(raw, "%a %b %e %H:%M:%S %Y").ok()?;
    let local = Local.from_local_datetime(&naive).single()?;
    Some(local.timestamp().max(0) as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::{Mutex, MutexGuard};
    use std::time::{SystemTime, UNIX_EPOCH};

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvGuard {
        _lock: MutexGuard<'static, ()>,
        tmux: Option<String>,
        term_program: Option<String>,
        term: Option<String>,
    }

    impl EnvGuard {
        fn acquire() -> Self {
            let lock = ENV_LOCK.lock().expect("env lock");
            Self {
                _lock: lock,
                tmux: std::env::var("TMUX").ok(),
                term_program: std::env::var("TERM_PROGRAM").ok(),
                term: std::env::var("TERM").ok(),
            }
        }

        fn set_var(&self, key: &str, value: &str) {
            std::env::set_var(key, value);
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match &self.tmux {
                Some(value) => std::env::set_var("TMUX", value),
                None => std::env::remove_var("TMUX"),
            }
            match &self.term_program {
                Some(value) => std::env::set_var("TERM_PROGRAM", value),
                None => std::env::remove_var("TERM_PROGRAM"),
            }
            match &self.term {
                Some(value) => std::env::set_var("TERM", value),
                None => std::env::remove_var("TERM"),
            }
        }
    }

    #[test]
    fn test_detect_parent_app_preserves_host_when_tmux_set() {
        let guard = EnvGuard::acquire();
        guard.set_var("TMUX", "/tmp/tmux-123");
        guard.set_var("TERM_PROGRAM", "cursor");

        let app = detect_parent_app(12345);
        assert_eq!(app, ParentApp::Cursor);
    }

    fn unique_temp_path(suffix: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("current time should be after epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("hud-hook-cwd-{suffix}-{nanos}"))
    }

    #[test]
    fn test_normalize_path_canonicalizes_existing_case_variants() {
        let root = unique_temp_path("canonicalize");
        let actual = root.join("CoDe").join("openclaw");
        fs::create_dir_all(&actual).expect("create mixed-case directory tree");

        let alias = root.join("code").join("openclaw");
        let alias_string = alias.to_string_lossy().to_string();
        let normalized = normalize_path(&alias_string);

        if alias.exists() {
            assert_eq!(
                normalized,
                actual.to_string_lossy().to_string(),
                "existing case variants should canonicalize to a stable path identity",
            );
        } else {
            assert_eq!(
                normalized, alias_string,
                "on case-sensitive filesystems, unknown-case aliases must fall back to raw path",
            );
        }

        fs::remove_dir_all(&root).expect("cleanup mixed-case directory tree");
    }
}
