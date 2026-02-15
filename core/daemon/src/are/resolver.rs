use crate::are::registry::{ShellRegistry, TmuxRegistry};
use crate::are::state::RoutingConfig;
use capacitor_daemon_protocol::{
    RoutingConfidence, RoutingDiagnostics, RoutingEvidence, RoutingSnapshot, RoutingStatus,
    RoutingTarget, RoutingTargetKind,
};
use chrono::{DateTime, Utc};
use std::collections::HashMap;

pub struct ResolveInput<'a> {
    pub project_path: &'a str,
    pub workspace_id: &'a str,
    pub now: DateTime<Utc>,
    pub config: &'a RoutingConfig,
    pub shell_registry: &'a ShellRegistry,
    pub tmux_registry: &'a TmuxRegistry,
}

pub fn resolve(input: ResolveInput<'_>) -> RoutingDiagnostics {
    let mut signal_ages_ms = HashMap::new();
    let mut candidate_targets: Vec<RoutingTarget> = Vec::new();
    let mut conflicts: Vec<String> = Vec::new();
    let mut scope_resolution = "global_fallback".to_string();

    let mut tmux_candidates = Vec::new();
    let mut freshest_tmux_age: Option<u64> = None;
    for client in &input.tmux_registry.clients {
        let age_ms = age_ms(input.now, client.captured_at);
        freshest_tmux_age = Some(freshest_tmux_age.map_or(age_ms, |current| current.min(age_ms)));
        if age_ms > input.config.tmux_signal_fresh_ms {
            continue;
        }

        let (scope_quality, scope_name) = candidate_scope_quality(
            input.config,
            input.workspace_id,
            input.project_path,
            Some(client.session_name.as_str()),
            client.pane_current_path.as_deref(),
        );
        let workspace_scoped = scope_name.starts_with("workspace_binding_");
        let path_scoped = client
            .pane_current_path
            .as_deref()
            .map(|path| shell_path_is_within_project(input.project_path, path))
            .unwrap_or(false);
        let session_scoped =
            session_name_matches_project(input.project_path, client.session_name.as_str());
        let session_name_fallback = session_scoped && !workspace_scoped && !path_scoped;
        if scope_quality == 0 || (!workspace_scoped && !path_scoped && !session_scoped) {
            continue;
        }
        let effective_scope_quality = if session_scoped {
            scope_quality.max(3)
        } else {
            scope_quality
        };
        let effective_scope_name = if session_scoped && scope_quality < 3 {
            "session_name_exact".to_string()
        } else {
            scope_name
        };
        tmux_candidates.push(ResolvedCandidate {
            target: RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some(client.session_name.clone()),
            },
            status: RoutingStatus::Attached,
            confidence: RoutingConfidence::High,
            reason_code: "TMUX_CLIENT_ATTACHED",
            reason: format!(
                "Attached tmux client on {} mapped to session {}",
                client.client_tty, client.session_name
            ),
            evidence: vec![
                RoutingEvidence {
                    evidence_type: "tmux_client".to_string(),
                    value: client.client_tty.clone(),
                    age_ms,
                    trust_rank: 1,
                },
                RoutingEvidence {
                    evidence_type: "tmux_pane_path".to_string(),
                    value: client
                        .pane_current_path
                        .clone()
                        .unwrap_or_else(|| "unknown".to_string()),
                    age_ms,
                    trust_rank: 1,
                },
            ],
            trust_rank: 1,
            scope_quality: effective_scope_quality,
            age_ms,
            scope_resolution: effective_scope_name,
            session_name_fallback,
        });
    }

    if tmux_candidates
        .iter()
        .any(|candidate| !candidate.session_name_fallback)
    {
        tmux_candidates.retain(|candidate| !candidate.session_name_fallback);
    }

    if let Some(age) = freshest_tmux_age {
        signal_ages_ms.insert("tmux_client".to_string(), age);
    }

    candidate_targets.extend(
        tmux_candidates
            .iter()
            .map(|candidate| candidate.target.clone()),
    );
    if let Some(best) = pick_best_candidate(&tmux_candidates) {
        scope_resolution = best.scope_resolution.clone();
        conflicts.extend(collect_conflicts(&tmux_candidates, best));
        return build_result(
            input,
            &best,
            signal_ages_ms,
            candidate_targets,
            conflicts,
            scope_resolution,
        );
    }

    let mut tmux_session_candidates = Vec::new();
    for session in &input.tmux_registry.sessions {
        let age_ms = age_ms(input.now, session.captured_at);
        let first_path = session.pane_paths.first().map(|value| value.as_str());
        let (scope_quality, scope_name) = candidate_scope_quality(
            input.config,
            input.workspace_id,
            input.project_path,
            Some(session.session_name.as_str()),
            first_path,
        );
        let workspace_scoped = scope_name.starts_with("workspace_binding_");
        let path_scoped = first_path
            .map(|path| shell_path_is_within_project(input.project_path, path))
            .unwrap_or(false);
        let session_scoped =
            session_name_matches_project(input.project_path, session.session_name.as_str());
        let session_name_fallback = session_scoped && !workspace_scoped && !path_scoped;
        if session_name_fallback && age_ms > input.config.tmux_signal_fresh_ms {
            continue;
        }
        if scope_quality == 0 || (!workspace_scoped && !path_scoped && !session_scoped) {
            continue;
        }
        let effective_scope_quality = if session_scoped {
            scope_quality.max(3)
        } else {
            scope_quality
        };
        let effective_scope_name = if session_scoped && scope_quality < 3 {
            "session_name_exact".to_string()
        } else {
            scope_name
        };
        tmux_session_candidates.push(ResolvedCandidate {
            target: RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some(session.session_name.clone()),
            },
            status: RoutingStatus::Detached,
            confidence: RoutingConfidence::Medium,
            reason_code: "TMUX_SESSION_DETACHED",
            reason: format!(
                "Detached tmux session {} is available",
                session.session_name
            ),
            evidence: vec![RoutingEvidence {
                evidence_type: "tmux_session".to_string(),
                value: session.session_name.clone(),
                age_ms,
                trust_rank: 1,
            }],
            trust_rank: 1,
            scope_quality: effective_scope_quality,
            age_ms,
            scope_resolution: effective_scope_name,
            session_name_fallback,
        });
    }

    if tmux_session_candidates
        .iter()
        .any(|candidate| !candidate.session_name_fallback)
    {
        tmux_session_candidates.retain(|candidate| !candidate.session_name_fallback);
    }

    candidate_targets.extend(
        tmux_session_candidates
            .iter()
            .map(|candidate| candidate.target.clone()),
    );
    if let Some(best) = pick_best_candidate(&tmux_session_candidates) {
        scope_resolution = best.scope_resolution.clone();
        conflicts.extend(collect_conflicts(&tmux_session_candidates, best));
        return build_result(
            input,
            &best,
            signal_ages_ms,
            candidate_targets,
            conflicts,
            scope_resolution,
        );
    }

    let mut shell_candidates = Vec::new();
    let mut stale_shell_candidates = Vec::new();
    let mut freshest_shell_age: Option<u64> = None;
    let shell_retention_ms = input
        .config
        .shell_retention_hours
        .saturating_mul(60 * 60 * 1_000);
    for shell in input.shell_registry.all() {
        let age_ms = age_ms(input.now, shell.recorded_at);
        freshest_shell_age = Some(freshest_shell_age.map_or(age_ms, |current| current.min(age_ms)));
        let (scope_quality, scope_name) = candidate_scope_quality(
            input.config,
            input.workspace_id,
            input.project_path,
            shell.tmux_session.as_deref(),
            Some(shell.cwd.as_str()),
        );
        let workspace_scoped = scope_name.starts_with("workspace_binding_");
        let path_scoped = shell_path_is_within_project(input.project_path, shell.cwd.as_str());
        if scope_quality <= 1 || (!workspace_scoped && !path_scoped) {
            // Shell fallback must be project/workspace scoped.
            // Global shell fallback causes cross-project misrouting where all cards
            // collapse to the same terminal app/session target.
            continue;
        }
        let target = if let Some(session) = shell.tmux_session.as_ref() {
            RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some(session.clone()),
            }
        } else if let Some(parent_app) = sanitize_parent_app(shell.parent_app.as_deref()) {
            RoutingTarget {
                kind: RoutingTargetKind::TerminalApp,
                value: Some(parent_app.to_string()),
            }
        } else {
            continue;
        };
        let confidence = if target.kind == RoutingTargetKind::TmuxSession {
            RoutingConfidence::Medium
        } else {
            RoutingConfidence::Low
        };
        let candidate = ResolvedCandidate {
            target,
            status: RoutingStatus::Detached,
            confidence,
            reason_code: if age_ms <= input.config.shell_signal_fresh_ms {
                "SHELL_FALLBACK_ACTIVE"
            } else {
                "SHELL_FALLBACK_STALE"
            },
            reason: format!("Shell fallback from {}", shell.tty),
            evidence: vec![RoutingEvidence {
                evidence_type: "shell_cwd".to_string(),
                value: shell.cwd.clone(),
                age_ms,
                trust_rank: 2,
            }],
            trust_rank: 2,
            scope_quality,
            age_ms,
            scope_resolution: scope_name,
            session_name_fallback: false,
        };
        if age_ms <= input.config.shell_signal_fresh_ms {
            shell_candidates.push(candidate);
        } else if age_ms <= shell_retention_ms {
            stale_shell_candidates.push(candidate);
        }
    }

    if let Some(age) = freshest_shell_age {
        signal_ages_ms.insert("shell_cwd".to_string(), age);
    }

    candidate_targets.extend(
        shell_candidates
            .iter()
            .map(|candidate| candidate.target.clone()),
    );
    if let Some(best) = pick_best_candidate(&shell_candidates) {
        scope_resolution = best.scope_resolution.clone();
        conflicts.extend(collect_conflicts(&shell_candidates, best));
        return build_result(
            input,
            &best,
            signal_ages_ms,
            candidate_targets,
            conflicts,
            scope_resolution,
        );
    }

    candidate_targets.extend(
        stale_shell_candidates
            .iter()
            .map(|candidate| candidate.target.clone()),
    );
    if let Some(best) = pick_best_candidate(&stale_shell_candidates) {
        scope_resolution = best.scope_resolution.clone();
        conflicts.extend(collect_conflicts(&stale_shell_candidates, best));
        return build_result(
            input,
            &best,
            signal_ages_ms,
            candidate_targets,
            conflicts,
            scope_resolution,
        );
    }

    RoutingDiagnostics {
        snapshot: RoutingSnapshot {
            version: 1,
            workspace_id: input.workspace_id.to_string(),
            project_path: input.project_path.to_string(),
            status: RoutingStatus::Unavailable,
            target: RoutingTarget {
                kind: RoutingTargetKind::None,
                value: None,
            },
            confidence: RoutingConfidence::Low,
            reason_code: "NO_TRUSTED_EVIDENCE".to_string(),
            reason: "No trusted routing evidence available".to_string(),
            evidence: Vec::new(),
            updated_at: input.now.to_rfc3339(),
        },
        signal_ages_ms,
        candidate_targets,
        conflicts,
        scope_resolution,
    }
}

