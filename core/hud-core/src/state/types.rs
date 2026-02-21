//! Serialized state types used by the hook/state pipeline.
//!
//! **Breaking changes are allowed** (single-user project). Current on-disk format is v3.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

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
    #[serde(default)]
    pub transcript_path: Option<String>,
    pub cwd: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
    pub trigger: Option<String>,
    #[serde(default)]
    pub prompt: Option<String>,
    #[serde(default)]
    pub custom_instructions: Option<String>,
    pub notification_type: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    pub stop_hook_active: Option<bool>,
    #[serde(default)]
    pub last_assistant_message: Option<String>,
    pub tool_name: Option<String>,
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub tool_input: Option<ToolInput>,
    #[serde(default)]
    pub tool_response: Option<ToolResponse>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub is_interrupt: Option<bool>,
    #[serde(default)]
    pub permission_suggestions: Option<Value>,
    #[serde(default)]
    pub source: Option<Value>,
    #[serde(default)]
    pub reason: Option<Value>,
    #[serde(default)]
    pub model: Option<String>,
    pub agent_id: Option<String>,
    #[serde(default)]
    pub agent_type: Option<String>,
    pub agent_transcript_path: Option<String>,
    #[serde(default)]
    pub teammate_name: Option<String>,
    #[serde(default)]
    pub team_name: Option<String>,
    #[serde(default)]
    pub task_id: Option<String>,
    #[serde(default)]
    pub task_subject: Option<String>,
    #[serde(default)]
    pub task_description: Option<String>,
    #[serde(default, flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// Tool input fields (file paths from Edit, Write, Read, etc.)
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct ToolInput {
    pub file_path: Option<String>,
    pub path: Option<String>,
    #[serde(default, flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// Tool response fields
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct ToolResponse {
    #[serde(rename = "filePath")]
    pub file_path: Option<String>,
    #[serde(default, flatten)]
    pub extra: BTreeMap<String, Value>,
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
    PostToolUseFailure {
        tool_name: Option<String>,
        file_path: Option<String>,
    },
    PermissionRequest,
    PreCompact,
    Notification {
        notification_type: String,
    },
    SubagentStart,
    SubagentStop,
    Stop {
        stop_hook_active: bool,
    },
    TeammateIdle,
    TaskCompleted,
    WorktreeCreate,
    WorktreeRemove,
    ConfigChange,
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
            "PostToolUseFailure" => {
                let file_path = tool_input_file_path().or_else(|| {
                    self.tool_response
                        .as_ref()
                        .and_then(|tr| tr.file_path.clone())
                });

                HookEvent::PostToolUseFailure {
                    tool_name: self.tool_name.clone(),
                    file_path,
                }
            }
            "PermissionRequest" => HookEvent::PermissionRequest,
            "PreCompact" => HookEvent::PreCompact,
            "Notification" => HookEvent::Notification {
                notification_type: self.notification_type.clone().unwrap_or_default(),
            },
            "SubagentStart" => HookEvent::SubagentStart,
            "SubagentStop" => HookEvent::SubagentStop,
            "Stop" => HookEvent::Stop {
                stop_hook_active: self.stop_hook_active.unwrap_or(false),
            },
            "TeammateIdle" => HookEvent::TeammateIdle,
            "TaskCompleted" => HookEvent::TaskCompleted,
            "WorktreeCreate" => HookEvent::WorktreeCreate,
            "WorktreeRemove" => HookEvent::WorktreeRemove,
            "ConfigChange" => HookEvent::ConfigChange,
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

    /// Build event metadata from documented hook fields and unknown passthrough fields.
    pub fn to_metadata_map(&self) -> Map<String, Value> {
        let mut metadata = Map::new();

        insert_trimmed_str(
            &mut metadata,
            "transcript_path",
            self.transcript_path.as_deref(),
        );
        insert_trimmed_str(
            &mut metadata,
            "permission_mode",
            self.permission_mode.as_deref(),
        );
        insert_trimmed_str(&mut metadata, "trigger", self.trigger.as_deref());
        insert_trimmed_str(&mut metadata, "prompt", self.prompt.as_deref());
        insert_trimmed_str(
            &mut metadata,
            "custom_instructions",
            self.custom_instructions.as_deref(),
        );
        insert_trimmed_str(
            &mut metadata,
            "notification_type",
            self.notification_type.as_deref(),
        );
        insert_trimmed_str(&mut metadata, "message", self.message.as_deref());
        insert_trimmed_str(&mut metadata, "title", self.title.as_deref());
        if let Some(stop_hook_active) = self.stop_hook_active {
            metadata.insert(
                "stop_hook_active".to_string(),
                Value::Bool(stop_hook_active),
            );
        }
        insert_trimmed_str(
            &mut metadata,
            "last_assistant_message",
            self.last_assistant_message.as_deref(),
        );
        insert_trimmed_str(&mut metadata, "tool_name", self.tool_name.as_deref());
        insert_trimmed_str(&mut metadata, "tool_use_id", self.tool_use_id.as_deref());
        insert_trimmed_str(&mut metadata, "error", self.error.as_deref());
        if let Some(is_interrupt) = self.is_interrupt {
            metadata.insert("is_interrupt".to_string(), Value::Bool(is_interrupt));
        }
        insert_trimmed_str(&mut metadata, "model", self.model.as_deref());
        insert_trimmed_str(&mut metadata, "agent_id", self.agent_id.as_deref());
        insert_trimmed_str(&mut metadata, "agent_type", self.agent_type.as_deref());
        insert_trimmed_str(
            &mut metadata,
            "agent_transcript_path",
            self.agent_transcript_path.as_deref(),
        );
        insert_trimmed_str(
            &mut metadata,
            "teammate_name",
            self.teammate_name.as_deref(),
        );
        insert_trimmed_str(&mut metadata, "team_name", self.team_name.as_deref());
        insert_trimmed_str(&mut metadata, "task_id", self.task_id.as_deref());
        insert_trimmed_str(&mut metadata, "task_subject", self.task_subject.as_deref());
        insert_trimmed_str(
            &mut metadata,
            "task_description",
            self.task_description.as_deref(),
        );

        if let Some(source) = &self.source {
            metadata.insert("source".to_string(), source.clone());
        }
        if let Some(reason) = &self.reason {
            metadata.insert("reason".to_string(), reason.clone());
        }
        if let Some(permission_suggestions) = &self.permission_suggestions {
            metadata.insert(
                "permission_suggestions".to_string(),
                permission_suggestions.clone(),
            );
        }

        if let Some(tool_input) = &self.tool_input {
            if let Ok(value) = serde_json::to_value(tool_input) {
                if !value_is_empty_object(&value) {
                    metadata.insert("tool_input".to_string(), value);
                }
            }
        }
        if let Some(tool_response) = &self.tool_response {
            if let Ok(value) = serde_json::to_value(tool_response) {
                if !value_is_empty_object(&value) {
                    metadata.insert("tool_response".to_string(), value);
                }
            }
        }

        for (key, value) in &self.extra {
            metadata.entry(key.clone()).or_insert_with(|| value.clone());
        }

        metadata
    }
}

fn insert_trimmed_str(map: &mut Map<String, Value>, key: &str, value: Option<&str>) {
    if let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) {
        map.insert(key.to_string(), Value::String(value.to_string()));
    }
}

