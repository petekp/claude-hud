use capacitor_daemon_protocol::{EventEnvelope, EventType};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::cmp::Ordering;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::reducer::{SessionRecord, SessionState};

const DEFAULT_HEM_CONFIG_RELATIVE_PATH: &str = ".capacitor/daemon/hem-v2.toml";

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum HemMode {
    Shadow,
    Primary,
}

impl Default for HemMode {
    fn default() -> Self {
        Self::Shadow
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct HemEngineConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub mode: HemMode,
}

impl Default for HemEngineConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            mode: HemMode::Primary,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct HemProviderConfig {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub version: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[allow(dead_code)]
pub struct HemCapabilitiesConfig {
    #[serde(default)]
    pub hook_snapshot_introspection: bool,
    #[serde(default)]
    pub event_delivery_ack: bool,
    #[serde(default)]
    pub global_ordering_guarantee: bool,
    #[serde(default)]
    pub per_event_correlation_id: bool,
    #[serde(default)]
    pub notification_matcher_support: bool,
    #[serde(default)]
    pub tool_use_id_consistency: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HemCapabilityDetectionStrategy {
    RuntimeHandshake,
    ConfigOnly,
}

impl Default for HemCapabilityDetectionStrategy {
    fn default() -> Self {
        Self::RuntimeHandshake
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct HemCapabilityDetectionConfig {
    #[serde(default)]
    pub strategy: HemCapabilityDetectionStrategy,
    #[serde(default = "default_capability_unknown_penalty")]
    pub unknown_penalty: f64,
    #[serde(default = "default_capability_misdeclared_penalty")]
    pub misdeclared_penalty: f64,
    #[serde(default = "default_capability_min_penalty_factor")]
    pub min_penalty_factor: f64,
}

impl Default for HemCapabilityDetectionConfig {
    fn default() -> Self {
        Self {
            strategy: HemCapabilityDetectionStrategy::default(),
            unknown_penalty: default_capability_unknown_penalty(),
            misdeclared_penalty: default_capability_misdeclared_penalty(),
            min_penalty_factor: default_capability_min_penalty_factor(),
        }
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
#[allow(dead_code)]
pub struct HemRuntimeConfig {
    #[serde(default)]
    pub engine: HemEngineConfig,
    #[serde(default)]
    pub provider: HemProviderConfig,
    #[serde(default)]
    pub capabilities: HemCapabilitiesConfig,
    #[serde(default)]
    pub capability_detection: HemCapabilityDetectionConfig,
    #[serde(default)]
    pub constraints: HemConstraintsConfig,
    #[serde(default)]
    pub thresholds: HemThresholdsConfig,
    #[serde(default)]
    pub source_reliability: HemSourceReliabilityConfig,
    #[serde(default)]
    pub weights: HemWeightsConfig,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct HemCapabilityWarning {
    pub code: String,
    pub capability: String,
    pub declared: String,
    pub observed: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct HemCapabilityStatus {
    pub strategy: String,
    pub handshake_seen: bool,
    pub confidence_penalty_factor: f64,
    pub unknown_count: u64,
    pub misdeclared_count: u64,
    pub warning_count: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_warning_at: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<HemCapabilityWarning>,
}

impl HemCapabilityStatus {
    pub fn from_strategy(strategy: &HemCapabilityDetectionStrategy) -> Self {
        Self {
            strategy: capability_strategy_str(strategy).to_string(),
            handshake_seen: false,
            confidence_penalty_factor: 1.0,
            unknown_count: 0,
            misdeclared_count: 0,
            warning_count: 0,
            last_warning_at: None,
            warnings: Vec::new(),
        }
    }
}

impl Default for HemCapabilityStatus {
    fn default() -> Self {
        Self::from_strategy(&HemCapabilityDetectionStrategy::default())
    }
}

#[derive(Debug, Clone)]
pub struct HemCapabilityAssessment {
    pub confidence_penalty_factor: f64,
    pub notification_matcher_support: bool,
    pub status: HemCapabilityStatus,
    pub warnings_changed: bool,
}

impl HemCapabilityAssessment {
    pub fn from_config(config: &HemRuntimeConfig) -> Self {
        Self {
            confidence_penalty_factor: 1.0,
            notification_matcher_support: config.capabilities.notification_matcher_support,
            status: HemCapabilityStatus::from_strategy(&config.capability_detection.strategy),
            warnings_changed: false,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct HemEffectiveCapabilities {
    pub confidence_penalty_factor: f64,
    pub notification_matcher_support: bool,
}

impl HemEffectiveCapabilities {
    #[allow(dead_code)]
    pub fn from_config(config: &HemRuntimeConfig) -> Self {
        Self {
            confidence_penalty_factor: 1.0,
            notification_matcher_support: config.capabilities.notification_matcher_support,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct HemThresholdsConfig {
    #[serde(default = "default_working_min_confidence")]
    pub working_min_confidence: f64,
    #[serde(default = "default_waiting_min_confidence")]
    pub waiting_min_confidence: f64,
    #[serde(default = "default_compacting_min_confidence")]
    pub compacting_min_confidence: f64,
    #[serde(default = "default_ready_min_confidence")]
    pub ready_min_confidence: f64,
    #[serde(default = "default_idle_min_confidence")]
    pub idle_min_confidence: f64,
}

impl Default for HemThresholdsConfig {
    fn default() -> Self {
        Self {
            working_min_confidence: default_working_min_confidence(),
            waiting_min_confidence: default_waiting_min_confidence(),
            compacting_min_confidence: default_compacting_min_confidence(),
            ready_min_confidence: default_ready_min_confidence(),
            idle_min_confidence: default_idle_min_confidence(),
        }
    }
}

impl HemThresholdsConfig {
    fn min_confidence_for_state(&self, state: &SessionState) -> f64 {
        match state {
            SessionState::Working => self.working_min_confidence,
            SessionState::Waiting => self.waiting_min_confidence,
            SessionState::Compacting => self.compacting_min_confidence,
            SessionState::Ready => self.ready_min_confidence,
            SessionState::Idle => self.idle_min_confidence,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)]
pub struct HemSourceReliabilityConfig {
    #[serde(default = "default_source_reliability_hook_event")]
    pub hook_event: f64,
    #[serde(default = "default_source_reliability_shell_cwd")]
    pub shell_cwd: f64,
    #[serde(default = "default_source_reliability_process_liveness")]
    pub process_liveness: f64,
    #[serde(default = "default_source_reliability_synthetic_guard")]
    pub synthetic_guard: f64,
}

impl Default for HemSourceReliabilityConfig {
    fn default() -> Self {
        Self {
            hook_event: default_source_reliability_hook_event(),
            shell_cwd: default_source_reliability_shell_cwd(),
            process_liveness: default_source_reliability_process_liveness(),
            synthetic_guard: default_source_reliability_synthetic_guard(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct HemSessionToProjectWeightsConfig {
    #[serde(default = "default_weight_project_boundary_from_file_path")]
    pub project_boundary_from_file_path: f64,
    #[serde(default = "default_weight_project_boundary_from_cwd")]
    pub project_boundary_from_cwd: f64,
    #[serde(default = "default_weight_recent_tool_activity")]
    pub recent_tool_activity: f64,
    #[serde(default = "default_weight_notification_signal")]
    pub notification_signal: f64,
}

impl Default for HemSessionToProjectWeightsConfig {
    fn default() -> Self {
        Self {
            project_boundary_from_file_path: default_weight_project_boundary_from_file_path(),
            project_boundary_from_cwd: default_weight_project_boundary_from_cwd(),
            recent_tool_activity: default_weight_recent_tool_activity(),
            notification_signal: default_weight_notification_signal(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct HemShellToProjectWeightsConfig {
    #[serde(default = "default_weight_exact_path_match")]
    pub exact_path_match: f64,
    #[serde(default = "default_weight_parent_path_match")]
    pub parent_path_match: f64,
    #[serde(default = "default_weight_terminal_focus_signal")]
    pub terminal_focus_signal: f64,
    #[serde(default = "default_weight_tmux_client_signal")]
    pub tmux_client_signal: f64,
}

impl Default for HemShellToProjectWeightsConfig {
    fn default() -> Self {
        Self {
            exact_path_match: default_weight_exact_path_match(),
            parent_path_match: default_weight_parent_path_match(),
            terminal_focus_signal: default_weight_terminal_focus_signal(),
            tmux_client_signal: default_weight_tmux_client_signal(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct HemStateSynthesisWeightsConfig {
    #[serde(default = "default_state_weight_working")]
    pub working: f64,
    #[serde(default = "default_state_weight_waiting")]
    pub waiting: f64,
    #[serde(default = "default_state_weight_compacting")]
    pub compacting: f64,
    #[serde(default = "default_state_weight_ready")]
    pub ready: f64,
    #[serde(default = "default_state_weight_idle")]
    pub idle: f64,
}

impl Default for HemStateSynthesisWeightsConfig {
    fn default() -> Self {
        Self {
            working: default_state_weight_working(),
            waiting: default_state_weight_waiting(),
            compacting: default_state_weight_compacting(),
            ready: default_state_weight_ready(),
            idle: default_state_weight_idle(),
        }
    }
}

impl HemStateSynthesisWeightsConfig {
    fn for_state(&self, state: &SessionState) -> f64 {
        match state {
            SessionState::Working => self.working,
            SessionState::Waiting => self.waiting,
            SessionState::Compacting => self.compacting,
            SessionState::Ready => self.ready,
            SessionState::Idle => self.idle,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct HemWeightsConfig {
    #[serde(default)]
    pub session_to_project: HemSessionToProjectWeightsConfig,
    #[serde(default)]
    pub shell_to_project: HemShellToProjectWeightsConfig,
    #[serde(default)]
    pub state_synthesis: HemStateSynthesisWeightsConfig,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HemConstraintsConfig {
    #[serde(default = "default_max_projects_per_session")]
    pub max_projects_per_session: usize,
    #[serde(default = "default_max_sessions_per_project")]
    pub max_sessions_per_project: usize,
}

impl Default for HemConstraintsConfig {
    fn default() -> Self {
        Self {
            max_projects_per_session: default_max_projects_per_session(),
            max_sessions_per_project: default_max_sessions_per_project(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct HemProjectState {
    pub project_id: String,
    pub project_path: String,
    pub state: SessionState,
    pub confidence: f64,
    pub evidence_count: usize,
}

#[derive(Debug, Clone)]
pub struct SessionProjectCandidate {
    pub session_id: String,
    pub project_id: String,
    pub project_path: String,
    pub score: f64,
    pub source_reliability: f64,
    pub observed_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct SessionProjectAssignment {
    pub session_id: String,
    pub project_id: String,
    pub project_path: String,
    pub score: f64,
    pub observed_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default)]
pub struct HemCapabilityTracker {
    handshake_seen: bool,
    hook_snapshot_introspection: Option<bool>,
    event_delivery_ack: Option<bool>,
    global_ordering_guarantee: Option<bool>,
    per_event_correlation_id: Option<bool>,
    notification_matcher_support: Option<bool>,
    tool_use_id_consistency: Option<ToolUseIdConsistencyLevel>,
    last_warning_signature: Option<String>,
}

impl HemCapabilityTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn observe_event(&mut self, event: &EventEnvelope) {
        if event.event_type == EventType::Notification && event.notification_type.is_some() {
            self.notification_matcher_support = Some(true);
        }

        let Some(metadata) = event.metadata.as_ref() else {
            return;
        };
        if metadata
            .get("correlation_id")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
        {
            self.per_event_correlation_id = Some(true);
        }

        let Some(capabilities) = metadata_capabilities_object(metadata) else {
            return;
        };
        self.handshake_seen = true;
        if let Some(value) = lookup_capability_bool(
            capabilities,
            &["hook_snapshot_introspection", "hookSnapshotIntrospection"],
        ) {
            self.hook_snapshot_introspection = Some(value);
        }
        if let Some(value) =
            lookup_capability_bool(capabilities, &["event_delivery_ack", "eventDeliveryAck"])
        {
            self.event_delivery_ack = Some(value);
        }
        if let Some(value) = lookup_capability_bool(
            capabilities,
            &["global_ordering_guarantee", "globalOrderingGuarantee"],
        ) {
            self.global_ordering_guarantee = Some(value);
        }
        if let Some(value) = lookup_capability_bool(
            capabilities,
            &["per_event_correlation_id", "perEventCorrelationId"],
        ) {
            self.per_event_correlation_id = Some(value);
        }
        if let Some(value) = lookup_capability_bool(
            capabilities,
            &["notification_matcher_support", "notificationMatcherSupport"],
        ) {
            self.notification_matcher_support = Some(value);
        }
        if let Some(value) = lookup_capability_string(
            capabilities,
            &["tool_use_id_consistency", "toolUseIdConsistency"],
        ) {
            self.tool_use_id_consistency = Some(parse_tool_use_id_consistency_level(value));
        }
    }

    pub fn assess(
        &mut self,
        config: &HemRuntimeConfig,
        observed_at: &str,
    ) -> HemCapabilityAssessment {
        match config.capability_detection.strategy {
            HemCapabilityDetectionStrategy::ConfigOnly => {
                let status =
                    HemCapabilityStatus::from_strategy(&config.capability_detection.strategy);
                self.last_warning_signature = None;
                HemCapabilityAssessment {
                    confidence_penalty_factor: 1.0,
                    notification_matcher_support: config.capabilities.notification_matcher_support,
                    status,
                    warnings_changed: false,
                }
            }
            HemCapabilityDetectionStrategy::RuntimeHandshake => {
                let mut unknown_count = 0_u64;
                let mut misdeclared_count = 0_u64;
                let mut warnings = Vec::new();

                evaluate_declared_bool_capability(
                    "hook_snapshot_introspection",
                    config.capabilities.hook_snapshot_introspection,
                    self.hook_snapshot_introspection,
                    &mut unknown_count,
                    &mut misdeclared_count,
                    &mut warnings,
                );
                evaluate_declared_bool_capability(
                    "event_delivery_ack",
                    config.capabilities.event_delivery_ack,
                    self.event_delivery_ack,
                    &mut unknown_count,
                    &mut misdeclared_count,
                    &mut warnings,
                );
                evaluate_declared_bool_capability(
                    "global_ordering_guarantee",
                    config.capabilities.global_ordering_guarantee,
                    self.global_ordering_guarantee,
                    &mut unknown_count,
                    &mut misdeclared_count,
                    &mut warnings,
                );
                evaluate_declared_bool_capability(
                    "per_event_correlation_id",
                    config.capabilities.per_event_correlation_id,
                    self.per_event_correlation_id,
                    &mut unknown_count,
                    &mut misdeclared_count,
                    &mut warnings,
                );
                evaluate_declared_bool_capability(
                    "notification_matcher_support",
                    config.capabilities.notification_matcher_support,
                    self.notification_matcher_support,
                    &mut unknown_count,
                    &mut misdeclared_count,
                    &mut warnings,
                );
                evaluate_declared_tool_use_consistency(
                    config.capabilities.tool_use_id_consistency.as_str(),
                    self.tool_use_id_consistency,
                    &mut unknown_count,
                    &mut misdeclared_count,
                    &mut warnings,
                );

                warnings.sort_by(|left, right| {
                    left.code
                        .cmp(&right.code)
                        .then_with(|| left.capability.cmp(&right.capability))
                });

                let penalty_factor = capability_penalty_factor(
                    unknown_count,
                    misdeclared_count,
                    &config.capability_detection,
                );
                let warning_count = warnings.len() as u64;
                let warning_signature = warning_signature(&warnings);
                let warnings_changed = warning_signature != self.last_warning_signature;
                self.last_warning_signature = warning_signature;

                let notification_matcher_support = self
                    .notification_matcher_support
                    .unwrap_or(config.capabilities.notification_matcher_support);
                let status = HemCapabilityStatus {
                    strategy: capability_strategy_str(&config.capability_detection.strategy)
                        .to_string(),
                    handshake_seen: self.handshake_seen,
                    confidence_penalty_factor: penalty_factor,
                    unknown_count,
                    misdeclared_count,
                    warning_count,
                    last_warning_at: (warning_count > 0).then(|| observed_at.to_string()),
                    warnings,
                };
                HemCapabilityAssessment {
                    confidence_penalty_factor: penalty_factor,
                    notification_matcher_support,
                    status,
                    warnings_changed,
                }
            }
        }
    }
}

pub fn default_config_path() -> Result<PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "Home directory not found".to_string())?;
    Ok(home.join(DEFAULT_HEM_CONFIG_RELATIVE_PATH))
}

pub fn load_runtime_config(path: Option<PathBuf>) -> Result<HemRuntimeConfig, String> {
    let config_path = match path {
        Some(path) => path,
        None => default_config_path()?,
    };

    if !config_path.exists() {
        return Ok(HemRuntimeConfig::default());
    }

    let content = fs_err::read_to_string(&config_path).map_err(|err| {
        format!(
            "Failed to read HEM config {}: {}",
            config_path.display(),
            err
        )
    })?;
    toml::from_str::<HemRuntimeConfig>(&content).map_err(|err| {
        format!(
            "Failed to parse HEM config {}: {}",
            config_path.display(),
            err
        )
    })
}

#[allow(dead_code)]
pub fn synthesize_project_states_shadow(
    sessions: &[SessionRecord],
    now: DateTime<Utc>,
    config: &HemRuntimeConfig,
) -> Vec<HemProjectState> {
    synthesize_project_states_shadow_with_capabilities(
        sessions,
        now,
        config,
        &HemEffectiveCapabilities::from_config(config),
    )
}

pub fn synthesize_project_states_shadow_with_capabilities(
    sessions: &[SessionRecord],
    now: DateTime<Utc>,
    config: &HemRuntimeConfig,
    effective_capabilities: &HemEffectiveCapabilities,
) -> Vec<HemProjectState> {
    let mut candidates: Vec<SessionProjectCandidate> = Vec::new();
    let mut session_evidence: HashMap<String, SessionEvidence> = HashMap::new();
    for record in sessions {
        if record.session_id.trim().is_empty() {
            continue;
        }
        let observed_at = parse_rfc3339(&record.updated_at).unwrap_or(now);
        let state = record.state.clone();
        let priority = state_priority(&state);
        let confidence = base_confidence(&state, now, observed_at);
        let min_confidence = clamp_unit(config.thresholds.min_confidence_for_state(&state));
        let session_id = record.session_id.clone();

        if !record.project_path.trim().is_empty() {
            let source_reliability = clamp_unit(
                config.source_reliability.hook_event
                    * effective_capabilities.confidence_penalty_factor,
            );
            let score = score_session_project_candidate(
                record,
                &state,
                confidence,
                source_reliability,
                now,
                config,
                effective_capabilities,
            );
            if score >= min_confidence {
                candidates.push(SessionProjectCandidate {
                    session_id: session_id.clone(),
                    project_id: if record.project_id.is_empty() {
                        record.project_path.clone()
                    } else {
                        record.project_id.clone()
                    },
                    project_path: record.project_path.clone(),
                    score,
                    source_reliability,
                    observed_at,
                });
            }
        }

        if !record.cwd.trim().is_empty() && record.cwd != record.project_path {
            let source_reliability = clamp_unit(
                config.source_reliability.shell_cwd
                    * effective_capabilities.confidence_penalty_factor,
            );
            let score = score_shell_project_candidate(
                record,
                &state,
                confidence,
                source_reliability,
                config,
            );
            if score >= min_confidence {
                candidates.push(SessionProjectCandidate {
                    session_id: session_id.clone(),
                    project_id: record.cwd.clone(),
                    project_path: record.cwd.clone(),
                    score,
                    source_reliability,
                    observed_at,
                });
            }
        }

        match session_evidence.get(&session_id) {
            Some(existing)
                if existing.priority > priority
                    || (existing.priority == priority && existing.observed_at >= observed_at) => {}
            _ => {
                session_evidence.insert(
                    session_id,
                    SessionEvidence {
                        state,
                        priority,
                        observed_at,
                        confidence,
                    },
                );
            }
        }
    }

    let assignments = assign_sessions_to_projects_deterministic(&candidates, &config.constraints);
    let mut by_project: HashMap<String, HemAggregate> = HashMap::new();
    for assignment in assignments {
        let Some(evidence) = session_evidence.get(&assignment.session_id) else {
            continue;
        };

        let entry = by_project
            .entry(assignment.project_path.clone())
            .or_insert_with(|| HemAggregate {
                project_id: assignment.project_id.clone(),
                project_path: assignment.project_path.clone(),
                state: evidence.state.clone(),
                priority: evidence.priority,
                updated_at: assignment.observed_at.max(evidence.observed_at),
                confidence: assignment.score.min(evidence.confidence),
                evidence_count: 0,
            });
        entry.evidence_count += 1;

        let observed_at = assignment.observed_at.max(evidence.observed_at);
        if evidence.priority > entry.priority
            || (evidence.priority == entry.priority && observed_at > entry.updated_at)
        {
            entry.state = evidence.state.clone();
            entry.priority = evidence.priority;
            entry.updated_at = observed_at;
            entry.confidence = assignment.score.min(evidence.confidence);
        }
    }

    let mut states = by_project
        .into_values()
        .map(|aggregate| HemProjectState {
            project_id: aggregate.project_id,
            project_path: aggregate.project_path,
            state: aggregate.state,
            confidence: aggregate.confidence,
            evidence_count: aggregate.evidence_count,
        })
        .collect::<Vec<_>>();
    states.sort_by(|left, right| {
        left.project_path
            .cmp(&right.project_path)
            .then_with(|| left.project_id.cmp(&right.project_id))
    });
    states
}

pub fn assign_sessions_to_projects_deterministic(
    candidates: &[SessionProjectCandidate],
    constraints: &HemConstraintsConfig,
) -> Vec<SessionProjectAssignment> {
    if constraints.max_projects_per_session == 0 || constraints.max_sessions_per_project == 0 {
        return Vec::new();
    }

    let mut ordered: Vec<&SessionProjectCandidate> = candidates.iter().collect();
    ordered.sort_by(|left, right| compare_candidates_best_first(left, right));

    let mut session_counts: HashMap<&str, usize> = HashMap::new();
    let mut project_counts: HashMap<&str, usize> = HashMap::new();
    let mut accepted: Vec<&SessionProjectCandidate> = Vec::new();

    for candidate in ordered {
        let session_count = session_counts
            .get(candidate.session_id.as_str())
            .copied()
            .unwrap_or(0);
        if session_count >= constraints.max_projects_per_session {
            continue;
        }

        let project_count = project_counts
            .get(candidate.project_path.as_str())
            .copied()
            .unwrap_or(0);
        if project_count >= constraints.max_sessions_per_project {
            continue;
        }

        accepted.push(candidate);
        session_counts.insert(candidate.session_id.as_str(), session_count + 1);
        project_counts.insert(candidate.project_path.as_str(), project_count + 1);
    }

    let mut assignments = accepted
        .into_iter()
        .map(|candidate| SessionProjectAssignment {
            session_id: candidate.session_id.clone(),
            project_id: candidate.project_id.clone(),
            project_path: candidate.project_path.clone(),
            score: candidate.score,
            observed_at: candidate.observed_at,
        })
        .collect::<Vec<_>>();
    assignments.sort_by(|left, right| {
        left.session_id
            .cmp(&right.session_id)
            .then_with(|| left.project_path.cmp(&right.project_path))
    });
    assignments
}

fn compare_candidates_best_first(
    left: &SessionProjectCandidate,
    right: &SessionProjectCandidate,
) -> Ordering {
    right
        .score
        .partial_cmp(&left.score)
        .unwrap_or(Ordering::Equal)
        .then_with(|| right.observed_at.cmp(&left.observed_at))
        .then_with(|| {
            right
                .source_reliability
                .partial_cmp(&left.source_reliability)
                .unwrap_or(Ordering::Equal)
        })
        .then_with(|| left.project_id.cmp(&right.project_id))
        .then_with(|| left.project_path.cmp(&right.project_path))
        .then_with(|| left.session_id.cmp(&right.session_id))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum ToolUseIdConsistencyLevel {
    None,
    Partial,
    Strong,
}

impl ToolUseIdConsistencyLevel {
    fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Partial => "partial",
            Self::Strong => "strong",
        }
    }
}

fn capability_strategy_str(strategy: &HemCapabilityDetectionStrategy) -> &'static str {
    match strategy {
        HemCapabilityDetectionStrategy::RuntimeHandshake => "runtime_handshake",
        HemCapabilityDetectionStrategy::ConfigOnly => "config_only",
    }
}

fn metadata_capabilities_object(metadata: &Value) -> Option<&Map<String, Value>> {
    let object = metadata.as_object()?;
    if let Some(capabilities) = object
        .get("hem_capabilities")
        .and_then(Value::as_object)
        .or_else(|| object.get("capabilities").and_then(Value::as_object))
    {
        return Some(capabilities);
    }
    if capability_keys_present(object) {
        return Some(object);
    }
    None
}

fn capability_keys_present(object: &Map<String, Value>) -> bool {
    object.contains_key("hook_snapshot_introspection")
        || object.contains_key("event_delivery_ack")
        || object.contains_key("global_ordering_guarantee")
        || object.contains_key("per_event_correlation_id")
        || object.contains_key("notification_matcher_support")
        || object.contains_key("tool_use_id_consistency")
}

fn lookup_capability_bool(object: &Map<String, Value>, keys: &[&str]) -> Option<bool> {
    keys.iter()
        .find_map(|key| object.get(*key).and_then(Value::as_bool))
}

fn lookup_capability_string<'a>(object: &'a Map<String, Value>, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| {
        object
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
    })
}

fn parse_tool_use_id_consistency_level(value: &str) -> ToolUseIdConsistencyLevel {
    match value.trim().to_ascii_lowercase().as_str() {
        "strong" => ToolUseIdConsistencyLevel::Strong,
        "partial" => ToolUseIdConsistencyLevel::Partial,
        _ => ToolUseIdConsistencyLevel::None,
    }
}

fn evaluate_declared_bool_capability(
    capability: &str,
    declared: bool,
    observed: Option<bool>,
    unknown_count: &mut u64,
    misdeclared_count: &mut u64,
    warnings: &mut Vec<HemCapabilityWarning>,
) {
    if !declared {
        return;
    }
    match observed {
        Some(true) => {}
        Some(false) => {
            *misdeclared_count = misdeclared_count.saturating_add(1);
            warnings.push(HemCapabilityWarning {
                code: "misdeclared_capability".to_string(),
                capability: capability.to_string(),
                declared: "true".to_string(),
                observed: "false".to_string(),
            });
        }
        None => {
            *unknown_count = unknown_count.saturating_add(1);
            warnings.push(HemCapabilityWarning {
                code: "unknown_capability".to_string(),
                capability: capability.to_string(),
                declared: "true".to_string(),
                observed: "unknown".to_string(),
            });
        }
    }
}

fn evaluate_declared_tool_use_consistency(
    declared: &str,
    observed: Option<ToolUseIdConsistencyLevel>,
    unknown_count: &mut u64,
    misdeclared_count: &mut u64,
    warnings: &mut Vec<HemCapabilityWarning>,
) {
    let declared = parse_tool_use_id_consistency_level(declared);
    if declared == ToolUseIdConsistencyLevel::None {
        return;
    }
    match observed {
        Some(value) if value >= declared => {}
        Some(value) => {
            *misdeclared_count = misdeclared_count.saturating_add(1);
            warnings.push(HemCapabilityWarning {
                code: "misdeclared_capability".to_string(),
                capability: "tool_use_id_consistency".to_string(),
                declared: declared.as_str().to_string(),
                observed: value.as_str().to_string(),
            });
        }
        None => {
            *unknown_count = unknown_count.saturating_add(1);
            warnings.push(HemCapabilityWarning {
                code: "unknown_capability".to_string(),
                capability: "tool_use_id_consistency".to_string(),
                declared: declared.as_str().to_string(),
                observed: "unknown".to_string(),
            });
        }
    }
}

fn capability_penalty_factor(
    unknown_count: u64,
    misdeclared_count: u64,
    config: &HemCapabilityDetectionConfig,
) -> f64 {
    let unknown_penalty = clamp_unit(config.unknown_penalty);
    let misdeclared_penalty = clamp_unit(config.misdeclared_penalty);
    let min_penalty_factor = clamp_unit(config.min_penalty_factor);
    let unknown_multiplier = unknown_penalty.powi(unknown_count as i32);
    let misdeclared_multiplier = misdeclared_penalty.powi(misdeclared_count as i32);
    (unknown_multiplier * misdeclared_multiplier).clamp(min_penalty_factor, 1.0)
}

fn warning_signature(warnings: &[HemCapabilityWarning]) -> Option<String> {
    if warnings.is_empty() {
        return None;
    }
    Some(
        warnings
            .iter()
            .map(|warning| {
                format!(
                    "{}:{}:{}:{}",
                    warning.code, warning.capability, warning.declared, warning.observed
                )
            })
            .collect::<Vec<_>>()
            .join("|"),
    )
}

fn default_max_projects_per_session() -> usize {
    1
}

fn default_max_sessions_per_project() -> usize {
    64
}

fn default_working_min_confidence() -> f64 {
    0.70
}

fn default_waiting_min_confidence() -> f64 {
    0.70
}

fn default_compacting_min_confidence() -> f64 {
    0.70
}

fn default_ready_min_confidence() -> f64 {
    0.55
}

fn default_idle_min_confidence() -> f64 {
    0.50
}

fn default_source_reliability_hook_event() -> f64 {
    1.0
}

fn default_source_reliability_shell_cwd() -> f64 {
    0.90
}

fn default_source_reliability_process_liveness() -> f64 {
    0.95
}

fn default_source_reliability_synthetic_guard() -> f64 {
    0.80
}

fn default_capability_unknown_penalty() -> f64 {
    0.95
}

fn default_capability_misdeclared_penalty() -> f64 {
    0.80
}

fn default_capability_min_penalty_factor() -> f64 {
    0.50
}

fn default_weight_project_boundary_from_file_path() -> f64 {
    0.45
}

fn default_weight_project_boundary_from_cwd() -> f64 {
    0.25
}

fn default_weight_recent_tool_activity() -> f64 {
    0.20
}

fn default_weight_notification_signal() -> f64 {
    0.10
}

fn default_weight_exact_path_match() -> f64 {
    0.50
}

fn default_weight_parent_path_match() -> f64 {
    0.20
}

fn default_weight_terminal_focus_signal() -> f64 {
    0.20
}

fn default_weight_tmux_client_signal() -> f64 {
    0.10
}

fn default_state_weight_working() -> f64 {
    1.00
}

fn default_state_weight_waiting() -> f64 {
    0.95
}

fn default_state_weight_compacting() -> f64 {
    0.90
}

fn default_state_weight_ready() -> f64 {
    0.70
}

fn default_state_weight_idle() -> f64 {
    0.40
}

const SCORE_STATE_COMPONENT_WEIGHT: f64 = 0.40;
const SCORE_SIGNAL_COMPONENT_WEIGHT: f64 = 0.60;
const RECENT_ACTIVITY_WINDOW_SECS: i64 = 180;
const SESSION_BOUNDARY_ANCHOR: f64 = 0.20;

fn score_session_project_candidate(
    record: &SessionRecord,
    state: &SessionState,
    base_confidence: f64,
    source_reliability: f64,
    now: DateTime<Utc>,
    config: &HemRuntimeConfig,
    effective_capabilities: &HemEffectiveCapabilities,
) -> f64 {
    let relation = path_relation(record.project_path.as_str(), record.cwd.as_str());
    let relation_signal =
        matches!(relation, PathRelation::Exact | PathRelation::Parent) as u8 as f64;
    let recent_activity = is_recent_tool_activity(record, now) as u8 as f64;
    let notification_signal =
        has_notification_signal(record, effective_capabilities.notification_matcher_support) as u8
            as f64;

    let signal_component = clamp_unit(
        SESSION_BOUNDARY_ANCHOR
            + config
                .weights
                .session_to_project
                .project_boundary_from_file_path
            + (config.weights.session_to_project.project_boundary_from_cwd * relation_signal)
            + (config.weights.session_to_project.recent_tool_activity * recent_activity)
            + (config.weights.session_to_project.notification_signal * notification_signal),
    );
    blend_score_components(
        base_confidence,
        state,
        signal_component,
        source_reliability,
        &config.weights,
    )
}

fn score_shell_project_candidate(
    record: &SessionRecord,
    state: &SessionState,
    base_confidence: f64,
    source_reliability: f64,
    config: &HemRuntimeConfig,
) -> f64 {
    let relation = path_relation(record.project_path.as_str(), record.cwd.as_str());
    let exact_path_match = (matches!(relation, PathRelation::Exact)
        || record.project_path.trim().is_empty()) as u8 as f64;
    let parent_path_match = matches!(relation, PathRelation::Parent) as u8 as f64;
    let terminal_focus_signal = (!record.cwd.trim().is_empty()) as u8 as f64;
    let tmux_client_signal = (record.pid > 0) as u8 as f64;

    let signal_component = clamp_unit(
        (config.weights.shell_to_project.exact_path_match * exact_path_match)
            + (config.weights.shell_to_project.parent_path_match * parent_path_match)
            + (config.weights.shell_to_project.terminal_focus_signal * terminal_focus_signal)
            + (config.weights.shell_to_project.tmux_client_signal * tmux_client_signal),
    );
    blend_score_components(
        base_confidence,
        state,
        signal_component,
        source_reliability,
        &config.weights,
    )
}

fn blend_score_components(
    base_confidence: f64,
    state: &SessionState,
    signal_component: f64,
    source_reliability: f64,
    weights: &HemWeightsConfig,
) -> f64 {
    let weighted_state = clamp_unit(base_confidence * weights.state_synthesis.for_state(state));
    let blended = (weighted_state * SCORE_STATE_COMPONENT_WEIGHT)
        + (signal_component * SCORE_SIGNAL_COMPONENT_WEIGHT);
    clamp_shadow_score(clamp_unit(source_reliability) * blended)
}

fn clamp_unit(value: f64) -> f64 {
    if value.is_finite() {
        value.clamp(0.0, 1.0)
    } else {
        0.0
    }
}

fn clamp_shadow_score(value: f64) -> f64 {
    clamp_unit(value).min(0.99)
}

fn is_recent_tool_activity(record: &SessionRecord, now: DateTime<Utc>) -> bool {
    record
        .last_activity_at
        .as_deref()
        .and_then(parse_rfc3339)
        .is_some_and(|last_activity| {
            now.signed_duration_since(last_activity).num_seconds() <= RECENT_ACTIVITY_WINDOW_SECS
        })
}

fn has_notification_signal(record: &SessionRecord, notification_matcher_support: bool) -> bool {
    if !notification_matcher_support {
        return false;
    }
    record
        .last_event
        .as_deref()
        .is_some_and(|event| event.starts_with("notification"))
}

#[derive(Clone, Copy)]
enum PathRelation {
    Exact,
    Parent,
    None,
}

fn path_relation(reference: &str, candidate: &str) -> PathRelation {
    let reference = reference.trim();
    let candidate = candidate.trim();
    if reference.is_empty() || candidate.is_empty() {
        return PathRelation::None;
    }
    let reference_path = Path::new(reference);
    let candidate_path = Path::new(candidate);
    if reference_path == candidate_path {
        return PathRelation::Exact;
    }
    if candidate_path.starts_with(reference_path) || reference_path.starts_with(candidate_path) {
        return PathRelation::Parent;
    }
    PathRelation::None
}

#[derive(Debug, Clone)]
struct HemAggregate {
    project_id: String,
    project_path: String,
    state: SessionState,
    priority: u8,
    updated_at: DateTime<Utc>,
    confidence: f64,
    evidence_count: usize,
}

#[derive(Debug, Clone)]
struct SessionEvidence {
    state: SessionState,
    priority: u8,
    observed_at: DateTime<Utc>,
    confidence: f64,
}

fn state_priority(state: &SessionState) -> u8 {
    match state {
        SessionState::Working => 4,
        SessionState::Waiting => 3,
        SessionState::Compacting => 2,
        SessionState::Ready => 1,
        SessionState::Idle => 0,
    }
}

fn base_confidence(state: &SessionState, now: DateTime<Utc>, updated_at: DateTime<Utc>) -> f64 {
    let base: f64 = match state {
        SessionState::Working => 0.90,
        SessionState::Waiting => 0.85,
        SessionState::Compacting => 0.80,
        SessionState::Ready => 0.65,
        SessionState::Idle => 0.55,
    };
    let age_secs = now.signed_duration_since(updated_at).num_seconds().max(0);
    if age_secs > 600 {
        (base - 0.10_f64).max(0.10_f64)
    } else {
        base
    }
}

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|parsed| parsed.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reducer::SessionState;
    use capacitor_daemon_protocol::{EventEnvelope, EventType};
    use serde_json::json;

    fn make_record(
        session_id: &str,
        project_path: &str,
        state: SessionState,
        updated_at: &str,
    ) -> SessionRecord {
        SessionRecord {
            session_id: session_id.to_string(),
            pid: 0,
            state,
            cwd: project_path.to_string(),
            project_id: project_path.to_string(),
            project_path: project_path.to_string(),
            updated_at: updated_at.to_string(),
            state_changed_at: updated_at.to_string(),
            last_event: None,
            last_activity_at: None,
            tools_in_flight: 0,
            ready_reason: None,
        }
    }

    #[test]
    fn load_runtime_config_defaults_when_file_missing() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("missing-hem.toml");
        let config = load_runtime_config(Some(path)).expect("load config");
        assert!(config.engine.enabled);
        assert_eq!(config.engine.mode, HemMode::Primary);
    }

    #[test]
    fn load_runtime_config_parses_engine_provider_and_capabilities() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("hem.toml");
        fs_err::write(
            &path,
            r#"
[engine]
enabled = true
mode = "primary"

[provider]
name = "claude_code"
version = "2.x"

[capabilities]
hook_snapshot_introspection = false
event_delivery_ack = true
global_ordering_guarantee = false
per_event_correlation_id = true
notification_matcher_support = true
tool_use_id_consistency = "partial"

[capability_detection]
strategy = "config_only"
unknown_penalty = 0.92
misdeclared_penalty = 0.78
min_penalty_factor = 0.44

[constraints]
max_projects_per_session = 1
max_sessions_per_project = 8

        [thresholds]
        working_min_confidence = 0.75

        [source_reliability]
        hook_event = 0.95
        shell_cwd = 0.85

        [weights.session_to_project]
        project_boundary_from_file_path = 0.5
        "#,
        )
        .expect("write config");

        let config = load_runtime_config(Some(path)).expect("load config");
        assert!(config.engine.enabled);
        assert_eq!(config.engine.mode, HemMode::Primary);
        assert_eq!(config.provider.name, "claude_code");
        assert_eq!(config.provider.version, "2.x");
        assert!(config.capabilities.event_delivery_ack);
        assert!(config.capabilities.per_event_correlation_id);
        assert_eq!(config.capabilities.tool_use_id_consistency, "partial");
        assert_eq!(
            config.capability_detection.strategy,
            HemCapabilityDetectionStrategy::ConfigOnly
        );
        assert!((config.capability_detection.unknown_penalty - 0.92).abs() < f64::EPSILON);
        assert!((config.capability_detection.misdeclared_penalty - 0.78).abs() < f64::EPSILON);
        assert!((config.capability_detection.min_penalty_factor - 0.44).abs() < f64::EPSILON);
        assert_eq!(config.constraints.max_projects_per_session, 1);
        assert_eq!(config.constraints.max_sessions_per_project, 8);
        assert!((config.thresholds.working_min_confidence - 0.75).abs() < f64::EPSILON);
        assert!((config.source_reliability.hook_event - 0.95).abs() < f64::EPSILON);
        assert!((config.source_reliability.shell_cwd - 0.85).abs() < f64::EPSILON);
        assert!(
            (config
                .weights
                .session_to_project
                .project_boundary_from_file_path
                - 0.5)
                .abs()
                < f64::EPSILON
        );
    }

    #[test]
    fn synthesize_project_states_shadow_prefers_higher_priority_and_sorts() {
        let now = parse_rfc3339("2026-02-13T12:00:00Z").expect("parse now");
        let sessions = vec![
            make_record(
                "session-z-ready",
                "/Users/petepetrash/Code/zeta",
                SessionState::Ready,
                "2026-02-13T11:59:50Z",
            ),
            make_record(
                "session-z-working",
                "/Users/petepetrash/Code/zeta",
                SessionState::Working,
                "2026-02-13T11:59:00Z",
            ),
            make_record(
                "session-a-idle",
                "/Users/petepetrash/Code/alpha",
                SessionState::Idle,
                "2026-02-13T11:59:55Z",
            ),
        ];
        let states = synthesize_project_states_shadow(&sessions, now, &HemRuntimeConfig::default());
        assert_eq!(states.len(), 2);
        assert_eq!(states[0].project_path, "/Users/petepetrash/Code/alpha");
        assert_eq!(states[1].project_path, "/Users/petepetrash/Code/zeta");
        assert_eq!(states[1].state, SessionState::Working);
        assert_eq!(states[1].evidence_count, 2);
    }

    #[test]
    fn synthesize_project_states_shadow_prefers_project_boundary_over_unrelated_cwd_by_default() {
        let now = parse_rfc3339("2026-02-13T12:00:00Z").expect("parse now");
        let mut record = make_record(
            "session-boundary",
            "/Users/petepetrash/Code/project-a",
            SessionState::Working,
            "2026-02-13T11:59:50Z",
        );
        record.cwd = "/Users/petepetrash/Downloads".to_string();

        let states = synthesize_project_states_shadow(&[record], now, &HemRuntimeConfig::default());
        assert_eq!(states.len(), 1);
        assert_eq!(states[0].project_path, "/Users/petepetrash/Code/project-a");
    }

    #[test]
    fn synthesize_project_states_shadow_uses_config_weighting_to_prefer_cwd_when_configured() {
        let now = parse_rfc3339("2026-02-13T12:00:00Z").expect("parse now");
        let mut record = make_record(
            "session-config-weight",
            "/Users/petepetrash/Code/project-a",
            SessionState::Working,
            "2026-02-13T11:59:50Z",
        );
        record.cwd = "/Users/petepetrash/Code/project-a/subdir".to_string();

        let mut config = HemRuntimeConfig::default();
        config.source_reliability.hook_event = 0.20;
        config
            .weights
            .session_to_project
            .project_boundary_from_file_path = 0.0;
        config.weights.session_to_project.project_boundary_from_cwd = 0.0;
        config.weights.session_to_project.recent_tool_activity = 0.0;
        config.weights.session_to_project.notification_signal = 0.0;
        config.weights.shell_to_project.exact_path_match = 0.0;
        config.weights.shell_to_project.parent_path_match = 1.0;
        config.weights.shell_to_project.terminal_focus_signal = 1.0;
        config.weights.shell_to_project.tmux_client_signal = 0.0;
        config.thresholds.working_min_confidence = 0.30;

        let states = synthesize_project_states_shadow(&[record], now, &config);
        assert_eq!(states.len(), 1);
        assert_eq!(
            states[0].project_path,
            "/Users/petepetrash/Code/project-a/subdir"
        );
    }

    #[test]
    fn deterministic_assignment_tie_breaks_by_project_path() {
        let now = parse_rfc3339("2026-02-13T12:00:00Z").expect("parse now");
        let assignments = assign_sessions_to_projects_deterministic(
            &[
                SessionProjectCandidate {
                    session_id: "session-1".to_string(),
                    project_id: "/Users/petepetrash/Code/zeta".to_string(),
                    project_path: "/Users/petepetrash/Code/zeta".to_string(),
                    score: 0.80,
                    source_reliability: 0.90,
                    observed_at: now,
                },
                SessionProjectCandidate {
                    session_id: "session-1".to_string(),
                    project_id: "/Users/petepetrash/Code/alpha".to_string(),
                    project_path: "/Users/petepetrash/Code/alpha".to_string(),
                    score: 0.80,
                    source_reliability: 0.90,
                    observed_at: now,
                },
            ],
            &HemConstraintsConfig::default(),
        );
        assert_eq!(assignments.len(), 1);
        assert_eq!(
            assignments[0].project_path,
            "/Users/petepetrash/Code/alpha".to_string()
        );
        assert!((assignments[0].score - 0.80).abs() < f64::EPSILON);
    }

    #[test]
    fn deterministic_assignment_prefers_higher_source_reliability_on_equal_score() {
        let now = parse_rfc3339("2026-02-13T12:00:00Z").expect("parse now");
        let assignments = assign_sessions_to_projects_deterministic(
            &[
                SessionProjectCandidate {
                    session_id: "session-1".to_string(),
                    project_id: "project-low-rel".to_string(),
                    project_path: "project-low-rel".to_string(),
                    score: 0.80,
                    source_reliability: 0.80,
                    observed_at: now,
                },
                SessionProjectCandidate {
                    session_id: "session-1".to_string(),
                    project_id: "project-high-rel".to_string(),
                    project_path: "project-high-rel".to_string(),
                    score: 0.80,
                    source_reliability: 0.95,
                    observed_at: now,
                },
            ],
            &HemConstraintsConfig::default(),
        );
        assert_eq!(assignments.len(), 1);
        assert_eq!(assignments[0].project_path, "project-high-rel");
    }

    #[test]
    fn assignment_enforces_project_capacity_and_uses_deterministic_fallback() {
        let now = parse_rfc3339("2026-02-13T12:00:00Z").expect("parse now");
        let constraints = HemConstraintsConfig {
            max_projects_per_session: 1,
            max_sessions_per_project: 1,
        };
        let assignments = assign_sessions_to_projects_deterministic(
            &[
                SessionProjectCandidate {
                    session_id: "session-a".to_string(),
                    project_id: "project-alpha".to_string(),
                    project_path: "project-alpha".to_string(),
                    score: 0.90,
                    source_reliability: 1.0,
                    observed_at: now,
                },
                SessionProjectCandidate {
                    session_id: "session-b".to_string(),
                    project_id: "project-alpha".to_string(),
                    project_path: "project-alpha".to_string(),
                    score: 0.89,
                    source_reliability: 1.0,
                    observed_at: now,
                },
                SessionProjectCandidate {
                    session_id: "session-b".to_string(),
                    project_id: "project-beta".to_string(),
                    project_path: "project-beta".to_string(),
                    score: 0.88,
                    source_reliability: 1.0,
                    observed_at: now,
                },
            ],
            &constraints,
        );
        assert_eq!(assignments.len(), 2);
        let session_b = assignments
            .iter()
            .find(|assignment| assignment.session_id == "session-b")
            .expect("session-b assignment");
        assert_eq!(session_b.project_path, "project-beta");
    }

    #[test]
    fn assignment_returns_empty_when_per_session_capacity_zero() {
        let now = parse_rfc3339("2026-02-13T12:00:00Z").expect("parse now");
        let constraints = HemConstraintsConfig {
            max_projects_per_session: 0,
            max_sessions_per_project: 10,
        };
        let assignments = assign_sessions_to_projects_deterministic(
            &[SessionProjectCandidate {
                session_id: "session-1".to_string(),
                project_id: "project-1".to_string(),
                project_path: "project-1".to_string(),
                score: 0.8,
                source_reliability: 1.0,
                observed_at: now,
            }],
            &constraints,
        );
        assert!(assignments.is_empty());
    }

    #[test]
    fn capability_assessment_marks_declared_unobserved_capability_as_unknown() {
        let mut config = HemRuntimeConfig::default();
        config.capability_detection.strategy = HemCapabilityDetectionStrategy::RuntimeHandshake;
        config.capability_detection.unknown_penalty = 0.91;
        config.capabilities.notification_matcher_support = true;

        let mut tracker = HemCapabilityTracker::new();
        let assessment = tracker.assess(&config, "2026-02-13T12:00:00Z");

        assert_eq!(assessment.status.unknown_count, 1);
        assert_eq!(assessment.status.misdeclared_count, 0);
        assert_eq!(assessment.status.warning_count, 1);
        assert!((assessment.confidence_penalty_factor - 0.91).abs() < f64::EPSILON);
    }

    #[test]
    fn capability_assessment_marks_false_handshake_as_misdeclared() {
        let mut config = HemRuntimeConfig::default();
        config.capability_detection.strategy = HemCapabilityDetectionStrategy::RuntimeHandshake;
        config.capability_detection.misdeclared_penalty = 0.73;
        config.capabilities.notification_matcher_support = true;

        let mut tracker = HemCapabilityTracker::new();
        tracker.observe_event(&EventEnvelope {
            event_id: "evt-capabilities".to_string(),
            recorded_at: "2026-02-13T12:00:00Z".to_string(),
            event_type: EventType::PostToolUse,
            session_id: Some("session-1".to_string()),
            pid: Some(1),
            cwd: Some("/repo".to_string()),
            tool: Some("Read".to_string()),
            file_path: None,
            parent_app: None,
            tty: None,
            tmux_session: None,
            tmux_client_tty: None,
            notification_type: None,
            stop_hook_active: None,
            metadata: Some(json!({
                "capabilities": {
                    "notification_matcher_support": false
                }
            })),
        });

        let assessment = tracker.assess(&config, "2026-02-13T12:00:00Z");
        assert!(assessment.status.handshake_seen);
        assert_eq!(assessment.status.unknown_count, 0);
        assert_eq!(assessment.status.misdeclared_count, 1);
        assert_eq!(assessment.status.warning_count, 1);
        assert!((assessment.confidence_penalty_factor - 0.73).abs() < f64::EPSILON);
        assert!(!assessment.notification_matcher_support);
    }

    #[test]
    fn synthesize_project_states_shadow_applies_capability_penalty_factor() {
        let now = parse_rfc3339("2026-02-13T12:00:00Z").expect("parse now");
        let record = make_record(
            "session-penalty",
            "/Users/petepetrash/Code/project-a",
            SessionState::Working,
            "2026-02-13T11:59:50Z",
        );
        let config = HemRuntimeConfig::default();

        let without_penalty = synthesize_project_states_shadow_with_capabilities(
            &[record.clone()],
            now,
            &config,
            &HemEffectiveCapabilities::from_config(&config),
        );
        assert_eq!(without_penalty.len(), 1);

        let with_penalty = synthesize_project_states_shadow_with_capabilities(
            &[record],
            now,
            &config,
            &HemEffectiveCapabilities {
                confidence_penalty_factor: 0.5,
                notification_matcher_support: config.capabilities.notification_matcher_support,
            },
        );
        assert!(with_penalty.is_empty());
    }
}
