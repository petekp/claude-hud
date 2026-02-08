//! HudEngine - The main entry point for Claude HUD clients.
//!
//! The HudEngine provides a unified, client-agnostic API for all HUD functionality.
//! It's designed to be:
//! - **Synchronous**: No async runtime required
//! - **Client-agnostic**: Works with Swift, TUI, mobile, etc.
//! - **Stateless**: Each call is independent (caching happens at lower levels)
//! - **Stable**: Prefer additive API changes to avoid breaking FFI clients
//!
//! ## Example Usage
//!
//! ```rust,ignore
//! use hud_core::HudEngine;
//!
//! let engine = HudEngine::new().expect("Failed to initialize");
//! let projects = engine.list_projects().unwrap_or_default();
//! let states = engine.get_all_session_states(&projects);
//! ```

use crate::agents::{AgentConfig, AgentRegistry, AgentSession};
use crate::artifacts::{collect_artifacts_from_dir, count_artifacts_in_dir, count_hooks_in_dir};
use crate::config::{load_hud_config_with_storage, resolve_symlink, save_hud_config_with_storage};
use crate::error::HudFfiError;
use crate::projects::{has_project_indicators, load_projects_with_storage};
use crate::sessions::{
    detect_session_state_with_storage, get_all_session_states_with_storage, read_project_status,
    ProjectStatus,
};
use crate::setup::{DependencyStatus, HookStatus, InstallResult, SetupChecker, SetupStatus};
use crate::storage::StorageConfig;
use crate::types::{
    Artifact, DashboardData, GlobalConfig, HookDiagnosticReport, HookIssue, HookTestResult,
    HudConfig, Plugin, PluginManifest, Project, ProjectSessionState, SuggestedProject,
};
use crate::validation::{create_claude_md, validate_project_path, ValidationResultFfi};
use fs_err as fs;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

/// The main engine for Claude HUD operations.
///
/// Provides a unified API for all HUD functionality, suitable for any client type.
/// This is the primary FFI interface for Swift/Kotlin/Python clients.
#[derive(uniffi::Object)]
pub struct HudEngine {
    storage: StorageConfig,
    agent_registry: Arc<AgentRegistry>,
}

impl HudEngine {
    /// Creates a new HudEngine instance with custom storage configuration.
    ///
    /// Used for testing with temp directories or custom storage locations.
    /// Not exposed to FFI - use `new()` for external clients.
    pub fn with_storage(storage: StorageConfig) -> Result<Self, HudFfiError> {
        let agent_config = AgentConfig::default();
        let agent_registry = Arc::new(AgentRegistry::new(agent_config));
        agent_registry.initialize_all();

        Ok(Self {
            storage,
            agent_registry,
        })
    }

    /// Returns the StorageConfig for this engine.
    /// Useful for accessing path configuration.
    pub fn storage(&self) -> &StorageConfig {
        &self.storage
    }
}

fn heartbeat_status(
    age_secs: u64,
    threshold_secs: u64,
    grace_secs: u64,
    has_active_session: bool,
) -> crate::types::HookHealthStatus {
    if age_secs <= threshold_secs {
        return crate::types::HookHealthStatus::Healthy;
    }

    if has_active_session && age_secs <= grace_secs {
        return crate::types::HookHealthStatus::Healthy;
    }

    crate::types::HookHealthStatus::Stale {
        last_seen_secs: age_secs,
    }
}

fn has_active_daemon_session(
    snapshot: Option<&crate::state::daemon::DaemonSessionsSnapshot>,
) -> bool {
    let snapshot = match snapshot {
        Some(snapshot) => snapshot,
        None => return false,
    };

    snapshot.sessions().iter().any(|record| {
        let is_alive = record.is_alive.unwrap_or(true);
        let is_active = !matches!(record.state.to_ascii_lowercase().as_str(), "idle");
        is_alive && is_active
    })
}

#[uniffi::export]
impl HudEngine {
    /// Creates a new HudEngine instance with default storage configuration.
    ///
    /// Uses `~/.capacitor/` for Capacitor data and `~/.claude/` for Claude data.
    #[uniffi::constructor]
    pub fn new() -> Result<Self, HudFfiError> {
        Self::with_storage(StorageConfig::default())
    }

    /// Returns the path to the Claude directory as a string.
    /// This is the Claude Code data directory (~/.claude by default).
    pub fn claude_dir(&self) -> String {
        self.storage.claude_root().to_string_lossy().to_string()
    }