#[derive(Debug, Clone)]
struct ResolvedCandidate {
    target: RoutingTarget,
    status: RoutingStatus,
    confidence: RoutingConfidence,
    reason_code: &'static str,
    reason: String,
    evidence: Vec<RoutingEvidence>,
    trust_rank: u8,
    scope_quality: u8,
    age_ms: u64,
    scope_resolution: String,
    session_name_fallback: bool,
}

fn build_result(
    input: ResolveInput<'_>,
    best: &ResolvedCandidate,
    signal_ages_ms: HashMap<String, u64>,
    candidate_targets: Vec<RoutingTarget>,
    mut conflicts: Vec<String>,
    mut scope_resolution: String,
) -> RoutingDiagnostics {
    if !conflicts.is_empty() {
        scope_resolution = "workspace_ambiguous".to_string();
        if !conflicts
            .iter()
            .any(|entry| entry.contains("ROUTING_SCOPE_AMBIGUOUS"))
        {
            conflicts.push("ROUTING_SCOPE_AMBIGUOUS".to_string());
        }
    }
    RoutingDiagnostics {
        snapshot: RoutingSnapshot {
            version: 1,
            workspace_id: input.workspace_id.to_string(),
            project_path: input.project_path.to_string(),
            status: best.status,
            target: best.target.clone(),
            confidence: best.confidence,
            reason_code: best.reason_code.to_string(),
            reason: best.reason.clone(),
            evidence: best.evidence.clone(),
            updated_at: input.now.to_rfc3339(),
        },
        signal_ages_ms,
        candidate_targets,
        conflicts,
        scope_resolution,
    }
}

