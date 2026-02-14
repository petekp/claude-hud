use crate::are::state::RoutingConfig;
use capacitor_daemon_protocol::{RoutingConfidence, RoutingSnapshot, RoutingStatus, RoutingTarget};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct LegacyRoutingDecision {
    pub status: RoutingStatus,
    pub target: RoutingTarget,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct RoutingMetrics {
    pub enabled: bool,
    pub dual_run_enabled: bool,
    pub snapshots_emitted: u64,
    pub legacy_vs_are_status_mismatch: u64,
    pub legacy_vs_are_target_mismatch: u64,
    pub confidence_high: u64,
    pub confidence_medium: u64,
    pub confidence_low: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_snapshot_at: Option<String>,
}

impl RoutingMetrics {
    pub fn new(config: &RoutingConfig) -> Self {
        Self {
            enabled: config.enabled,
            dual_run_enabled: config.feature_flags.dual_run,
            ..Self::default()
        }
    }

    pub fn record_snapshot(&mut self, snapshot: &RoutingSnapshot) {
        self.snapshots_emitted = self.snapshots_emitted.saturating_add(1);
        self.last_snapshot_at = Some(snapshot.updated_at.clone());
        match snapshot.confidence {
            RoutingConfidence::High => {
                self.confidence_high = self.confidence_high.saturating_add(1);
            }
            RoutingConfidence::Medium => {
                self.confidence_medium = self.confidence_medium.saturating_add(1);
            }
            RoutingConfidence::Low => {
                self.confidence_low = self.confidence_low.saturating_add(1);
            }
        }
    }

    pub fn record_divergence(&mut self, legacy: &LegacyRoutingDecision, are: &RoutingSnapshot) {
        if legacy.status != are.status {
            self.legacy_vs_are_status_mismatch =
                self.legacy_vs_are_status_mismatch.saturating_add(1);
        }
        if legacy.target != are.target {
            self.legacy_vs_are_target_mismatch =
                self.legacy_vs_are_target_mismatch.saturating_add(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::are::state::RoutingConfig;
    use capacitor_daemon_protocol::{RoutingConfidence, RoutingStatus, RoutingTargetKind};

    fn base_snapshot(
        status: RoutingStatus,
        kind: RoutingTargetKind,
        value: Option<&str>,
    ) -> RoutingSnapshot {
        RoutingSnapshot {
            version: 1,
            workspace_id: "workspace-1".to_string(),
            project_path: "/Users/petepetrash/Code/capacitor".to_string(),
            status,
            target: RoutingTarget {
                kind,
                value: value.map(str::to_string),
            },
            confidence: RoutingConfidence::High,
            reason_code: "TMUX_CLIENT_ATTACHED".to_string(),
            reason: "attached".to_string(),
            evidence: vec![],
            updated_at: "2026-02-14T15:00:00Z".to_string(),
        }
    }

    #[test]
    fn record_snapshot_tracks_confidence_distribution() {
        let mut metrics = RoutingMetrics::new(&RoutingConfig::default());
        let mut high = base_snapshot(
            RoutingStatus::Attached,
            RoutingTargetKind::TmuxSession,
            Some("caps"),
        );
        metrics.record_snapshot(&high);
        high.confidence = RoutingConfidence::Medium;
        metrics.record_snapshot(&high);
        high.confidence = RoutingConfidence::Low;
        metrics.record_snapshot(&high);

        assert_eq!(metrics.snapshots_emitted, 3);
        assert_eq!(metrics.confidence_high, 1);
        assert_eq!(metrics.confidence_medium, 1);
        assert_eq!(metrics.confidence_low, 1);
        assert_eq!(
            metrics.last_snapshot_at.as_deref(),
            Some("2026-02-14T15:00:00Z")
        );
    }

    #[test]
    fn record_divergence_tracks_status_and_target_independently() {
        let mut metrics = RoutingMetrics::new(&RoutingConfig::default());
        let legacy = LegacyRoutingDecision {
            status: RoutingStatus::Detached,
            target: RoutingTarget {
                kind: RoutingTargetKind::TerminalApp,
                value: Some("ghostty".to_string()),
            },
        };
        let status_mismatch_snapshot = base_snapshot(
            RoutingStatus::Attached,
            RoutingTargetKind::TerminalApp,
            Some("ghostty"),
        );
        metrics.record_divergence(&legacy, &status_mismatch_snapshot);
        assert_eq!(metrics.legacy_vs_are_status_mismatch, 1);
        assert_eq!(metrics.legacy_vs_are_target_mismatch, 0);

        let target_mismatch_snapshot = base_snapshot(
            RoutingStatus::Detached,
            RoutingTargetKind::TmuxSession,
            Some("caps"),
        );
        metrics.record_divergence(&legacy, &target_mismatch_snapshot);
        assert_eq!(metrics.legacy_vs_are_status_mismatch, 1);
        assert_eq!(metrics.legacy_vs_are_target_mismatch, 1);
    }
}