    /// Returns the path to the Capacitor data directory as a string.
    /// This is where Capacitor stores its own data (~/.capacitor by default).
    pub fn capacitor_dir(&self) -> String {
        self.storage.root().to_string_lossy().to_string()
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Projects API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Lists all pinned projects, sorted by most recent activity.
    pub fn list_projects(&self) -> Result<Vec<Project>, HudFfiError> {
        load_projects_with_storage(&self.storage).map_err(HudFfiError::from)
    }

    /// Gets the HUD configuration (pinned projects, terminal app, etc.)
    pub fn get_config(&self) -> HudConfig {
        load_hud_config_with_storage(&self.storage)
    }

    /// Adds a project to the pinned projects list.
    pub fn add_project(&self, path: String) -> Result<(), HudFfiError> {
        let mut config = load_hud_config_with_storage(&self.storage);

        if !std::path::Path::new(&path).exists() {
            return Err(HudFfiError::from(format!("Path does not exist: {}", path)));
        }

        if config.pinned_projects.contains(&path) {
            return Err(HudFfiError::from(format!(
                "Project already pinned: {}",
                path
            )));
        }

        config.pinned_projects.push(path);
        save_hud_config_with_storage(&self.storage, &config).map_err(HudFfiError::from)
    }

    /// Removes a project from the pinned projects list.
    pub fn remove_project(&self, path: String) -> Result<(), HudFfiError> {
        let mut config = load_hud_config_with_storage(&self.storage);
        config.pinned_projects.retain(|p| p != &path);
        save_hud_config_with_storage(&self.storage, &config).map_err(HudFfiError::from)
    }

    /// Discovers suggested projects based on activity in ~/.claude/projects.
    pub fn get_suggested_projects(&self) -> Result<Vec<SuggestedProject>, HudFfiError> {
        let projects_dir = self.storage.claude_root().join("projects");
        if !projects_dir.exists() {
            return Ok(Vec::new());
        }

        let config = load_hud_config_with_storage(&self.storage);
        let pinned_set: std::collections::HashSet<_> = config.pinned_projects.iter().collect();

        let mut suggestions: Vec<(SuggestedProject, u32)> = Vec::new();

        if let Ok(entries) = fs::read_dir(&projects_dir) {
            for entry in entries.filter_map(|e| e.ok()) {
                if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    continue;
                }

                let encoded_name = entry.file_name().to_string_lossy().to_string();

                // Try to resolve the encoded path
                if let Some(real_path) = crate::projects::try_resolve_encoded_path(&encoded_name) {
                    if pinned_set.contains(&real_path) {
                        continue;
                    }

                    let project_path = PathBuf::from(&real_path);
                    let has_indicators = has_project_indicators(&project_path);
                    let has_claude_md = project_path.join("CLAUDE.md").exists();

                    let task_count = fs::read_dir(entry.path())
                        .map(|entries| {
                            entries
                                .filter_map(|e| e.ok())
                                .filter(|e| e.path().extension().is_some_and(|ext| ext == "jsonl"))
                                .count() as u32
                        })
                        .unwrap_or(0);

                    let display_path = if real_path.starts_with("/Users/") {
                        format!(
                            "~/{}",
                            real_path.split('/').skip(3).collect::<Vec<_>>().join("/")
                        )
                    } else {
                        real_path.clone()
                    };

                    let name = real_path
                        .split('/')
                        .next_back()
                        .unwrap_or(&real_path)
                        .to_string();

                    suggestions.push((
                        SuggestedProject {
                            path: real_path,
                            display_path,
                            name,
                            task_count,
                            has_claude_md,
                            has_project_indicators: has_indicators,
                        },
                        task_count,
                    ));
                }
            }
        }

        suggestions.sort_by(|a, b| b.1.cmp(&a.1));
        Ok(suggestions.into_iter().map(|(s, _)| s).collect())
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Session State API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Gets the session state for a single project.
    /// Uses daemon session snapshots for reliable state.
    pub fn get_session_state(&self, project_path: String) -> ProjectSessionState {
        detect_session_state_with_storage(&self.storage, &project_path)
    }

    /// Gets session states for multiple projects.
    /// Uses daemon session snapshots for reliable state.
    ///
    /// Takes a Vec instead of slice for FFI compatibility.
    pub fn get_all_session_states(
        &self,
        projects: Vec<Project>,
    ) -> HashMap<String, ProjectSessionState> {
        let paths: Vec<String> = projects.iter().map(|p| p.path.clone()).collect();
        get_all_session_states_with_storage(&self.storage, &paths)
    }

    /// Gets project status from .claude/hud-status.json.
    pub fn get_project_status(&self, project_path: String) -> Option<ProjectStatus> {
        read_project_status(&project_path)
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Multi-Agent API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Detects all agent sessions for a project path.
    ///
    /// Returns sessions from all installed agents (Claude, Codex, Aider, etc.)
    /// that have active sessions at the given path or its children.
    pub fn get_agent_sessions(&self, project_path: String) -> Vec<AgentSession> {
        self.agent_registry.detect_all_sessions(&project_path)
    }

    /// Detects the primary agent session for a project path.
    ///
    /// Returns the first session found based on user preference order.
    /// Use this when you only need to display one agent's state.
    pub fn get_primary_agent_session(&self, project_path: String) -> Option<AgentSession> {
        self.agent_registry.detect_primary_session(&project_path)
    }

    /// Gets all agent sessions across all projects (cached).
    ///
    /// Uses mtime-based caching for efficient repeated calls.
    /// Call `invalidate_agent_cache()` to force a refresh.
    pub fn get_all_agent_sessions(&self) -> Vec<AgentSession> {
        self.agent_registry.all_sessions_cached()
    }

    /// Invalidates the agent session cache.
    ///
    /// Call this when you know the underlying state has changed
    /// and want to force a fresh read on the next call.
    pub fn invalidate_agent_cache(&self) {
        self.agent_registry.invalidate_all_caches();
    }

    /// Returns the list of installed agent IDs.
    ///
    /// Useful for debugging and UI display of which agents are available.
    pub fn list_installed_agents(&self) -> Vec<String> {
        self.agent_registry
            .installed_agents()
            .iter()
            .map(|a| a.id().to_string())
            .collect()
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Artifacts API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Lists all artifacts (skills, commands, agents) from global and plugin sources.
    pub fn list_artifacts(&self) -> Vec<Artifact> {
        let mut artifacts = Vec::new();

        // Global artifacts
        if let Some(skills_dir) = resolve_symlink(&self.storage.claude_root().join("skills")) {
            artifacts.extend(collect_artifacts_from_dir(&skills_dir, "skill", "Global"));
        }
        if let Some(commands_dir) = resolve_symlink(&self.storage.claude_root().join("commands")) {
            artifacts.extend(collect_artifacts_from_dir(
                &commands_dir,
                "command",
                "Global",
            ));
        }
        if let Some(agents_dir) = resolve_symlink(&self.storage.claude_root().join("agents")) {
            artifacts.extend(collect_artifacts_from_dir(&agents_dir, "agent", "Global"));
        }

        // Plugin artifacts
        if let Ok(plugins) = self.list_plugins() {
            for plugin in plugins {
                if plugin.enabled {
                    let plugin_path = PathBuf::from(&plugin.path);
                    artifacts.extend(collect_artifacts_from_dir(
                        &plugin_path.join("skills"),
                        "skill",
                        &plugin.name,
                    ));
                    artifacts.extend(collect_artifacts_from_dir(
                        &plugin_path.join("commands"),
                        "command",
                        &plugin.name,
                    ));
                    artifacts.extend(collect_artifacts_from_dir(
                        &plugin_path.join("agents"),
                        "agent",
                        &plugin.name,
                    ));
                }
            }
        }

        // Sort by type first, then by name (matching lib.rs behavior)
        artifacts.sort_by(|a, b| {
            let type_order = a.artifact_type.cmp(&b.artifact_type);
            if type_order == std::cmp::Ordering::Equal {
                a.name.to_lowercase().cmp(&b.name.to_lowercase())
            } else {
                type_order
            }
        });
        artifacts
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Plugins API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Lists all installed plugins.
    pub fn list_plugins(&self) -> Result<Vec<Plugin>, HudFfiError> {
        let registry_path = self
            .storage
            .claude_root()
            .join("plugins")
            .join("installed_plugins.json");
        if !registry_path.exists() {
            return Ok(Vec::new());
        }

        let content = fs::read_to_string(&registry_path)
            .map_err(|e| HudFfiError::from(format!("Failed to read plugin registry: {}", e)))?;

        #[derive(serde::Deserialize)]
        struct Registry {
            plugins: HashMap<String, Vec<PluginInfo>>,
        }

        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct PluginInfo {
            install_path: String,
        }

        let registry: Registry = serde_json::from_str(&content)
            .map_err(|e| HudFfiError::from(format!("Failed to parse plugin registry: {}", e)))?;

        // Load settings to check enabled status
        let settings_path = self.storage.claude_root().join("settings.json");
        let enabled_plugins: HashMap<String, bool> = if settings_path.exists() {
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Settings {
                enabled_plugins: Option<HashMap<String, bool>>,
            }

            fs::read_to_string(&settings_path)
                .ok()
                .and_then(|c| serde_json::from_str::<Settings>(&c).ok())
                .and_then(|s| s.enabled_plugins)
                .unwrap_or_default()
        } else {
            HashMap::new()
        };

        let mut plugins = Vec::new();

        for (id, installs) in registry.plugins {
            if let Some(install) = installs.first() {
                let plugin_path = PathBuf::from(&install.install_path);

                let manifest_path = plugin_path.join(".claude-plugin").join("plugin.json");
                let manifest: Option<PluginManifest> = fs::read_to_string(&manifest_path)
                    .ok()
                    .and_then(|c| serde_json::from_str(&c).ok());

                let name = manifest
                    .as_ref()
                    .map(|m| m.name.clone())
                    .unwrap_or_else(|| id.clone());
                let description = manifest
                    .as_ref()
                    .and_then(|m| m.description.clone())
                    .unwrap_or_default();

                let enabled = enabled_plugins.get(&id).copied().unwrap_or(true);

                plugins.push(Plugin {
                    id: id.clone(),
                    name,
                    description,
                    enabled,
                    path: install.install_path.clone(),
                    skill_count: count_artifacts_in_dir(&plugin_path.join("skills"), "skills"),
                    command_count: count_artifacts_in_dir(
                        &plugin_path.join("commands"),
                        "commands",
                    ),
                    agent_count: count_artifacts_in_dir(&plugin_path.join("agents"), "agents"),
                    hook_count: count_hooks_in_dir(&plugin_path),
                });
            }
        }

        plugins.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        Ok(plugins)
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Dashboard API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Loads all dashboard data in one call.
    pub fn load_dashboard(&self) -> Result<DashboardData, HudFfiError> {
        let settings_path = self.storage.claude_root().join("settings.json");
        let instructions_path = self.storage.claude_root().join("CLAUDE.md");

        let skills_dir = resolve_symlink(&self.storage.claude_root().join("skills"));
        let commands_dir = resolve_symlink(&self.storage.claude_root().join("commands"));
        let agents_dir = resolve_symlink(&self.storage.claude_root().join("agents"));

        let global = GlobalConfig {
            settings_path: settings_path.to_string_lossy().to_string(),
            settings_exists: settings_path.exists(),
            instructions_path: if instructions_path.exists() {
                Some(instructions_path.to_string_lossy().to_string())
            } else {
                None
            },
            skills_dir: skills_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
            commands_dir: commands_dir
                .as_ref()
                .map(|p| p.to_string_lossy().to_string()),
            agents_dir: agents_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
            skill_count: skills_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "skills"))
                .unwrap_or(0),
            command_count: commands_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "commands"))
                .unwrap_or(0),
            agent_count: agents_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "agents"))
                .unwrap_or(0),
        };