fn collect_conflicts(candidates: &[ResolvedCandidate], best: &ResolvedCandidate) -> Vec<String> {
    let tied = candidates
        .iter()
        .filter(|candidate| {
            candidate.scope_quality == best.scope_quality
                && candidate.trust_rank == best.trust_rank
                && candidate.age_ms == best.age_ms
                && candidate.target != best.target
        })
        .count();
    if tied == 0 {
        Vec::new()
    } else {
        vec!["ROUTING_CONFLICT_DETECTED".to_string()]
    }
}

fn pick_best_candidate(candidates: &[ResolvedCandidate]) -> Option<&ResolvedCandidate> {
    candidates.iter().max_by(|left, right| {
        left.scope_quality
            .cmp(&right.scope_quality)
            .then_with(|| right.trust_rank.cmp(&left.trust_rank))
            .then_with(|| right.age_ms.cmp(&left.age_ms))
            .then_with(|| {
                let left_value = left.target.value.as_deref().unwrap_or("");
                let right_value = right.target.value.as_deref().unwrap_or("");
                right_value.cmp(left_value)
            })
    })
}

fn candidate_scope_quality(
    config: &RoutingConfig,
    workspace_id: &str,
    project_path: &str,
    session_name: Option<&str>,
    candidate_path: Option<&str>,
) -> (u8, String) {
    if let Some(binding) = config.workspace_bindings.get(workspace_id) {
        if let Some(session_name) = session_name {
            if binding
                .preferred_sessions
                .iter()
                .any(|value| value == session_name)
            {
                return (4, "workspace_binding_exact".to_string());
            }
        }
        if let Some(path) = candidate_path {
            if binding.path_patterns.iter().any(|pattern| {
                pattern_matches(pattern, project_path) && pattern_matches(pattern, path)
            }) {
                return (3, "workspace_binding_pattern".to_string());
            }
        }
    }

    if let Some(path) = candidate_path {
        let normalized_candidate = normalize_path(path);
        let normalized_project = normalize_path(project_path);
        if normalized_candidate == normalized_project {
            return (3, "path_exact".to_string());
        }
        if normalized_candidate.starts_with(&(normalized_project.clone() + "/"))
            || normalized_project.starts_with(&(normalized_candidate + "/"))
        {
            return (2, "path_parent".to_string());
        }
    }

    (1, "global_fallback".to_string())
}

