use crate::are::registry::WorkspaceBindings;
use capacitor_daemon_protocol::{RoutingConfigView, RoutingSnapshot};
use std::collections::HashMap;

pub const DEFAULT_TMUX_SIGNAL_FRESH_MS: u64 = 5_000;
pub const DEFAULT_SHELL_SIGNAL_FRESH_MS: u64 = 600_000;
pub const DEFAULT_SHELL_RETENTION_HOURS: u64 = 24;
pub const DEFAULT_TMUX_POLL_INTERVAL_MS: u64 = 1_000;

#[derive(Debug, Clone)]
pub struct RoutingFeatureFlags {
    pub dual_run: bool,
    pub emit_diagnostics: bool,
}

impl Default for RoutingFeatureFlags {
    fn default() -> Self {
        Self {
            dual_run: true,
            emit_diagnostics: true,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RoutingConfig {
    pub enabled: bool,
    pub tmux_signal_fresh_ms: u64,
    pub shell_signal_fresh_ms: u64,
    pub shell_retention_hours: u64,
    pub tmux_poll_interval_ms: u64,
    pub workspace_bindings: WorkspaceBindings,
    pub feature_flags: RoutingFeatureFlags,
}

impl RoutingConfig {
    pub fn view(&self) -> RoutingConfigView {
        RoutingConfigView {
            tmux_signal_fresh_ms: self.tmux_signal_fresh_ms,
            shell_signal_fresh_ms: self.shell_signal_fresh_ms,
            shell_retention_hours: self.shell_retention_hours,
            tmux_poll_interval_ms: self.tmux_poll_interval_ms,
        }
    }
}

impl Default for RoutingConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            tmux_signal_fresh_ms: DEFAULT_TMUX_SIGNAL_FRESH_MS,
            shell_signal_fresh_ms: DEFAULT_SHELL_SIGNAL_FRESH_MS,
            shell_retention_hours: DEFAULT_SHELL_RETENTION_HOURS,
            tmux_poll_interval_ms: DEFAULT_TMUX_POLL_INTERVAL_MS,
            workspace_bindings: WorkspaceBindings::default(),
            feature_flags: RoutingFeatureFlags::default(),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RoutingState {
    snapshots: HashMap<String, RoutingSnapshot>,
}

impl RoutingState {
    pub fn cache_snapshot(&mut self, snapshot: RoutingSnapshot) {
        self.snapshots
            .insert(snapshot.workspace_id.clone(), snapshot);
    }

    pub fn snapshot_for_workspace(&self, workspace_id: &str) -> Option<&RoutingSnapshot> {
        self.snapshots.get(workspace_id)
    }
}