        let plugins = self.list_plugins().unwrap_or_default();
        let projects = self.list_projects().unwrap_or_default();

        Ok(DashboardData {
            global,
            plugins,
            projects,
        })
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Idea Capture API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Captures a new idea for a project.
    ///
    /// Appends the idea to `~/.capacitor/projects/{encoded}/ideas.md`
    /// with default metadata (effort: unknown, status: open, triage: pending).
    ///
    /// Returns the generated ULID for the idea.
    pub fn capture_idea(
        &self,
        project_path: String,
        idea_text: String,
    ) -> Result<String, HudFfiError> {
        crate::ideas::capture_idea_with_storage(&self.storage, &project_path, &idea_text)
            .map_err(HudFfiError::from)
    }

    /// Loads all ideas for a project.
    ///
    /// Returns an empty vector if the ideas file doesn't exist.
    pub fn load_ideas(&self, project_path: String) -> Result<Vec<crate::types::Idea>, HudFfiError> {
        crate::ideas::load_ideas_with_storage(&self.storage, &project_path)
            .map_err(HudFfiError::from)
    }

    /// Updates the status of an idea.
    ///
    /// Valid statuses: open, in-progress, done
    pub fn update_idea_status(
        &self,
        project_path: String,
        idea_id: String,
        new_status: String,
    ) -> Result<(), HudFfiError> {
        crate::ideas::update_idea_status_with_storage(
            &self.storage,
            &project_path,
            &idea_id,
            &new_status,
        )
        .map_err(HudFfiError::from)
    }