fn normalize_path(value: &str) -> String {
    if value == "/" {
        "/".to_string()
    } else {
        value.trim_end_matches('/').to_string()
    }
}

fn pattern_matches(pattern: &str, path: &str) -> bool {
    if let Some(prefix) = pattern.strip_suffix("/**") {
        let normalized_prefix = normalize_path(prefix);
        let normalized_path = normalize_path(path);
        normalized_path == normalized_prefix
            || normalized_path.starts_with(&(normalized_prefix + "/"))
    } else {
        normalize_path(pattern) == normalize_path(path)
    }
}

fn sanitize_parent_app(value: Option<&str>) -> Option<&str> {
    value.and_then(|candidate| {
        let normalized = candidate.trim();
        if normalized.is_empty() || normalized.eq_ignore_ascii_case("unknown") {
            None
        } else {
            Some(normalized)
        }
    })
}

fn shell_path_is_within_project(project_path: &str, shell_cwd: &str) -> bool {
    let normalized_project = normalize_path(project_path);
    let normalized_shell = normalize_path(shell_cwd);
    normalized_shell == normalized_project
        || normalized_shell.starts_with(&(normalized_project + "/"))
}

fn session_name_matches_project(project_path: &str, session_name: &str) -> bool {
    let normalized_project = normalize_path(project_path);
    let project_name = normalized_project
        .rsplit('/')
        .next()
        .unwrap_or(normalized_project.as_str());
    let normalized_session = normalize_path(session_name);
    !project_name.is_empty() && normalized_session == project_name
}