fn value_is_empty_object(value: &Value) -> bool {
    match value {
        Value::Object(object) => object.is_empty(),
        _ => false,
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
            transcript_path: None,
            cwd: None,
            permission_mode: None,
            trigger: None,
            prompt: None,
            custom_instructions: None,
            notification_type: None,
            message: None,
            title: None,
            stop_hook_active: None,
            last_assistant_message: None,
            tool_name: None,
            tool_use_id: None,
            tool_input: None,
            tool_response: None,
            error: None,
            is_interrupt: None,
            permission_suggestions: None,
            source: None,
            reason: None,
            model: None,
            agent_id: None,
            agent_type: None,
            agent_transcript_path: None,
            teammate_name: None,
            team_name: None,
            task_id: None,
            task_subject: None,
            task_description: None,
            extra: BTreeMap::new(),
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
            ..ToolInput::default()
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
            ..ToolInput::default()
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

    #[test]
    fn post_tool_use_failure_preserves_file_path_from_tool_input() {
        let mut input = base_input();
        input.hook_event_name = Some("PostToolUseFailure".to_string());
        input.tool_name = Some("Edit".to_string());
        input.tool_input = Some(ToolInput {
            file_path: Some("apps/docs/src/error.md".to_string()),
            path: None,
            ..ToolInput::default()
        });

        let event = input.to_event().expect("event");

        match event {
            HookEvent::PostToolUseFailure {
                tool_name,
                file_path,
            } => {
                assert_eq!(tool_name, Some("Edit".to_string()));
                assert_eq!(file_path, Some("apps/docs/src/error.md".to_string()));
            }
            _ => panic!("expected PostToolUseFailure"),
        }
    }

    #[test]
    fn deserializes_session_start_when_source_is_object() {
        let input: HookInput = serde_json::from_str(
            r#"{
                "hook_event_name":"SessionStart",
                "session_id":"sess-1",
                "cwd":"/Users/petepetrash/Code/capacitor",
                "source":{"type":"startup"}
            }"#,
        )
        .expect("HookInput should accept object source");

        assert_eq!(input.to_event(), Some(HookEvent::SessionStart));
    }

    #[test]
    fn deserializes_session_start_when_reason_is_object() {
        let input: HookInput = serde_json::from_str(
            r#"{
                "hook_event_name":"SessionStart",
                "session_id":"sess-2",
                "cwd":"/Users/petepetrash/Code/capacitor",
                "reason":{"kind":"resume"}
            }"#,
        )
        .expect("HookInput should accept object reason");

        assert_eq!(input.to_event(), Some(HookEvent::SessionStart));
    }

    #[test]
    fn hook_metadata_map_captures_documented_and_unknown_fields() {
        let input: HookInput = serde_json::from_str(
            r#"{
                "hook_event_name":"TaskCompleted",
                "session_id":"sess-3",
                "transcript_path":"/tmp/transcript.jsonl",
                "cwd":"/Users/petepetrash/Code/capacitor",
                "permission_mode":"acceptEdits",
                "tool_name":"Edit",
                "tool_use_id":"toolu_123",
                "prompt":"Please fix flaky CI tests",
                "trigger":"manual",
                "source":{"type":"startup"},
                "reason":{"kind":"resume"},
                "agent_id":"agent-42",
                "agent_type":"Explore",
                "agent_transcript_path":"/tmp/subagent.jsonl",
                "message":"Claude needs your permission to use Bash",
                "title":"Permission needed",
                "notification_type":"permission_prompt",
                "last_assistant_message":"Done",
                "teammate_name":"implementer",
                "team_name":"my-project",
                "task_id":"task-001",
                "task_subject":"Fix flaky tests",
                "task_description":"Stabilize integration tests in CI",
                "custom_instructions":"compact this",
                "error":"Command exited with non-zero status code 1",
                "is_interrupt":false,
                "permission_suggestions":[{"type":"toolAlwaysAllow","tool":"Bash"}],
                "tool_input":{"path":"src/main.rs","command":"npm test"},
                "tool_response":{"filePath":"src/main.rs"},
                "future_field":"future-value"
            }"#,
        )
        .expect("HookInput should deserialize richer documented payload");

        let metadata = input.to_metadata_map();

        assert_eq!(
            metadata.get("transcript_path").and_then(|v| v.as_str()),
            Some("/tmp/transcript.jsonl")
        );
        assert_eq!(
            metadata.get("permission_mode").and_then(|v| v.as_str()),
            Some("acceptEdits")
        );
        assert_eq!(
            metadata.get("prompt").and_then(|v| v.as_str()),
            Some("Please fix flaky CI tests")
        );
        assert_eq!(
            metadata.get("agent_type").and_then(|v| v.as_str()),
            Some("Explore")
        );
        assert_eq!(
            metadata.get("error").and_then(|v| v.as_str()),
            Some("Command exited with non-zero status code 1")
        );
        assert_eq!(
            metadata.get("is_interrupt").and_then(|v| v.as_bool()),
            Some(false)
        );
        assert_eq!(
            metadata.get("task_subject").and_then(|v| v.as_str()),
            Some("Fix flaky tests")
        );
        assert_eq!(
            metadata
                .get("tool_input")
                .and_then(|v| v.get("command"))
                .and_then(|v| v.as_str()),
            Some("npm test")
        );
        assert_eq!(
            metadata.get("future_field").and_then(|v| v.as_str()),
            Some("future-value")
        );
    }
}