    /// Updates the effort estimate of an idea.
    ///
    /// Valid efforts: unknown, small, medium, large, xl
    pub fn update_idea_effort(
        &self,
        project_path: String,
        idea_id: String,
        new_effort: String,
    ) -> Result<(), HudFfiError> {
        crate::ideas::update_idea_effort_with_storage(
            &self.storage,
            &project_path,
            &idea_id,
            &new_effort,
        )
        .map_err(HudFfiError::from)
    }

    /// Updates the triage status of an idea.
    ///
    /// Valid triage statuses: pending, validated
    pub fn update_idea_triage(
        &self,
        project_path: String,
        idea_id: String,
        new_triage: String,
    ) -> Result<(), HudFfiError> {
        crate::ideas::update_idea_triage_with_storage(
            &self.storage,
            &project_path,
            &idea_id,
            &new_triage,
        )
        .map_err(HudFfiError::from)
    }

    /// Updates the title of an idea.
    ///
    /// Used for async title generation - the idea is initially saved with a placeholder,
    /// then this is called once the AI-generated title is ready.
    pub fn update_idea_title(
        &self,
        project_path: String,
        idea_id: String,
        new_title: String,
    ) -> Result<(), HudFfiError> {
        crate::ideas::update_idea_title_with_storage(
            &self.storage,
            &project_path,
            &idea_id,
            &new_title,
        )
        .map_err(HudFfiError::from)
    }

