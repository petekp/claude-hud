//! Event handler for Claude Code hooks.
//!
//! Reads JSON from stdin, parses the hook event, and updates session state.
//!
//! ## State Machine
//!
//! ```text
//! SessionStart           → ready
//! UserPromptSubmit       → working
//! PreToolUse/PostToolUse → working  (heartbeat if already working)
//! PermissionRequest      → waiting
//! Notification           → ready    (only idle_prompt type)
//! PreCompact             → compacting
//! Stop                   → ready    (unless stop_hook_active=true)
//! SessionEnd             → removes session record
//! ```

use chrono::Utc;
use fs_err as fs;
use hud_core::state::{HookEvent, HookInput};
use hud_core::types::SessionState;
use std::env;
use std::io::{self, Read};
use std::path::Path;

pub fn run() -> Result<(), String> {
    // Skip if this is a summary generation subprocess
    if env::var("HUD_SUMMARY_GEN")
        .map(|v| v == "1")
        .unwrap_or(false)
    {
        // Drain stdin and exit
        let _ = io::stdin().read_to_end(&mut Vec::new());
        return Ok(());
    }

    // Read JSON from stdin
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| format!("Failed to read stdin: {}", e))?;

    if input.trim().is_empty() {
        return Ok(());
    }

    // Parse the hook input
    let hook_input: HookInput =
        serde_json::from_str(&input).map_err(|e| format!("Failed to parse hook input: {}", e))?;

    handle_hook_input(hook_input)
}

fn handle_hook_input(hook_input: HookInput) -> Result<(), String> {
    let home = dirs::home_dir().ok_or("Cannot determine home directory")?;
    handle_hook_input_with_home(hook_input, &home)
}

fn handle_hook_input_with_home(hook_input: HookInput, home: &Path) -> Result<(), String> {
    let event = match hook_input.to_event() {
        Some(e) => e,
        None => return Ok(()),
    };

    let session_id = match &hook_input.session_id {
        Some(id) => id.clone(),
        None => {
            tracing::debug!(
                event = ?hook_input.hook_event_name,
                "Skipping event (missing session_id)"
            );
            return Ok(());
        }
    };

    if !crate::daemon_client::daemon_enabled() {
        return Err("Daemon disabled".to_string());
    }

    let cwd = hook_input.resolve_cwd(None);
    let (action, _new_state, _file_activity) = process_event(&event, None, &hook_input);

    if cwd.is_none() && action != Action::Delete {
        tracing::debug!(
            event = ?hook_input.hook_event_name,
            session = %session_id,
            "Skipping event (missing cwd)"
        );
        return Ok(());
    }

    let cwd = cwd.unwrap_or_default();
    let claude_pid = std::process::id();
    let ppid = get_ppid().unwrap_or(claude_pid);

    let daemon_sent = crate::daemon_client::send_handle_event(&event, &session_id, ppid, &cwd);
    if daemon_sent {
        touch_heartbeat(home);
        tracing::debug!(
            event = ?hook_input.hook_event_name,
            session = %session_id,
            "Daemon accepted event"
        );
        return Ok(());
    }

    Err("Failed to send hook event to daemon".to_string())
}

#[derive(Debug, PartialEq)]
enum Action {
    Upsert,
    Heartbeat,
    Delete,
    Skip,
}

/// Returns true if the session is in an active state that shouldn't be overridden.
fn is_active_state(state: Option<SessionState>) -> bool {
    matches!(
        state,
        Some(SessionState::Working) | Some(SessionState::Waiting) | Some(SessionState::Compacting)
    )
}

fn process_event(
    event: &HookEvent,
    current_state: Option<SessionState>,
    _input: &HookInput,
) -> (Action, Option<SessionState>, Option<(String, String)>) {
    match event {
        HookEvent::SessionStart => {
            if is_active_state(current_state) {
                (Action::Skip, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Ready), None)
            }
        }

        HookEvent::UserPromptSubmit => (Action::Upsert, Some(SessionState::Working), None),

        HookEvent::PreToolUse { .. } => {
            if current_state == Some(SessionState::Working) {
                (Action::Heartbeat, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Working), None)
            }
        }

        HookEvent::PostToolUse { .. } => {
            if current_state == Some(SessionState::Working) {
                (Action::Heartbeat, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Working), None)
            }
        }

        HookEvent::PermissionRequest => (Action::Upsert, Some(SessionState::Waiting), None),

        HookEvent::PreCompact => (Action::Upsert, Some(SessionState::Compacting), None),

        HookEvent::Notification { notification_type } => {
            if notification_type == "idle_prompt" {
                (Action::Upsert, Some(SessionState::Ready), None)
            } else {
                (Action::Skip, None, None)
            }
        }

        HookEvent::Stop { stop_hook_active } => {
            if *stop_hook_active {
                (Action::Skip, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Ready), None)
            }
        }

        HookEvent::SessionEnd => (Action::Delete, None, None),

        HookEvent::Unknown { event_name } => {
            tracing::debug!(event_name = %event_name, "Unhandled event");
            (Action::Skip, None, None)
        }
    }
}

fn get_ppid() -> Option<u32> {
    #[cfg(unix)]
    {
        // SAFETY: getppid() is a simple syscall that returns the parent process ID.
        // It has no failure modes and always returns a valid PID (1 if parent exited).
        #[allow(unsafe_code)]
        Some(unsafe { libc::getppid() } as u32)
    }
    #[cfg(not(unix))]
    {
        None
    }
}

fn touch_heartbeat(home: &Path) {
    let heartbeat_path = home.join(".capacitor/hud-hook-heartbeat");

    if let Some(parent) = heartbeat_path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    use fs_err::OpenOptions;
    use std::io::Write as _;

    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&heartbeat_path)
    {
        let _ = writeln!(file, "{}", Utc::now().timestamp());
    }
}
