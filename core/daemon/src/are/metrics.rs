use crate::are::state::RoutingConfig;
use capacitor_daemon_protocol::{RoutingConfidence, RoutingSnapshot, RoutingStatus, RoutingTarget};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::Serialize;

const ROUTING_AGREEMENT_GATE_TARGET: f64 = 0.995;
const ROUTING_MIN_ROLLOUT_COMPARISONS: u64 = 1_000;
const ROUTING_MIN_ROLLOUT_WINDOW_HOURS: u64 = 168;

#[derive(Debug, Clone, Serialize)]
pub struct LegacyRoutingDecision {
    pub status: RoutingStatus,
    pub target: RoutingTarget,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedRoutingRolloutState {
    pub dual_run_comparisons: u64,
    pub legacy_vs_are_status_mismatch: u64,
    pub legacy_vs_are_target_mismatch: u64,
    pub first_comparison_at: Option<String>,
    pub last_comparison_at: Option<String>,
    pub last_snapshot_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RoutingRolloutGate {
    pub agreement_gate_target: f64,
    pub min_comparisons_required: u64,
    pub min_window_hours_required: u64,
    pub comparisons: u64,
    pub volume_gate_met: bool,
    pub window_gate_met: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status_agreement_rate: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_agreement_rate: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_comparison_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_comparison_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_elapsed_hours: Option<u64>,
    pub status_gate_met: bool,
    pub target_gate_met: bool,
    pub status_row_default_ready: bool,
    pub launcher_default_ready: bool,
}

impl Default for RoutingRolloutGate {
    fn default() -> Self {
        Self {
            agreement_gate_target: ROUTING_AGREEMENT_GATE_TARGET,
            min_comparisons_required: ROUTING_MIN_ROLLOUT_COMPARISONS,
            min_window_hours_required: ROUTING_MIN_ROLLOUT_WINDOW_HOURS,
            comparisons: 0,
            volume_gate_met: false,
            window_gate_met: false,
            status_agreement_rate: None,
            target_agreement_rate: None,
            first_comparison_at: None,
            last_comparison_at: None,
            window_elapsed_hours: None,
            status_gate_met: false,
            target_gate_met: false,
            status_row_default_ready: false,
            launcher_default_ready: false,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct RoutingMetrics {
    pub enabled: bool,
    pub dual_run_enabled: bool,
    pub snapshots_emitted: u64,
    pub dual_run_comparisons: u64,
    pub legacy_vs_are_status_mismatch: u64,
    pub legacy_vs_are_target_mismatch: u64,
    pub confidence_high: u64,
    pub confidence_medium: u64,
    pub confidence_low: u64,
    pub rollout: RoutingRolloutGate,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_snapshot_at: Option<String>,
    #[serde(skip)]
    first_comparison_at: Option<DateTime<Utc>>,
    #[serde(skip)]
    last_comparison_at: Option<DateTime<Utc>>,
}

impl RoutingMetrics {
    pub fn new(config: &RoutingConfig) -> Self {
        Self {
            enabled: config.enabled,
            dual_run_enabled: config.feature_flags.dual_run,
            rollout: RoutingRolloutGate::default(),
            ..Self::default()
        }
    }

    pub fn from_persisted(
        config: &RoutingConfig,
        persisted: Option<PersistedRoutingRolloutState>,
    ) -> Self {
        let mut metrics = Self::new(config);
        if let Some(persisted) = persisted {
            metrics.apply_persisted_rollout_state(persisted);
        }
        metrics
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
        self.refresh_rollout_gate();
    }

    pub fn record_divergence(&mut self, legacy: &LegacyRoutingDecision, are: &RoutingSnapshot) {
        self.dual_run_comparisons = self.dual_run_comparisons.saturating_add(1);
        self.record_comparison_timestamp(&are.updated_at);
        if legacy.status != are.status {
            self.legacy_vs_are_status_mismatch =
                self.legacy_vs_are_status_mismatch.saturating_add(1);
        }
        if legacy.target != are.target {
            self.legacy_vs_are_target_mismatch =
                self.legacy_vs_are_target_mismatch.saturating_add(1);
        }
        self.refresh_rollout_gate();
    }

    fn refresh_rollout_gate(&mut self) {
        self.rollout.comparisons = self.dual_run_comparisons;
        self.rollout.first_comparison_at =
            self.first_comparison_at.as_ref().map(format_rfc3339_utc);
        self.rollout.last_comparison_at = self.last_comparison_at.as_ref().map(format_rfc3339_utc);
        self.rollout.window_elapsed_hours = window_elapsed_hours(
            self.first_comparison_at.as_ref(),
            self.last_comparison_at.as_ref(),
        );
        self.rollout.volume_gate_met =
            self.rollout.comparisons >= self.rollout.min_comparisons_required;
        self.rollout.window_gate_met = self
            .rollout
            .window_elapsed_hours
            .is_some_and(|hours| hours >= self.rollout.min_window_hours_required);
        self.rollout.status_agreement_rate = agreement_rate(
            self.dual_run_comparisons,
            self.legacy_vs_are_status_mismatch,
        );
        self.rollout.target_agreement_rate = agreement_rate(
            self.dual_run_comparisons,
            self.legacy_vs_are_target_mismatch,
        );

        self.rollout.status_gate_met = self.dual_run_enabled
            && self.rollout.volume_gate_met
            && self.rollout.window_gate_met
            && self
                .rollout
                .status_agreement_rate
                .is_some_and(|rate| rate >= self.rollout.agreement_gate_target);
        self.rollout.target_gate_met = self.dual_run_enabled
            && self.rollout.volume_gate_met
            && self.rollout.window_gate_met
            && self
                .rollout
                .target_agreement_rate
                .is_some_and(|rate| rate >= self.rollout.agreement_gate_target);
        self.rollout.status_row_default_ready = self.rollout.status_gate_met;
        self.rollout.launcher_default_ready =
            self.rollout.status_gate_met && self.rollout.target_gate_met;
    }

    fn record_comparison_timestamp(&mut self, timestamp: &str) {
        let Some(parsed) = parse_rfc3339_utc(timestamp) else {
            return;
        };

        let should_update_first = self
            .first_comparison_at
            .as_ref()
            .is_none_or(|current| parsed < *current);
        if should_update_first {
            self.first_comparison_at = Some(parsed.clone());
        }

        let should_update_last = self
            .last_comparison_at
            .as_ref()
            .is_none_or(|current| parsed > *current);
        if should_update_last {
            self.last_comparison_at = Some(parsed);
        }
    }

    pub fn persisted_rollout_state(&self) -> PersistedRoutingRolloutState {
        PersistedRoutingRolloutState {
            dual_run_comparisons: self.dual_run_comparisons,
            legacy_vs_are_status_mismatch: self.legacy_vs_are_status_mismatch,
            legacy_vs_are_target_mismatch: self.legacy_vs_are_target_mismatch,
            first_comparison_at: self.first_comparison_at.as_ref().map(format_rfc3339_utc),
            last_comparison_at: self.last_comparison_at.as_ref().map(format_rfc3339_utc),
            last_snapshot_at: self.last_snapshot_at.clone(),
        }
    }

    fn apply_persisted_rollout_state(&mut self, persisted: PersistedRoutingRolloutState) {
        self.dual_run_comparisons = persisted.dual_run_comparisons;
        self.legacy_vs_are_status_mismatch = persisted.legacy_vs_are_status_mismatch;
        self.legacy_vs_are_target_mismatch = persisted.legacy_vs_are_target_mismatch;
        self.last_snapshot_at = persisted.last_snapshot_at;

        let first = persisted
            .first_comparison_at
            .as_deref()
            .and_then(parse_rfc3339_utc);
        let last = persisted
            .last_comparison_at
            .as_deref()
            .and_then(parse_rfc3339_utc);
        let (first, last) = normalize_comparison_window(first, last);
        self.first_comparison_at = first;
        self.last_comparison_at = last;

        self.refresh_rollout_gate();
    }
}

fn agreement_rate(comparisons: u64, mismatches: u64) -> Option<f64> {
    if comparisons == 0 {
        return None;
    }
    let clamped_mismatches = mismatches.min(comparisons);
    let matches = comparisons.saturating_sub(clamped_mismatches);
    Some(matches as f64 / comparisons as f64)
}

fn parse_rfc3339_utc(value: &str) -> Option<DateTime<Utc>> {
    chrono::DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|timestamp| timestamp.with_timezone(&Utc))
}

fn format_rfc3339_utc(value: &DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn window_elapsed_hours(
    first: Option<&DateTime<Utc>>,
    last: Option<&DateTime<Utc>>,
) -> Option<u64> {
    let (Some(first), Some(last)) = (first, last) else {
        return None;
    };

    let elapsed = last
        .clone()
        .signed_duration_since(first.clone())
        .num_hours();
    Some(elapsed.max(0) as u64)
}

fn normalize_comparison_window(
    first: Option<DateTime<Utc>>,
    last: Option<DateTime<Utc>>,
) -> (Option<DateTime<Utc>>, Option<DateTime<Utc>>) {
    match (first, last) {
        (Some(first), Some(last)) => {
            if first <= last {
                (Some(first), Some(last))
            } else {
                (Some(last), Some(first))
            }
        }
        values => values,
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
        base_snapshot_at(status, kind, value, "2026-02-14T15:00:00Z")
    }

    fn base_snapshot_at(
        status: RoutingStatus,
        kind: RoutingTargetKind,
        value: Option<&str>,
        updated_at: &str,
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
            updated_at: updated_at.to_string(),
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
        assert_eq!(metrics.dual_run_comparisons, 2);
    }

    #[test]
    fn rollout_gate_requires_independent_status_and_target_agreement() {
        let mut metrics = RoutingMetrics::new(&RoutingConfig::default());
        let legacy = LegacyRoutingDecision {
            status: RoutingStatus::Attached,
            target: RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("caps".to_string()),
            },
        };
        let mut snapshot = base_snapshot(
            RoutingStatus::Attached,
            RoutingTargetKind::TmuxSession,
            Some("caps"),
        );

        for _ in 0..1000 {
            metrics.record_snapshot(&snapshot);
            metrics.record_divergence(&legacy, &snapshot);
        }
        for _ in 0..4 {
            snapshot.status = RoutingStatus::Detached;
            snapshot.updated_at = "2026-02-22T15:00:00Z".to_string();
            metrics.record_snapshot(&snapshot);
            metrics.record_divergence(&legacy, &snapshot);
            snapshot.status = RoutingStatus::Attached;
            snapshot.updated_at = "2026-02-14T15:00:00Z".to_string();
        }
        for _ in 0..6 {
            snapshot.target = RoutingTarget {
                kind: RoutingTargetKind::TerminalApp,
                value: Some("ghostty".to_string()),
            };
            snapshot.updated_at = "2026-02-22T15:05:00Z".to_string();
            metrics.record_snapshot(&snapshot);
            metrics.record_divergence(&legacy, &snapshot);
            snapshot.target = RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("caps".to_string()),
            };
            snapshot.updated_at = "2026-02-14T15:00:00Z".to_string();
        }

        assert_eq!(metrics.rollout.comparisons, 1010);
        assert_eq!(metrics.legacy_vs_are_status_mismatch, 4);
        assert_eq!(metrics.legacy_vs_are_target_mismatch, 6);
        assert_eq!(metrics.rollout.agreement_gate_target, 0.995);
        assert_eq!(metrics.rollout.min_comparisons_required, 1_000);
        assert_eq!(metrics.rollout.min_window_hours_required, 168);
        assert_eq!(metrics.rollout.window_elapsed_hours, Some(192));
        assert!(metrics.rollout.volume_gate_met);
        assert!(metrics.rollout.window_gate_met);
        assert!(metrics
            .rollout
            .status_agreement_rate
            .is_some_and(|rate| rate >= 0.995),);
        assert!(metrics
            .rollout
            .target_agreement_rate
            .is_some_and(|rate| rate < 0.995),);
        assert!(metrics.rollout.status_gate_met);
        assert!(!metrics.rollout.target_gate_met);
        assert!(metrics.rollout.status_row_default_ready);
        assert!(!metrics.rollout.launcher_default_ready);
    }

    #[test]
    fn rollout_gate_is_not_default_ready_after_single_comparison() {
        let mut metrics = RoutingMetrics::new(&RoutingConfig::default());
        let legacy = LegacyRoutingDecision {
            status: RoutingStatus::Attached,
            target: RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("caps".to_string()),
            },
        };
        let snapshot = base_snapshot(
            RoutingStatus::Attached,
            RoutingTargetKind::TmuxSession,
            Some("caps"),
        );

        metrics.record_snapshot(&snapshot);
        metrics.record_divergence(&legacy, &snapshot);

        assert_eq!(metrics.rollout.comparisons, 1);
        assert!(!metrics.rollout.volume_gate_met);
        assert!(!metrics.rollout.window_gate_met);
        assert!(!metrics.rollout.status_row_default_ready);
        assert!(!metrics.rollout.launcher_default_ready);
    }

    #[test]
    fn rollout_gate_requires_validation_window_duration() {
        let mut metrics = RoutingMetrics::new(&RoutingConfig::default());
        let legacy = LegacyRoutingDecision {
            status: RoutingStatus::Attached,
            target: RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("caps".to_string()),
            },
        };
        let early_snapshot = base_snapshot_at(
            RoutingStatus::Attached,
            RoutingTargetKind::TmuxSession,
            Some("caps"),
            "2026-02-14T15:00:00Z",
        );
        let late_snapshot = base_snapshot_at(
            RoutingStatus::Attached,
            RoutingTargetKind::TmuxSession,
            Some("caps"),
            "2026-02-20T14:59:59Z",
        );

        for _ in 0..999 {
            metrics.record_snapshot(&early_snapshot);
            metrics.record_divergence(&legacy, &early_snapshot);
        }
        metrics.record_snapshot(&late_snapshot);
        metrics.record_divergence(&legacy, &late_snapshot);

        assert_eq!(metrics.rollout.comparisons, 1_000);
        assert_eq!(metrics.rollout.window_elapsed_hours, Some(143));
        assert!(metrics.rollout.volume_gate_met);
        assert!(!metrics.rollout.window_gate_met);
        assert!(!metrics.rollout.status_row_default_ready);
        assert!(!metrics.rollout.launcher_default_ready);
    }

    #[test]
    fn rollout_gate_is_blocked_when_dual_run_disabled() {
        let mut config = RoutingConfig::default();
        config.feature_flags.dual_run = false;

        let mut metrics = RoutingMetrics::new(&config);
        let legacy = LegacyRoutingDecision {
            status: RoutingStatus::Attached,
            target: RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("caps".to_string()),
            },
        };
        let snapshot = base_snapshot(
            RoutingStatus::Attached,
            RoutingTargetKind::TmuxSession,
            Some("caps"),
        );
        metrics.record_snapshot(&snapshot);
        metrics.record_divergence(&legacy, &snapshot);

        assert_eq!(metrics.rollout.comparisons, 1);
        assert_eq!(metrics.rollout.status_agreement_rate, Some(1.0));
        assert_eq!(metrics.rollout.target_agreement_rate, Some(1.0));
        assert!(!metrics.rollout.volume_gate_met);
        assert!(!metrics.rollout.window_gate_met);
        assert!(!metrics.rollout.status_gate_met);
        assert!(!metrics.rollout.target_gate_met);
        assert!(!metrics.rollout.status_row_default_ready);
        assert!(!metrics.rollout.launcher_default_ready);
    }

