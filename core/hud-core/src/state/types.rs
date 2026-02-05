//! Serialized state types used by the hook/state pipeline.
//!
//! **Breaking changes are allowed** (single-user project). Current on-disk format is v3.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::types::SessionState;

// =============================================================================
// Hook Input Types (JSON from Claude Code hooks)
// =============================================================================

/// Raw JSON input from Claude Code hooks.
///
/// This struct captures all fields that Claude Code might send. Fields are optional
/// because different events include different data.
#[derive(Debug, Clone, Deserialize)]
pub struct HookInput {
    pub hook_event_name: Option<String>,
    pub session_id: Option<String>,
    pub cwd: Option<String>,
    pub trigger: Option<String>,
    pub notification_type: Option<String>,
    pub stop_hook_active: Option<bool>,
    pub tool_name: Option<String>,
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub tool_input: Option<ToolInput>,
    #[serde(default)]
    pub tool_response: Option<ToolResponse>,
    pub source: Option<String>,
    pub reason: Option<String>,
    pub agent_id: Option<String>,
    pub agent_transcript_path: Option<String>,
}

/// Tool input fields (file paths from Edit, Write, Read, etc.)
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ToolInput {
    pub file_path: Option<String>,
    pub path: Option<String>,
}

/// Tool response fields
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ToolResponse {
    #[serde(rename = "filePath")]
    pub file_path: Option<String>,
}

/// Parsed hook event with associated data.
#[derive(Debug, Clone, PartialEq)]
pub enum HookEvent {
    SessionStart,
    SessionEnd,
    UserPromptSubmit,
    PreToolUse {
        tool_name: Option<String>,
        file_path: Option<String>,
    },
    PostToolUse {
        tool_name: Option<String>,
        file_path: Option<String>,
    },
    PermissionRequest,
    PreCompact,
    Notification {
        notification_type: String,
    },
    Stop {
        stop_hook_active: bool,
    },
    Unknown {
        event_name: String,
    },
}

impl HookInput {
    /// Parse a HookEvent from the raw input.
    pub fn to_event(&self) -> Option<HookEvent> {
        let event_name = self.hook_event_name.as_deref()?;
        let tool_input_file_path = || {
            self.tool_input
                .as_ref()
                .and_then(|ti| ti.file_path.clone().or_else(|| ti.path.clone()))
        };

        Some(match event_name {
            "SessionStart" => HookEvent::SessionStart,
            "SessionEnd" => HookEvent::SessionEnd,
            "UserPromptSubmit" => HookEvent::UserPromptSubmit,
            "PreToolUse" => HookEvent::PreToolUse {
                tool_name: self.tool_name.clone(),
                file_path: tool_input_file_path(),
            },
            "PostToolUse" => {
                // Resolve file path from multiple possible locations
                let file_path = tool_input_file_path().or_else(|| {
                    self.tool_response
                        .as_ref()
                        .and_then(|tr| tr.file_path.clone())
                });

                HookEvent::PostToolUse {
                    tool_name: self.tool_name.clone(),
                    file_path,
                }
            }
            "PermissionRequest" => HookEvent::PermissionRequest,
            "PreCompact" => HookEvent::PreCompact,
            "Notification" => HookEvent::Notification {
                notification_type: self.notification_type.clone().unwrap_or_default(),
            },
            "Stop" => HookEvent::Stop {
                stop_hook_active: self.stop_hook_active.unwrap_or(false),
            },
            _ => HookEvent::Unknown {
                event_name: event_name.to_string(),
            },
        })
    }

    /// Resolve the working directory, with fallbacks.
    pub fn resolve_cwd(&self, current_cwd: Option<&str>) -> Option<String> {
        // Priority: input cwd > env CLAUDE_PROJECT_DIR > existing cwd > env PWD
        self.cwd
            .clone()
            .or_else(|| std::env::var("CLAUDE_PROJECT_DIR").ok())
            .or_else(|| current_cwd.map(|s| s.to_string()))
            .or_else(|| std::env::var("PWD").ok())
            .map(|cwd| normalize_path(&cwd))
    }
}

/// Normalize a path: strip trailing slashes (except for root "/").
fn normalize_path(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        "/".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_input() -> HookInput {
        HookInput {
            hook_event_name: None,
            session_id: None,
            cwd: None,
            trigger: None,
            notification_type: None,
            stop_hook_active: None,
            tool_name: None,
            tool_use_id: None,
            tool_input: None,
            tool_response: None,
            source: None,
            reason: None,
            agent_id: None,
            agent_transcript_path: None,
        }
    }

    #[test]
    fn pre_tool_use_preserves_file_path_from_tool_input() {
        let mut input = base_input();
        input.hook_event_name = Some("PreToolUse".to_string());
        input.tool_name = Some("Edit".to_string());
        input.tool_input = Some(ToolInput {
            file_path: Some("apps/docs/src/index.md".to_string()),
            path: None,
        });

        let event = input.to_event().expect("event");

        match event {
            HookEvent::PreToolUse {
                tool_name,
                file_path,
            } => {
                assert_eq!(tool_name, Some("Edit".to_string()));
                assert_eq!(file_path, Some("apps/docs/src/index.md".to_string()));
            }
            _ => panic!("expected PreToolUse"),
        }
    }

    #[test]
    fn pre_tool_use_preserves_file_path_from_tool_input_path() {
        let mut input = base_input();
        input.hook_event_name = Some("PreToolUse".to_string());
        input.tool_name = Some("Read".to_string());
        input.tool_input = Some(ToolInput {
            file_path: None,
            path: Some("apps/docs/src/path.md".to_string()),
        });

        let event = input.to_event().expect("event");

        match event {
            HookEvent::PreToolUse {
                tool_name,
                file_path,
            } => {
                assert_eq!(tool_name, Some("Read".to_string()));
                assert_eq!(file_path, Some("apps/docs/src/path.md".to_string()));
            }
            _ => panic!("expected PreToolUse"),
        }
    }
}

// -----------------------------------------------------------------------------
// Canonical hook→state mapping (implemented in the daemon reducer)
//
// SessionStart           → ready
// UserPromptSubmit       → working
// PreToolUse             → working  (heartbeat if already working)
// PostToolUse            → working  (+ tracks file activity)
// PermissionRequest      → waiting
// Notification           → ready    (only idle_prompt type; others ignored)
// PreCompact             → compacting
// Stop                   → ready    (ignored if stop_hook_active=true)
// SessionEnd             → removes session record
// SubagentStop           → ignored  (metadata only, no state change)
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

impl SessionRecord {}