fn age_ms(now: DateTime<Utc>, observed_at: DateTime<Utc>) -> u64 {
    now.signed_duration_since(observed_at)
        .num_milliseconds()
        .max(0) as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::are::registry::{
        ShellSignal, TmuxClientSignal, TmuxSessionSignal, WorkspaceBinding,
    };
    use crate::are::state::RoutingConfig;
    use chrono::Duration;

    fn test_now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-02-14T15:00:00Z")
            .expect("parse")
            .with_timezone(&Utc)
    }

    #[test]
    fn resolver_prefers_workspace_binding_preferred_session_over_other_candidates() {
        let now = test_now();
        let mut config = RoutingConfig::default();
        config.workspace_bindings.upsert(
            "workspace-1",
            WorkspaceBinding {
                preferred_sessions: vec!["zeta".to_string()],
                path_patterns: vec![],
            },
        );

        let tmux_registry = TmuxRegistry {
            clients: vec![
                TmuxClientSignal {
                    client_tty: "/dev/ttys010".to_string(),
                    session_name: "alpha".to_string(),
                    pane_current_path: Some("/Users/petepetrash/Code/capacitor".to_string()),
                    captured_at: now - Duration::milliseconds(250),
                },
                TmuxClientSignal {
                    client_tty: "/dev/ttys011".to_string(),
                    session_name: "zeta".to_string(),
                    pane_current_path: Some("/Users/petepetrash/Code/capacitor".to_string()),
                    captured_at: now - Duration::milliseconds(250),
                },
            ],
            sessions: vec![],
        };

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/capacitor",
            workspace_id: "workspace-1",
            now,
            config: &config,
            shell_registry: &ShellRegistry::default(),
            tmux_registry: &tmux_registry,
        });

        assert_eq!(diagnostics.snapshot.status, RoutingStatus::Attached);
        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("zeta".to_string())
            }
        );
    }

    #[test]
    fn resolver_prefers_tmux_signal_over_shell_fallback() {
        let now = test_now();
        let config = RoutingConfig::default();
        let mut shell_registry = ShellRegistry::default();
        shell_registry.upsert(ShellSignal {
            pid: 11,
            proc_start: Some(100),
            cwd: "/Users/petepetrash/Code/capacitor".to_string(),
            tty: "/dev/ttys020".to_string(),
            parent_app: Some("terminal".to_string()),
            tmux_session: None,
            tmux_client_tty: None,
            tmux_pane: None,
            recorded_at: now - Duration::seconds(1),
        });
        let tmux_registry = TmuxRegistry {
            clients: vec![TmuxClientSignal {
                client_tty: "/dev/ttys030".to_string(),
                session_name: "cap-main".to_string(),
                pane_current_path: Some("/Users/petepetrash/Code/capacitor".to_string()),
                captured_at: now - Duration::milliseconds(400),
            }],
            sessions: vec![],
        };

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/capacitor",
            workspace_id: "workspace-2",
            now,
            config: &config,
            shell_registry: &shell_registry,
            tmux_registry: &tmux_registry,
        });

        assert_eq!(diagnostics.snapshot.status, RoutingStatus::Attached);
        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("cap-main".to_string())
            }
        );
    }

    #[test]
    fn resolver_uses_lexicographic_tiebreak_for_equal_candidates() {
        let now = test_now();
        let config = RoutingConfig::default();
        let tmux_registry = TmuxRegistry {
            clients: vec![
                TmuxClientSignal {
                    client_tty: "/dev/ttys100".to_string(),
                    session_name: "zeta".to_string(),
                    pane_current_path: Some("/Users/petepetrash/Code/capacitor".to_string()),
                    captured_at: now - Duration::milliseconds(300),
                },
                TmuxClientSignal {
                    client_tty: "/dev/ttys101".to_string(),
                    session_name: "alpha".to_string(),
                    pane_current_path: Some("/Users/petepetrash/Code/capacitor".to_string()),
                    captured_at: now - Duration::milliseconds(300),
                },
            ],
            sessions: vec![],
        };

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/capacitor",
            workspace_id: "workspace-3",
            now,
            config: &config,
            shell_registry: &ShellRegistry::default(),
            tmux_registry: &tmux_registry,
        });

        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("alpha".to_string())
            }
        );
    }

    #[test]
    fn resolver_does_not_apply_tmux_session_from_parent_directory() {
        let now = test_now();
        let config = RoutingConfig::default();
        let tmux_registry = TmuxRegistry {
            clients: vec![],
            sessions: vec![TmuxSessionSignal {
                session_name: "mac-mini".to_string(),
                pane_paths: vec!["/Users/petepetrash".to_string()],
                captured_at: now - Duration::milliseconds(300),
            }],
        };

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/agent-skills",
            workspace_id: "workspace-4a",
            now,
            config: &config,
            shell_registry: &ShellRegistry::default(),
            tmux_registry: &tmux_registry,
        });

        assert_eq!(diagnostics.snapshot.status, RoutingStatus::Unavailable);
        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::None,
                value: None,
            }
        );
        assert_eq!(diagnostics.snapshot.reason_code, "NO_TRUSTED_EVIDENCE");
    }

    #[test]
    fn resolver_prefers_tmux_session_with_project_name_match() {
        let now = test_now();
        let config = RoutingConfig::default();
        let tmux_registry = TmuxRegistry {
            clients: vec![],
            sessions: vec![
                TmuxSessionSignal {
                    session_name: "mac-mini".to_string(),
                    pane_paths: vec!["/Users/petepetrash".to_string()],
                    captured_at: now - Duration::milliseconds(300),
                },
                TmuxSessionSignal {
                    session_name: "agent-skills".to_string(),
                    pane_paths: vec!["/Users/petepetrash/Code/claude-code-setup".to_string()],
                    captured_at: now - Duration::milliseconds(500),
                },
            ],
        };

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/agent-skills",
            workspace_id: "workspace-4b",
            now,
            config: &config,
            shell_registry: &ShellRegistry::default(),
            tmux_registry: &tmux_registry,
        });

        assert_eq!(diagnostics.snapshot.status, RoutingStatus::Detached);
        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("agent-skills".to_string()),
            }
        );
        assert_eq!(diagnostics.snapshot.reason_code, "TMUX_SESSION_DETACHED");
    }

    #[test]
    fn resolver_does_not_use_stale_session_name_exact_fallback() {
        let now = test_now();
        let mut config = RoutingConfig::default();
        config.tmux_signal_fresh_ms = 1_000;
        let tmux_registry = TmuxRegistry {
            clients: vec![],
            sessions: vec![TmuxSessionSignal {
                session_name: "agent-skills".to_string(),
                pane_paths: vec!["/Users/petepetrash/Code/unrelated".to_string()],
                captured_at: now - Duration::seconds(5),
            }],
        };

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/agent-skills",
            workspace_id: "workspace-4c",
            now,
            config: &config,
            shell_registry: &ShellRegistry::default(),
            tmux_registry: &tmux_registry,
        });

        assert_eq!(diagnostics.snapshot.status, RoutingStatus::Unavailable);
        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::None,
                value: None,
            }
        );
        assert_eq!(diagnostics.snapshot.reason_code, "NO_TRUSTED_EVIDENCE");
    }

    #[test]
    fn resolver_prefers_project_path_scoped_tmux_session_over_session_name_fallback() {
        let now = test_now();
        let config = RoutingConfig::default();
        let tmux_registry = TmuxRegistry {
            clients: vec![],
            sessions: vec![
                TmuxSessionSignal {
                    session_name: "agent-skills".to_string(),
                    pane_paths: vec!["/Users/petepetrash/Code/unrelated".to_string()],
                    captured_at: now - Duration::milliseconds(100),
                },
                TmuxSessionSignal {
                    session_name: "zzz-project-context".to_string(),
                    pane_paths: vec!["/Users/petepetrash/Code/agent-skills".to_string()],
                    captured_at: now - Duration::milliseconds(500),
                },
            ],
        };

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/agent-skills",
            workspace_id: "workspace-4d",
            now,
            config: &config,
            shell_registry: &ShellRegistry::default(),
            tmux_registry: &tmux_registry,
        });

        assert_eq!(diagnostics.snapshot.status, RoutingStatus::Detached);
        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("zzz-project-context".to_string()),
            }
        );
        assert_eq!(diagnostics.snapshot.reason_code, "TMUX_SESSION_DETACHED");
    }

    #[test]
    fn resolver_ambiguity_is_stable_across_repeated_runs() {
        let now = test_now();
        let config = RoutingConfig::default();
        let tmux_registry = TmuxRegistry {
            clients: vec![
                TmuxClientSignal {
                    client_tty: "/dev/ttys100".to_string(),
                    session_name: "zeta".to_string(),
                    pane_current_path: Some("/Users/petepetrash/Code/capacitor".to_string()),
                    captured_at: now - Duration::milliseconds(300),
                },
                TmuxClientSignal {
                    client_tty: "/dev/ttys101".to_string(),
                    session_name: "alpha".to_string(),
                    pane_current_path: Some("/Users/petepetrash/Code/capacitor".to_string()),
                    captured_at: now - Duration::milliseconds(300),
                },
            ],
            sessions: vec![],
        };

        for _ in 0..20 {
            let diagnostics = resolve(ResolveInput {
                project_path: "/Users/petepetrash/Code/capacitor",
                workspace_id: "workspace-7",
                now,
                config: &config,
                shell_registry: &ShellRegistry::default(),
                tmux_registry: &tmux_registry,
            });

            assert_eq!(diagnostics.snapshot.status, RoutingStatus::Attached);
            assert_eq!(
                diagnostics.snapshot.target,
                RoutingTarget {
                    kind: RoutingTargetKind::TmuxSession,
                    value: Some("alpha".to_string()),
                }
            );
            assert_eq!(diagnostics.scope_resolution, "workspace_ambiguous");
            assert!(diagnostics
                .conflicts
                .iter()
                .any(|value| value == "ROUTING_CONFLICT_DETECTED"));
            assert!(diagnostics
                .conflicts
                .iter()
                .any(|value| value == "ROUTING_SCOPE_AMBIGUOUS"));
        }
    }

    #[test]
    fn resolver_treats_trailing_slash_paths_as_exact_match() {
        let now = test_now();
        let config = RoutingConfig::default();
        let tmux_registry = TmuxRegistry {
            clients: vec![],
            sessions: vec![TmuxSessionSignal {
                session_name: "caps".to_string(),
                pane_paths: vec!["/Users/petepetrash/Code/capacitor/".to_string()],
                captured_at: now - Duration::milliseconds(300),
            }],
        };

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/capacitor",
            workspace_id: "workspace-8",
            now,
            config: &config,
            shell_registry: &ShellRegistry::default(),
            tmux_registry: &tmux_registry,
        });

        assert_eq!(diagnostics.snapshot.status, RoutingStatus::Detached);
        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                value: Some("caps".to_string()),
            }
        );
        assert_eq!(diagnostics.scope_resolution, "path_exact");
    }

    #[test]
    fn resolver_does_not_assume_case_or_symlink_path_equivalence() {
        let now = test_now();
        let config = RoutingConfig::default();

        let case_variant_registry = TmuxRegistry {
            clients: vec![],
            sessions: vec![TmuxSessionSignal {
                session_name: "caps-case".to_string(),
                pane_paths: vec!["/Users/petepetrash/Code/CAPACITOR".to_string()],
                captured_at: now - Duration::milliseconds(300),
            }],
        };

        let case_variant = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/capacitor",
            workspace_id: "workspace-9a",
            now,
            config: &config,
            shell_registry: &ShellRegistry::default(),
            tmux_registry: &case_variant_registry,
        });

        assert_eq!(case_variant.snapshot.status, RoutingStatus::Unavailable);
        assert_eq!(case_variant.snapshot.reason_code, "NO_TRUSTED_EVIDENCE");

        let symlink_like_registry = TmuxRegistry {
            clients: vec![],
            sessions: vec![TmuxSessionSignal {
                session_name: "caps-symlink".to_string(),
                pane_paths: vec!["/tmp/capacitor".to_string()],
                captured_at: now - Duration::milliseconds(300),
            }],
        };

        let symlink_like = resolve(ResolveInput {
            project_path: "/private/tmp/capacitor",
            workspace_id: "workspace-9b",
            now,
            config: &config,
            shell_registry: &ShellRegistry::default(),
            tmux_registry: &symlink_like_registry,
        });

        assert_eq!(symlink_like.snapshot.status, RoutingStatus::Unavailable);
        assert_eq!(symlink_like.snapshot.reason_code, "NO_TRUSTED_EVIDENCE");
    }

    #[test]
    fn resolver_does_not_apply_shell_fallback_from_unrelated_project_path() {
        let now = test_now();
        let config = RoutingConfig::default();
        let mut shell_registry = ShellRegistry::default();
        shell_registry.upsert(ShellSignal {
            pid: 42,
            proc_start: Some(200),
            cwd: "/Users/petepetrash/Code/plink".to_string(),
            tty: "/dev/ttys040".to_string(),
            parent_app: Some("ghostty".to_string()),
            tmux_session: None,
            tmux_client_tty: None,
            tmux_pane: None,
            recorded_at: now - Duration::milliseconds(500),
        });

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/capacitor",
            workspace_id: "workspace-4",
            now,
            config: &config,
            shell_registry: &shell_registry,
            tmux_registry: &TmuxRegistry::default(),
        });

        assert_eq!(diagnostics.snapshot.status, RoutingStatus::Unavailable);
        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::None,
                value: None,
            }
        );
        assert_eq!(diagnostics.snapshot.reason_code, "NO_TRUSTED_EVIDENCE");
    }

    #[test]
    fn resolver_does_not_apply_shell_fallback_from_parent_directory() {
        let now = test_now();
        let config = RoutingConfig::default();
        let mut shell_registry = ShellRegistry::default();
        shell_registry.upsert(ShellSignal {
            pid: 43,
            proc_start: Some(201),
            cwd: "/Users/petepetrash".to_string(),
            tty: "/dev/ttys041".to_string(),
            parent_app: Some("vscode".to_string()),
            tmux_session: None,
            tmux_client_tty: None,
            tmux_pane: None,
            recorded_at: now - Duration::milliseconds(500),
        });

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/agent-skills",
            workspace_id: "workspace-5",
            now,
            config: &config,
            shell_registry: &shell_registry,
            tmux_registry: &TmuxRegistry::default(),
        });

        assert_eq!(diagnostics.snapshot.status, RoutingStatus::Unavailable);
        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::None,
                value: None,
            }
        );
        assert_eq!(diagnostics.snapshot.reason_code, "NO_TRUSTED_EVIDENCE");
    }

    #[test]
    fn resolver_applies_shell_fallback_for_child_directory_of_project() {
        let now = test_now();
        let config = RoutingConfig::default();
        let mut shell_registry = ShellRegistry::default();
        shell_registry.upsert(ShellSignal {
            pid: 44,
            proc_start: Some(202),
            cwd: "/Users/petepetrash/Code/capacitor/apps/swift".to_string(),
            tty: "/dev/ttys042".to_string(),
            parent_app: Some("ghostty".to_string()),
            tmux_session: None,
            tmux_client_tty: None,
            tmux_pane: None,
            recorded_at: now - Duration::milliseconds(500),
        });

        let diagnostics = resolve(ResolveInput {
            project_path: "/Users/petepetrash/Code/capacitor",
            workspace_id: "workspace-6",
            now,
            config: &config,
            shell_registry: &shell_registry,
            tmux_registry: &TmuxRegistry::default(),
        });

        assert_eq!(diagnostics.snapshot.status, RoutingStatus::Detached);
        assert_eq!(
            diagnostics.snapshot.target,
            RoutingTarget {
                kind: RoutingTargetKind::TerminalApp,
                value: Some("ghostty".to_string()),
            }
        );
        assert_eq!(diagnostics.snapshot.reason_code, "SHELL_FALLBACK_ACTIVE");
    }
}