// -----------------------------------------------------------------------------
// Canonical hook→state mapping (implemented in the daemon reducer)
//
// SessionStart           → ready
// UserPromptSubmit       → working
// PreToolUse             → working  (heartbeat if already working)
// PostToolUse            → working  (+ tracks file activity)
// PostToolUseFailure     → working  (no file activity entry)
// PermissionRequest      → waiting
// Notification           → ready/waiting (idle_prompt|auth_success => ready, permission_prompt|elicitation_dialog => waiting)
// PreCompact             → compacting
// Stop                   → ready    (ignored if stop_hook_active=true)
// TaskCompleted          → ready    (main agent only; teammate/subagent completions ignored)
// SessionEnd             → removes session record
// SubagentStop           → ignored  (implemented via agent_id metadata filtering)
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
    pub prompt: Option<String>,
    #[serde(default)]
    pub source: Option<serde_json::Value>,
    #[serde(default)]
    pub reason: Option<serde_json::Value>,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
    #[serde(default)]
    pub custom_instructions: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub is_interrupt: Option<bool>,
    #[serde(default)]
    pub stop_hook_active: Option<bool>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub last_assistant_message: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub agent_type: Option<String>,
    #[serde(default)]
    pub agent_transcript_path: Option<String>,
    #[serde(default)]
    pub teammate_name: Option<String>,
    #[serde(default)]
    pub team_name: Option<String>,
    #[serde(default)]
    pub task_id: Option<String>,
    #[serde(default)]
    pub task_subject: Option<String>,
    #[serde(default)]
    pub task_description: Option<String>,
    #[serde(default)]
    pub permission_suggestions: Option<serde_json::Value>,
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