    /// Updates the description of an idea.
    ///
    /// Used for sensemaking - the idea is initially saved with raw user input,
    /// then this is called with an AI-generated expansion.
    pub fn update_idea_description(
        &self,
        project_path: String,
        idea_id: String,
        new_description: String,
    ) -> Result<(), HudFfiError> {
        crate::ideas::update_idea_description_with_storage(
            &self.storage,
            &project_path,
            &idea_id,
            &new_description,
        )
        .map_err(HudFfiError::from)
    }

    /// Saves the display order of ideas for a project.
    ///
    /// The order is stored separately from idea content in `~/.capacitor/projects/{encoded}/ideas-order.json`.
    /// This prevents churning the ideas markdown file on every drag-reorder.
    pub fn save_ideas_order(
        &self,
        project_path: String,
        idea_ids: Vec<String>,
    ) -> Result<(), HudFfiError> {
        crate::ideas::save_ideas_order_with_storage(&self.storage, &project_path, idea_ids)
            .map_err(HudFfiError::from)
    }

    /// Loads the display order of ideas for a project.
    ///
    /// Returns an empty vector if no order file exists (graceful degradation).
    /// The caller should merge this with loaded ideas: ordered first, unordered appended.
    pub fn load_ideas_order(&self, project_path: String) -> Result<Vec<String>, HudFfiError> {
        crate::ideas::load_ideas_order_with_storage(&self.storage, &project_path)
            .map_err(HudFfiError::from)
    }