    #[test]
    fn restores_rollout_state_and_recomputes_gates() {
        let metrics = RoutingMetrics::from_persisted(
            &RoutingConfig::default(),
            Some(PersistedRoutingRolloutState {
                dual_run_comparisons: 1_010,
                legacy_vs_are_status_mismatch: 4,
                legacy_vs_are_target_mismatch: 6,
                first_comparison_at: Some("2026-02-14T15:00:00Z".to_string()),
                last_comparison_at: Some("2026-02-22T15:00:00Z".to_string()),
                last_snapshot_at: Some("2026-02-22T15:00:00Z".to_string()),
            }),
        );

        assert_eq!(metrics.rollout.comparisons, 1_010);
        assert_eq!(metrics.rollout.window_elapsed_hours, Some(192));
        assert!(metrics.rollout.volume_gate_met);
        assert!(metrics.rollout.window_gate_met);
        assert!(metrics.rollout.status_gate_met);
        assert!(!metrics.rollout.target_gate_met);
        assert!(metrics.rollout.status_row_default_ready);
        assert!(!metrics.rollout.launcher_default_ready);
        assert_eq!(
            metrics.last_snapshot_at.as_deref(),
            Some("2026-02-22T15:00:00Z"),
        );
    }

    #[test]
    fn restores_rollout_state_and_keeps_window_gate_closed_when_elapsed_is_short() {
        let metrics = RoutingMetrics::from_persisted(
            &RoutingConfig::default(),
            Some(PersistedRoutingRolloutState {
                dual_run_comparisons: 1_000,
                legacy_vs_are_status_mismatch: 0,
                legacy_vs_are_target_mismatch: 0,
                first_comparison_at: Some("2026-02-14T15:00:00Z".to_string()),
                last_comparison_at: Some("2026-02-20T14:59:59Z".to_string()),
                last_snapshot_at: None,
            }),
        );

        assert_eq!(metrics.rollout.comparisons, 1_000);
        assert_eq!(metrics.rollout.window_elapsed_hours, Some(143));
        assert!(metrics.rollout.volume_gate_met);
        assert!(!metrics.rollout.window_gate_met);
        assert!(!metrics.rollout.status_row_default_ready);
        assert!(!metrics.rollout.launcher_default_ready);
    }
}