    /// Returns the file path where ideas are stored for a project.
    ///
    /// This is useful for mtime-based change detection in the UI.
    /// Path: `~/.capacitor/projects/{encoded-path}/ideas.md`
    pub fn get_ideas_file_path(&self, project_path: String) -> String {
        self.storage
            .project_ideas_file(&project_path)
            .to_string_lossy()
            .to_string()
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Validation API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Validates a project path before adding it.
    ///
    /// Returns validation result indicating whether the path is valid,
    /// if there's a better path to use, or if the project is missing CLAUDE.md.
    ///
    /// This enables smart UI flows like:
    /// - Suggesting parent directory when user picks a subdirectory
    /// - Warning about dangerous paths (/, ~, etc.)
    /// - Offering to create CLAUDE.md when missing
    /// - Detecting if the project is already tracked
    pub fn validate_project(&self, path: String) -> ValidationResultFfi {
        let config = load_hud_config_with_storage(&self.storage);
        validate_project_path(&path, &config.pinned_projects).into()
    }

    /// Creates a CLAUDE.md file for a project.
    ///
    /// Returns Ok(()) if successful, or an error if the file couldn't be created.
    /// Does NOT overwrite existing CLAUDE.md files.
    pub fn create_project_claude_md(&self, project_path: String) -> Result<(), HudFfiError> {
        create_claude_md(&project_path).map_err(HudFfiError::from)
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setup API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Checks the overall setup status including dependencies and hooks.
    ///
    /// Returns a comprehensive status object indicating:
    /// - Which dependencies are installed (tmux, claude)
    /// - Whether hooks are installed and up-to-date
    /// - Whether storage is ready
    /// - Any blocking issues preventing operation
    pub fn check_setup_status(&self) -> SetupStatus {
        let checker = SetupChecker::new(self.storage.clone());
        checker.check_setup_status()
    }

    /// Checks the status of a specific dependency.
    ///
    /// Supported dependencies: "tmux", "claude"
    pub fn check_dependency(&self, name: String) -> DependencyStatus {
        let checker = SetupChecker::new(self.storage.clone());
        checker.check_dependency(&name)
    }

    /// Installs the hook binary from a source path to ~/.local/bin/hud-hook.
    ///
    /// This is the platform-agnostic installation logic. The client is responsible
    /// for finding the source binary (e.g., from macOS app bundle, Linux package, etc.).
    ///
    /// Returns success if:
    /// - Binary already installed and executable
    /// - Binary successfully copied and permissions set
    ///
    /// Returns error if:
    /// - Source path doesn't exist
    /// - Cannot create ~/.local/bin
    /// - Cannot copy or set permissions
    pub fn install_hook_binary_from_path(
        &self,
        source_path: String,
    ) -> Result<InstallResult, HudFfiError> {
        let checker = SetupChecker::new(self.storage.clone());
        checker.install_binary_from_path(&source_path)
    }

    /// Installs the session tracking hooks.
    ///
    /// This will:
    /// 1. Verify the hook binary exists at ~/.local/bin/hud-hook
    /// 2. Register the hooks in ~/.claude/settings.json
    ///
    /// Returns an error if:
    /// - Hook binary is missing or broken
    /// - Hooks are disabled by policy (disableAllHooks or allowManagedHooksOnly)
    /// - File system operations fail
    pub fn install_hooks(&self) -> Result<InstallResult, HudFfiError> {
        let checker = SetupChecker::new(self.storage.clone());
        checker.install_hooks()
    }

    /// Returns the current hook status without full setup check.
    ///
    /// Useful for quick hook status checks in the UI.
    pub fn get_hook_status(&self) -> HookStatus {
        let checker = SetupChecker::new(self.storage.clone());
        checker.check_setup_status().hooks
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Cleanup API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Performs startup cleanup of daemon-era artifacts.
    ///
    /// In daemon-only mode this is a no-op and returns any cleanup errors.
    pub fn run_startup_cleanup(&self) -> crate::state::CleanupStats {
        crate::state::run_startup_cleanup()
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Health API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Checks the health of the hook binary by examining its heartbeat file.
    ///
    /// The hook binary touches `~/.capacitor/hud-hook-heartbeat` on every valid hook event.
    /// If the file's mtime is older than 60 seconds, the hooks have likely
    /// stopped firing (binary crash, SIGKILL, etc.). When there is an active
    /// daemon session, we allow a short grace window before reporting stale
    /// to avoid false alarms during quiet periods.
    ///
    /// Returns a health report with:
    /// - `Healthy`: Heartbeat is fresh (within threshold)
    /// - `Unknown`: No heartbeat file (hooks never fired)
    /// - `Stale`: Heartbeat is old (hooks stopped firing)
    /// - `Unreadable`: Can't read heartbeat file
    pub fn check_hook_health(&self) -> crate::types::HookHealthReport {
        use crate::types::{HookHealthReport, HookHealthStatus};

        const HOOK_HEALTH_THRESHOLD_SECS: u64 = 60;
        const HOOK_HEALTH_GRACE_SECS: u64 = 300;

        let heartbeat_path = self.storage.root().join("hud-hook-heartbeat");
        let threshold_secs = HOOK_HEALTH_THRESHOLD_SECS;

        let (status, age) = match std::fs::metadata(&heartbeat_path) {
            Ok(meta) => match meta.modified() {
                Ok(mtime) => {
                    let age_secs = mtime.elapsed().map(|d| d.as_secs()).unwrap_or(0);
                    let has_active_session = if age_secs > threshold_secs {
                        has_active_daemon_session(
                            crate::state::daemon::sessions_snapshot().as_ref(),
                        )
                    } else {
                        false
                    };

                    let status = heartbeat_status(
                        age_secs,
                        threshold_secs,
                        HOOK_HEALTH_GRACE_SECS,
                        has_active_session,
                    );
                    (status, Some(age_secs))
                }
                Err(e) => (
                    HookHealthStatus::Unreadable {
                        reason: e.to_string(),
                    },
                    None,
                ),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (HookHealthStatus::Unknown, None),
            Err(e) => (
                HookHealthStatus::Unreadable {
                    reason: e.to_string(),
                },
                None,
            ),
        };

        HookHealthReport {
            status,
            heartbeat_path: heartbeat_path.display().to_string(),
            threshold_secs,
            last_heartbeat_age_secs: age,
        }
    }

    /// Returns a unified diagnostic report for hook status.
    ///
    /// This combines setup status (is everything installed?) with health status
    /// (are hooks actually firing?) into a single report for the UI.
    ///
    /// The report provides:
    /// - `is_healthy`: True if everything is working
    /// - `primary_issue`: The most critical issue to display (prioritized)
    /// - `can_auto_fix`: True if "Fix All" can resolve the issue
    /// - Individual status flags for checklist display
    pub fn get_hook_diagnostic(&self) -> HookDiagnosticReport {
        let setup_status = self.check_setup_status();
        let health = self.check_hook_health();

        // Determine individual status flags
        let binary_ok = setup_status
            .dependencies
            .iter()
            .find(|d| d.name == "hud-hook")
            .map(|d| d.found)
            .unwrap_or(false);

        let config_ok = matches!(setup_status.hooks, HookStatus::Installed { .. });

        let firing_ok = matches!(health.status, crate::types::HookHealthStatus::Healthy);

        // Determine if this is first-run (no heartbeat file ever created)
        let is_first_run = matches!(health.status, crate::types::HookHealthStatus::Unknown);

        // Prioritize issues: policy > symlink > binary > config > firing
        let primary_issue: Option<HookIssue> = match &setup_status.hooks {
            HookStatus::PolicyBlocked { reason } => Some(HookIssue::PolicyBlocked {
                reason: reason.clone(),
            }),
            HookStatus::SymlinkBroken { target, reason } => Some(HookIssue::SymlinkBroken {
                target: target.clone(),
                reason: reason.clone(),
            }),
            HookStatus::BinaryBroken { reason } => Some(HookIssue::BinaryBroken {
                reason: reason.clone(),
            }),
            _ if !binary_ok => Some(HookIssue::BinaryMissing),
            HookStatus::NotInstalled => Some(HookIssue::ConfigMissing),
            HookStatus::Installed { .. } => {
                // Hooks are installed, check if they're firing
                match &health.status {
                    crate::types::HookHealthStatus::Healthy => None,
                    crate::types::HookHealthStatus::Unknown => Some(HookIssue::NotFiring {
                        last_seen_secs: None,
                    }),
                    crate::types::HookHealthStatus::Stale { last_seen_secs } => {
                        Some(HookIssue::NotFiring {
                            last_seen_secs: Some(*last_seen_secs),
                        })
                    }
                    crate::types::HookHealthStatus::Unreadable { .. } => {
                        // Can't check, assume firing is OK
                        None
                    }
                }
            }
        };

        // Can auto-fix everything except policy blocks
        let can_auto_fix = !matches!(primary_issue, Some(HookIssue::PolicyBlocked { .. }));

        let is_healthy = primary_issue.is_none();

        // Get symlink info for debugging display
        let symlink_path = dirs::home_dir()
            .map(|h| h.join(".local/bin/hud-hook"))
            .unwrap_or_else(|| std::path::PathBuf::from("/usr/local/bin/hud-hook"));

        let symlink_target = if symlink_path.is_symlink() {
            std::fs::read_link(&symlink_path)
                .ok()
                .map(|p| p.to_string_lossy().to_string())
        } else {
            None
        };

        HookDiagnosticReport {
            is_healthy,
            primary_issue,
            can_auto_fix,
            is_first_run,
            binary_ok,
            config_ok,
            firing_ok,
            symlink_path: symlink_path.to_string_lossy().to_string(),
            symlink_target,
            last_heartbeat_age_secs: health.last_heartbeat_age_secs,
        }
    }

    /// Runs a comprehensive hook system test.
    ///
    /// This verifies:
    /// 1. Heartbeat file exists and is recent (< 60s old)
    /// 2. Daemon health probe succeeds
    ///
    /// Used by the "Test Hooks" button in SetupStatusCard to give users
    /// confidence that the hook system is functioning correctly.
    pub fn run_hook_test(&self) -> HookTestResult {
        // 1. Check heartbeat
        let health = self.check_hook_health();
        let heartbeat_ok = matches!(health.status, crate::types::HookHealthStatus::Healthy);
        let heartbeat_age = health.last_heartbeat_age_secs;

        // 2. Test daemon health
        let state_file_ok = self.test_state_file_io();

        let success = heartbeat_ok && state_file_ok;
        let message = if success {
            "Hooks are working correctly".to_string()
        } else if !heartbeat_ok {
            match heartbeat_age {
                Some(age) => format!(
                    "Heartbeat stale ({}s ago). Start a Claude session to test.",
                    age
                ),
                None => "No heartbeat detected. Start a Claude session to test hooks.".to_string(),
            }
        } else {
            "Daemon health check failed. Ensure the daemon is running.".to_string()
        };

        HookTestResult {
            success,
            heartbeat_ok,
            heartbeat_age_secs: heartbeat_age,
            state_file_ok,
            message,
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Terminal Activation API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Resolves what activation action to take for a project.
    ///
    /// This is the main entry point for terminal activation. Given the current
    /// shell state and tmux context, it determines what action(s) Swift should
    /// take to activate the correct terminal.
    ///
    /// # Arguments
    /// * `project_path` - The absolute path to the project
    /// * `shell_state` - Current daemon shell snapshot (may be None if unavailable)
    /// * `tmux_context` - Tmux state queried by Swift
    ///
    /// # Returns
    /// An `ActivationDecision` with primary action and optional fallback.
    ///
    /// # Example Usage (Swift)
    /// ```swift
    /// let decision = engine.resolveActivation(
    ///     projectPath: project.path,
    ///     shellState: shellStore.state?.toFfi(),
    ///     tmuxContext: await queryTmuxContext()
    /// )
    /// await executeAction(decision.primary)
    /// ```
    pub fn resolve_activation(
        &self,
        project_path: String,
        shell_state: Option<crate::activation::ShellCwdStateFfi>,
        tmux_context: crate::activation::TmuxContextFfi,
    ) -> crate::activation::ActivationDecision {
        crate::activation::resolve_activation(&project_path, shell_state.as_ref(), &tmux_context)
    }

    /// Resolves activation and optionally returns a decision trace for debugging.
    pub fn resolve_activation_with_trace(
        &self,
        project_path: String,
        shell_state: Option<crate::activation::ShellCwdStateFfi>,
        tmux_context: crate::activation::TmuxContextFfi,
        include_trace: bool,
    ) -> crate::activation::ActivationDecision {
        crate::activation::resolve_activation_with_trace(
            &project_path,
            shell_state.as_ref(),
            &tmux_context,
            include_trace,
        )
    }
}

impl HudEngine {
    /// Tests daemon connectivity for diagnostics.
    fn test_state_file_io(&self) -> bool {
        crate::state::daemon::daemon_health().unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_state_file_io_uses_daemon_health() {
        let engine = HudEngine::new().unwrap();
        let _ = engine.test_state_file_io();
    }

    #[test]
    fn heartbeat_status_marks_stale_when_old_and_inactive() {
        let status = heartbeat_status(120, 60, 300, false);
        assert!(matches!(
            status,
            crate::types::HookHealthStatus::Stale { .. }
        ));
    }

    #[test]
    fn heartbeat_status_allows_grace_when_active() {
        let status = heartbeat_status(120, 60, 300, true);
        assert!(matches!(status, crate::types::HookHealthStatus::Healthy));
    }

    #[test]
    fn heartbeat_status_marks_stale_after_grace() {
        let status = heartbeat_status(400, 60, 300, true);
        assert!(matches!(
            status,
            crate::types::HookHealthStatus::Stale { .. }
        ));
    }

    #[test]
    fn projects_persist_across_engine_restarts() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&root).expect("create root");
        std::fs::create_dir_all(&claude_root).expect("create claude root");

        let project_path = temp.path().join("project");
        std::fs::create_dir_all(&project_path).expect("create project");

        let storage = StorageConfig::with_roots(root.clone(), claude_root);
        let engine = HudEngine::with_storage(storage.clone()).expect("engine");
        engine
            .add_project(project_path.to_string_lossy().to_string())
            .expect("add project");

        let engine_after_restart = HudEngine::with_storage(storage).expect("engine restart");
        let projects = engine_after_restart.list_projects().expect("list projects");
        let paths: Vec<_> = projects.into_iter().map(|p| p.path).collect();

        assert!(paths.contains(&project_path.to_string_lossy().to_string()));
    }

    #[test]
    fn remove_project_persists_across_engine_restarts() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&root).expect("create root");
        std::fs::create_dir_all(&claude_root).expect("create claude root");

        let project_path = temp.path().join("project");
        std::fs::create_dir_all(&project_path).expect("create project");

        let storage = StorageConfig::with_roots(root.clone(), claude_root);
        let engine = HudEngine::with_storage(storage.clone()).expect("engine");
        let project_string = project_path.to_string_lossy().to_string();

        engine.add_project(project_string.clone()).expect("add project");
        engine.remove_project(project_string.clone()).expect("remove project");

        let engine_after_restart = HudEngine::with_storage(storage).expect("engine restart");
        let projects = engine_after_restart.list_projects().expect("list projects");
        let paths: Vec<_> = projects.into_iter().map(|p| p.path).collect();

        assert!(!paths.contains(&project_string));
    }
}
