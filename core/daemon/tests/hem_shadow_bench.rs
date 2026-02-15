use capacitor_daemon_protocol::{
    EventEnvelope, EventType, Method, Request, Response, PROTOCOL_VERSION,
};
use chrono::{Duration as ChronoDuration, SecondsFormat, Utc};
use serde::Serialize;
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering as AtomicOrdering},
    Arc, Mutex,
};
use std::thread;
use std::thread::sleep;
use std::time::{Duration, Instant};

struct DaemonGuard {
    child: Child,
}

impl DaemonGuard {
    fn spawn(home: &Path) -> Self {
        let child = Command::new(env!("CARGO_BIN_EXE_capacitor-daemon"))
            .env("HOME", home)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("Failed to spawn capacitor-daemon");
        Self { child }
    }

    fn pid(&self) -> u32 {
        self.child.id()
    }
}

impl Drop for DaemonGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Debug, Clone, Serialize)]
struct LatencyStats {
    count: usize,
    min_ms: f64,
    mean_ms: f64,
    p50_ms: f64,
    p95_ms: f64,
    p99_ms: f64,
    max_ms: f64,
}

#[derive(Debug, Clone, Serialize)]
struct ScenarioMetrics {
    shadow_enabled: bool,
    burst_events: usize,
    burst_sessions: usize,
    replay_sessions: usize,
    burst_latency: LatencyStats,
    replay_startup_ms: f64,
    replay_get_project_states_ms: f64,
    peak_rss_kb: u64,
    peak_cpu_pct: f64,
    daemon_db_bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    hem_shadow_health: Option<HemShadowHealthSnapshot>,
}

#[derive(Debug, Clone, Serialize)]
struct HemShadowHealthSnapshot {
    enabled: bool,
    mode: String,
    events_evaluated: u64,
    projects_evaluated: u64,
    gate_blocking_mismatches: u64,
    gate_critical_mismatches: u64,
    gate_important_mismatches: u64,
    blocking_mismatch_rate: f64,
    stable_state_samples: u64,
    stable_state_matches: u64,
    stable_state_agreement_rate: f64,
    stable_state_agreement_gate_target: f64,
    stable_state_agreement_gate_met: bool,
}

#[derive(Debug, Clone, Serialize)]
struct OverheadSummary {
    burst_mean_delta_ms: f64,
    burst_p95_delta_ms: f64,
    burst_p99_delta_ms: f64,
    burst_mean_delta_pct: f64,
    burst_p95_delta_pct: f64,
    burst_p99_delta_pct: f64,
    replay_startup_delta_ms: f64,
    replay_startup_delta_pct: f64,
    rss_delta_kb: i64,
    rss_delta_pct: f64,
    cpu_delta_pct: f64,
    daemon_db_delta_bytes: i64,
    daemon_db_delta_pct: f64,
}

#[derive(Debug, Clone, Serialize)]
struct AcceptanceThresholds {
    max_shadow_burst_p95_ms: f64,
    max_shadow_burst_p99_ms: f64,
    max_burst_p95_delta_pct: f64,
    max_burst_p99_delta_pct: f64,
    max_replay_startup_delta_pct: f64,
    min_burst_p95_delta_ms_for_pct_gate: f64,
    min_burst_p99_delta_ms_for_pct_gate: f64,
    min_replay_startup_delta_ms_for_pct_gate: f64,
    min_burst_p95_baseline_ms_for_pct_gate: f64,
    min_burst_p99_baseline_ms_for_pct_gate: f64,
    min_replay_startup_baseline_ms_for_pct_gate: f64,
    max_rss_delta_pct: f64,
    max_cpu_delta_pct: f64,
    max_daemon_db_delta_pct: f64,
}

#[derive(Debug, Clone, Serialize)]
struct AcceptanceEvaluation {
    passed: bool,
    failures: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct BenchReport {
    generated_at: String,
    baseline: ScenarioMetrics,
    shadow: ScenarioMetrics,
    overhead: OverheadSummary,
    thresholds: AcceptanceThresholds,
    acceptance: AcceptanceEvaluation,
}

const BENCH_REPORT_PATH_ENV: &str = "CAPACITOR_BENCH_REPORT_PATH";

fn socket_path(home: &Path) -> PathBuf {
    home.join(".capacitor").join("daemon.sock")
}

fn can_bind_socket(home: &Path) -> bool {
    let probe_path = home.join("probe.sock");
    match UnixListener::bind(&probe_path) {
        Ok(listener) => {
            drop(listener);
            let _ = fs::remove_file(&probe_path);
            true
        }
        Err(err) if err.kind() == std::io::ErrorKind::PermissionDenied => false,
        Err(_) => true,
    }
}

fn write_hem_config(home: &Path, shadow_enabled: bool) {
    let daemon_dir = home.join(".capacitor").join("daemon");
    fs::create_dir_all(&daemon_dir).expect("create daemon config dir");
    let config = format!(
        r#"[engine]
enabled = {enabled}
mode = "shadow"
"#,
        enabled = if shadow_enabled { "true" } else { "false" }
    );
    fs::write(daemon_dir.join("hem-v2.toml"), config).expect("write hem-v2.toml");
}

fn read_response(stream: &mut UnixStream) -> Result<Response, String> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = stream
            .read(&mut chunk)
            .map_err(|err| format!("Failed to read response: {}", err))?;
        if n == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..n]);
        if chunk[..n].contains(&b'\n') {
            break;
        }
    }

    let response_bytes = match buffer.iter().position(|byte| *byte == b'\n') {
        Some(index) => &buffer[..index],
        None => buffer.as_slice(),
    };
    serde_json::from_slice(response_bytes)
        .map_err(|err| format!("Failed to parse response JSON: {}", err))
}

fn try_send_request(socket: &Path, request: &Request) -> Result<(Response, Duration), String> {
    let started = Instant::now();
    let mut stream =
        UnixStream::connect(socket).map_err(|err| format!("Failed to connect socket: {}", err))?;
    serde_json::to_writer(&mut stream, request)
        .map_err(|err| format!("Failed to serialize request: {}", err))?;
    stream
        .write_all(b"\n")
        .map_err(|err| format!("Failed to write request newline: {}", err))?;
    stream
        .flush()
        .map_err(|err| format!("Failed to flush request: {}", err))?;
    let response = read_response(&mut stream)?;
    Ok((response, started.elapsed()))
}

fn wait_for_daemon_ready(socket: &Path, timeout: Duration) -> Duration {
    let started = Instant::now();
    let deadline = started + timeout;
    while Instant::now() < deadline {
        let request = Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetHealth,
            id: Some("health-check".to_string()),
            params: None,
        };
        if let Ok((response, _)) = try_send_request(socket, &request) {
            if response.ok {
                return started.elapsed();
            }
        }
        sleep(Duration::from_millis(25));
    }
    panic!(
        "Timed out waiting for daemon readiness at {}",
        socket.display()
    );
}

fn build_event(
    event_id: &str,
    recorded_at: &str,
    event_type: EventType,
    session_id: &str,
    cwd: &str,
) -> EventEnvelope {
    EventEnvelope {
        event_id: event_id.to_string(),
        recorded_at: recorded_at.to_string(),
        event_type,
        session_id: Some(session_id.to_string()),
        pid: Some(std::process::id()),
        cwd: Some(cwd.to_string()),
        tool: Some("Edit".to_string()),
        file_path: Some("src/main.rs".to_string()),
        parent_app: None,
        tty: None,
        tmux_session: None,
        tmux_client_tty: None,
        notification_type: None,
        stop_hook_active: None,
        metadata: None,
    }
}

fn send_event(socket: &Path, event: EventEnvelope) -> Duration {
    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::Event,
        id: Some(event.event_id.clone()),
        params: Some(serde_json::to_value(event).expect("serialize event")),
    };
    let (response, elapsed) = try_send_request(socket, &request).expect("send event request");
    assert!(response.ok, "daemon rejected event: {:?}", response.error);
    elapsed
}

fn run_burst_event_storm(
    socket: &Path,
    cwd_root: &Path,
    event_count: usize,
    session_count: usize,
) -> LatencyStats {
    let base_time = Utc::now() - ChronoDuration::seconds(event_count as i64 + 60);
    let mut samples = Vec::with_capacity(event_count);
    for idx in 0..event_count {
        let session_idx = idx % session_count.max(1);
        let session_id = format!("burst-session-{}", session_idx);
        let cwd = cwd_root
            .join("workspace")
            .join(format!("repo-{}", session_idx % 16))
            .to_string_lossy()
            .to_string();
        let event_type = match idx % 5 {
            0 => EventType::SessionStart,
            1 => EventType::UserPromptSubmit,
            2 => EventType::PreToolUse,
            3 => EventType::PostToolUse,
            _ => EventType::TaskCompleted,
        };
        let recorded_at = (base_time + ChronoDuration::milliseconds(idx as i64))
            .to_rfc3339_opts(SecondsFormat::Secs, true);
        let event = build_event(
            &format!("evt-burst-{}", idx),
            &recorded_at,
            event_type,
            &session_id,
            &cwd,
        );
        samples.push(send_event(socket, event));
    }

    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::GetProjectStates,
        id: Some("project-snapshot".to_string()),
        params: None,
    };
    let (response, _) = try_send_request(socket, &request).expect("get project states");
    assert!(response.ok, "project snapshot failed: {:?}", response.error);
    latency_stats(&samples)
}

fn preload_replay_trace(socket: &Path, cwd_root: &Path, replay_sessions: usize) {
    let base_time = Utc::now() - ChronoDuration::hours(2);
    for idx in 0..replay_sessions {
        let session_id = format!("replay-session-{}", idx);
        let cwd = cwd_root
            .join("replay")
            .join(format!("repo-{}", idx % 32))
            .to_string_lossy()
            .to_string();
        let t0 = (base_time + ChronoDuration::seconds((idx * 4) as i64))
            .to_rfc3339_opts(SecondsFormat::Secs, true);
        let t1 = (base_time + ChronoDuration::seconds((idx * 4 + 1) as i64))
            .to_rfc3339_opts(SecondsFormat::Secs, true);
        let t2 = (base_time + ChronoDuration::seconds((idx * 4 + 2) as i64))
            .to_rfc3339_opts(SecondsFormat::Secs, true);
        let t3 = (base_time + ChronoDuration::seconds((idx * 4 + 3) as i64))
            .to_rfc3339_opts(SecondsFormat::Secs, true);

        send_event(
            socket,
            build_event(
                &format!("evt-replay-start-{}", idx),
                &t0,
                EventType::SessionStart,
                &session_id,
                &cwd,
            ),
        );
        send_event(
            socket,
            build_event(
                &format!("evt-replay-prompt-{}", idx),
                &t1,
                EventType::UserPromptSubmit,
                &session_id,
                &cwd,
            ),
        );
        send_event(
            socket,
            build_event(
                &format!("evt-replay-post-{}", idx),
                &t2,
                EventType::PostToolUse,
                &session_id,
                &cwd,
            ),
        );
        send_event(
            socket,
            build_event(
                &format!("evt-replay-end-{}", idx),
                &t3,
                EventType::SessionEnd,
                &session_id,
                &cwd,
            ),
        );
    }
}

fn emit_stable_state_probe(socket: &Path, cwd_root: &Path) {
    let session_id = "stable-probe-session";
    let cwd = cwd_root.join("stable-probe").to_string_lossy().to_string();
    let base = Utc::now() + ChronoDuration::seconds(60);
    let t0 = base.to_rfc3339_opts(SecondsFormat::Secs, true);
    let t1 = (base + ChronoDuration::seconds(1)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let t2 = (base + ChronoDuration::seconds(40)).to_rfc3339_opts(SecondsFormat::Secs, true);

    send_event(
        socket,
        build_event(
            "evt-stable-probe-start",
            &t0,
            EventType::SessionStart,
            session_id,
            &cwd,
        ),
    );
    send_event(
        socket,
        build_event(
            "evt-stable-probe-task",
            &t1,
            EventType::TaskCompleted,
            session_id,
            &cwd,
        ),
    );

    let mut shell_event = build_event(
        "evt-stable-probe-shell",
        &t2,
        EventType::ShellCwd,
        session_id,
        &cwd,
    );
    shell_event.pid = Some(std::process::id());
    shell_event.tty = Some("/dev/ttys-stable-probe".to_string());
    shell_event.tool = None;
    send_event(socket, shell_event);
}

fn run_scenario(
    shadow_enabled: bool,
    burst_events: usize,
    burst_sessions: usize,
    replay_sessions: usize,
) -> ScenarioMetrics {
    let home = tempfile::Builder::new()
        .prefix(if shadow_enabled {
            "capacitor-shadow-on"
        } else {
            "capacitor-shadow-off"
        })
        .tempdir_in("/tmp")
        .expect("create temp HOME");
    write_hem_config(home.path(), shadow_enabled);
    let socket = socket_path(home.path());

    let daemon = DaemonGuard::spawn(home.path());
    let (sampler_stop, sampler_peaks, sampler_handle) = start_resource_sampler(daemon.pid());
    wait_for_daemon_ready(&socket, Duration::from_secs(10));
    let burst_latency = run_burst_event_storm(&socket, home.path(), burst_events, burst_sessions);

    preload_replay_trace(&socket, home.path(), replay_sessions);
    emit_stable_state_probe(&socket, home.path());
    let hem_shadow_health = read_hem_shadow_health(&socket);
    sampler_stop.store(true, AtomicOrdering::Relaxed);
    let _ = sampler_handle.join();
    let (peak_rss_kb, peak_cpu_pct) = *sampler_peaks.lock().expect("resource peaks");
    drop(daemon);

    let _daemon_restarted = DaemonGuard::spawn(home.path());
    let replay_startup = wait_for_daemon_ready(&socket, Duration::from_secs(10));
    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::GetProjectStates,
        id: Some("replay-project-states".to_string()),
        params: None,
    };
    let (response, replay_get_project_states) =
        try_send_request(&socket, &request).expect("replay project states");
    assert!(
        response.ok,
        "replay project states failed: {:?}",
        response.error
    );
    let daemon_db_bytes = daemon_db_total_bytes(home.path());

    ScenarioMetrics {
        shadow_enabled,
        burst_events,
        burst_sessions,
        replay_sessions,
        burst_latency,
        replay_startup_ms: duration_ms(replay_startup),
        replay_get_project_states_ms: duration_ms(replay_get_project_states),
        peak_rss_kb,
        peak_cpu_pct,
        daemon_db_bytes,
        hem_shadow_health,
    }
}

fn duration_ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

fn percentile_nearest_rank(sorted_ms: &[f64], percentile: f64) -> f64 {
    if sorted_ms.is_empty() {
        return 0.0;
    }
    let n = sorted_ms.len();
    let rank = (percentile * n as f64).ceil() as usize;
    let idx = rank.saturating_sub(1).min(n - 1);
    sorted_ms[idx]
}

fn latency_stats(samples: &[Duration]) -> LatencyStats {
    if samples.is_empty() {
        return LatencyStats {
            count: 0,
            min_ms: 0.0,
            mean_ms: 0.0,
            p50_ms: 0.0,
            p95_ms: 0.0,
            p99_ms: 0.0,
            max_ms: 0.0,
        };
    }

    let mut values = samples
        .iter()
        .map(|sample| duration_ms(*sample))
        .collect::<Vec<_>>();
    values.sort_by(|left, right| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal));
    let sum = values.iter().sum::<f64>();
    LatencyStats {
        count: values.len(),
        min_ms: *values.first().unwrap_or(&0.0),
        mean_ms: sum / values.len() as f64,
        p50_ms: percentile_nearest_rank(&values, 0.50),
        p95_ms: percentile_nearest_rank(&values, 0.95),
        p99_ms: percentile_nearest_rank(&values, 0.99),
        max_ms: *values.last().unwrap_or(&0.0),
    }
}

fn delta_pct(baseline: f64, shadow: f64) -> f64 {
    if baseline.abs() < f64::EPSILON {
        0.0
    } else {
        ((shadow - baseline) / baseline) * 100.0
    }
}

fn daemon_db_total_bytes(home: &Path) -> u64 {
    let daemon_dir = home.join(".capacitor").join("daemon");
    ["state.db", "state.db-wal", "state.db-shm"]
        .into_iter()
        .filter_map(|file| fs::metadata(daemon_dir.join(file)).ok())
        .map(|meta| meta.len())
        .sum()
}

fn read_hem_shadow_health(socket: &Path) -> Option<HemShadowHealthSnapshot> {
    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::GetHealth,
        id: Some("bench-health".to_string()),
        params: None,
    };
    let (response, _) = try_send_request(socket, &request).ok()?;
    if !response.ok {
        return None;
    }
    let hem_shadow = response
        .data
        .as_ref()
        .and_then(|data| data.get("hem_shadow"))
        .and_then(|value| value.as_object())?;

    Some(HemShadowHealthSnapshot {
        enabled: hem_shadow
            .get("enabled")
            .and_then(|value| value.as_bool())
            .unwrap_or(false),
        mode: hem_shadow
            .get("mode")
            .and_then(|value| value.as_str())
            .unwrap_or("unknown")
            .to_string(),
        events_evaluated: hem_shadow
            .get("events_evaluated")
            .and_then(|value| value.as_u64())
            .unwrap_or(0),
        projects_evaluated: hem_shadow
            .get("projects_evaluated")
            .and_then(|value| value.as_u64())
            .unwrap_or(0),
        gate_blocking_mismatches: hem_shadow
            .get("gate_blocking_mismatches")
            .and_then(|value| value.as_u64())
            .unwrap_or(0),
        gate_critical_mismatches: hem_shadow
            .get("gate_critical_mismatches")
            .and_then(|value| value.as_u64())
            .unwrap_or(0),
        gate_important_mismatches: hem_shadow
            .get("gate_important_mismatches")
            .and_then(|value| value.as_u64())
            .unwrap_or(0),
        blocking_mismatch_rate: hem_shadow
            .get("blocking_mismatch_rate")
            .and_then(|value| value.as_f64())
            .unwrap_or(0.0),
        stable_state_samples: hem_shadow
            .get("stable_state_samples")
            .and_then(|value| value.as_u64())
            .unwrap_or(0),
        stable_state_matches: hem_shadow
            .get("stable_state_matches")
            .and_then(|value| value.as_u64())
            .unwrap_or(0),
        stable_state_agreement_rate: hem_shadow
            .get("stable_state_agreement_rate")
            .and_then(|value| value.as_f64())
            .unwrap_or(0.0),
        stable_state_agreement_gate_target: hem_shadow
            .get("stable_state_agreement_gate_target")
            .and_then(|value| value.as_f64())
            .unwrap_or(0.995),
        stable_state_agreement_gate_met: hem_shadow
            .get("stable_state_agreement_gate_met")
            .and_then(|value| value.as_bool())
            .unwrap_or(false),
    })
}

fn parse_ps_metrics(pid: u32) -> Option<(u64, f64)> {
    let output = Command::new("ps")
        .arg("-o")
        .arg("rss=,%cpu=")
        .arg("-p")
        .arg(pid.to_string())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout
        .lines()
        .map(str::trim)
        .find(|candidate| !candidate.is_empty())?;
    let mut parts = line.split_whitespace();
    let rss_kb = parts.next()?.parse::<u64>().ok()?;
    let cpu_pct = parts.next()?.parse::<f64>().ok()?;
    Some((rss_kb, cpu_pct))
}

type SamplerPeaks = Arc<Mutex<(u64, f64)>>;
type ResourceSampler = (Arc<AtomicBool>, SamplerPeaks, thread::JoinHandle<()>);

fn start_resource_sampler(pid: u32) -> ResourceSampler {
    let stop = Arc::new(AtomicBool::new(false));
    let peaks = Arc::new(Mutex::new((0_u64, 0.0_f64)));
    let stop_flag = Arc::clone(&stop);
    let peak_values = Arc::clone(&peaks);
    let handle = thread::spawn(move || {
        while !stop_flag.load(AtomicOrdering::Relaxed) {
            if let Some((rss_kb, cpu_pct)) = parse_ps_metrics(pid) {
                let mut lock = peak_values.lock().expect("resource peak lock");
                if rss_kb > lock.0 {
                    lock.0 = rss_kb;
                }
                if cpu_pct > lock.1 {
                    lock.1 = cpu_pct;
                }
            }
            sleep(Duration::from_millis(50));
        }
    });
    (stop, peaks, handle)
}

fn parse_env_f64(key: &str, default: f64) -> f64 {
    env::var(key)
        .ok()
        .and_then(|raw| raw.parse::<f64>().ok())
        .filter(|value| value.is_finite() && *value > 0.0)
        .unwrap_or(default)
}

fn acceptance_thresholds_from_env() -> AcceptanceThresholds {
    AcceptanceThresholds {
        max_shadow_burst_p95_ms: parse_env_f64("CAPACITOR_BENCH_MAX_SHADOW_BURST_P95_MS", 50.0),
        max_shadow_burst_p99_ms: parse_env_f64("CAPACITOR_BENCH_MAX_SHADOW_BURST_P99_MS", 90.0),
        max_burst_p95_delta_pct: parse_env_f64("CAPACITOR_BENCH_MAX_BURST_P95_DELTA_PCT", 35.0),
        max_burst_p99_delta_pct: parse_env_f64("CAPACITOR_BENCH_MAX_BURST_P99_DELTA_PCT", 45.0),
        max_replay_startup_delta_pct: parse_env_f64(
            "CAPACITOR_BENCH_MAX_REPLAY_STARTUP_DELTA_PCT",
            40.0,
        ),
        min_burst_p95_delta_ms_for_pct_gate: parse_env_f64(
            "CAPACITOR_BENCH_MIN_BURST_P95_DELTA_MS_FOR_PCT_GATE",
            4.0,
        ),
        min_burst_p99_delta_ms_for_pct_gate: parse_env_f64(
            "CAPACITOR_BENCH_MIN_BURST_P99_DELTA_MS_FOR_PCT_GATE",
            5.0,
        ),
        min_replay_startup_delta_ms_for_pct_gate: parse_env_f64(
            "CAPACITOR_BENCH_MIN_REPLAY_STARTUP_DELTA_MS_FOR_PCT_GATE",
            5.0,
        ),
        min_burst_p95_baseline_ms_for_pct_gate: parse_env_f64(
            "CAPACITOR_BENCH_MIN_BURST_P95_BASELINE_MS_FOR_PCT_GATE",
            20.0,
        ),
        min_burst_p99_baseline_ms_for_pct_gate: parse_env_f64(
            "CAPACITOR_BENCH_MIN_BURST_P99_BASELINE_MS_FOR_PCT_GATE",
            25.0,
        ),
        min_replay_startup_baseline_ms_for_pct_gate: parse_env_f64(
            "CAPACITOR_BENCH_MIN_REPLAY_STARTUP_BASELINE_MS_FOR_PCT_GATE",
            25.0,
        ),
        max_rss_delta_pct: parse_env_f64("CAPACITOR_BENCH_MAX_RSS_DELTA_PCT", 35.0),
        max_cpu_delta_pct: parse_env_f64("CAPACITOR_BENCH_MAX_CPU_DELTA_PCT", 40.0),
        max_daemon_db_delta_pct: parse_env_f64("CAPACITOR_BENCH_MAX_DB_DELTA_PCT", 35.0),
    }
}

fn evaluate_acceptance(
    baseline: &ScenarioMetrics,
    shadow: &ScenarioMetrics,
    overhead: &OverheadSummary,
    thresholds: &AcceptanceThresholds,
) -> AcceptanceEvaluation {
    let mut failures = Vec::new();
    if shadow.burst_latency.p95_ms > thresholds.max_shadow_burst_p95_ms {
        failures.push(format!(
            "shadow burst p95 {:.2}ms exceeds {:.2}ms",
            shadow.burst_latency.p95_ms, thresholds.max_shadow_burst_p95_ms
        ));
    }
    if shadow.burst_latency.p99_ms > thresholds.max_shadow_burst_p99_ms {
        failures.push(format!(
            "shadow burst p99 {:.2}ms exceeds {:.2}ms",
            shadow.burst_latency.p99_ms, thresholds.max_shadow_burst_p99_ms
        ));
    }
    if baseline.burst_latency.p95_ms >= thresholds.min_burst_p95_baseline_ms_for_pct_gate
        && overhead.burst_p95_delta_ms > thresholds.min_burst_p95_delta_ms_for_pct_gate
        && overhead.burst_p95_delta_pct > thresholds.max_burst_p95_delta_pct
    {
        failures.push(format!(
            "burst p95 delta {:.2}% exceeds {:.2}% (delta {:.2}ms > {:.2}ms gate)",
            overhead.burst_p95_delta_pct,
            thresholds.max_burst_p95_delta_pct,
            overhead.burst_p95_delta_ms,
            thresholds.min_burst_p95_delta_ms_for_pct_gate
        ));
    }
    if baseline.burst_latency.p99_ms >= thresholds.min_burst_p99_baseline_ms_for_pct_gate
        && overhead.burst_p99_delta_ms > thresholds.min_burst_p99_delta_ms_for_pct_gate
        && overhead.burst_p99_delta_pct > thresholds.max_burst_p99_delta_pct
    {
        failures.push(format!(
            "burst p99 delta {:.2}% exceeds {:.2}% (delta {:.2}ms > {:.2}ms gate)",
            overhead.burst_p99_delta_pct,
            thresholds.max_burst_p99_delta_pct,
            overhead.burst_p99_delta_ms,
            thresholds.min_burst_p99_delta_ms_for_pct_gate
        ));
    }
    if baseline.replay_startup_ms >= thresholds.min_replay_startup_baseline_ms_for_pct_gate
        && overhead.replay_startup_delta_ms > thresholds.min_replay_startup_delta_ms_for_pct_gate
        && overhead.replay_startup_delta_pct > thresholds.max_replay_startup_delta_pct
    {
        failures.push(format!(
            "replay startup delta {:.2}% exceeds {:.2}% (delta {:.2}ms > {:.2}ms gate)",
            overhead.replay_startup_delta_pct,
            thresholds.max_replay_startup_delta_pct,
            overhead.replay_startup_delta_ms,
            thresholds.min_replay_startup_delta_ms_for_pct_gate
        ));
    }
    if overhead.rss_delta_pct > thresholds.max_rss_delta_pct {
        failures.push(format!(
            "RSS delta {:.2}% exceeds {:.2}%",
            overhead.rss_delta_pct, thresholds.max_rss_delta_pct
        ));
    }
    if overhead.cpu_delta_pct > thresholds.max_cpu_delta_pct {
        failures.push(format!(
            "CPU delta {:.2}% exceeds {:.2}%",
            overhead.cpu_delta_pct, thresholds.max_cpu_delta_pct
        ));
    }
    if overhead.daemon_db_delta_pct > thresholds.max_daemon_db_delta_pct {
        failures.push(format!(
            "daemon DB delta {:.2}% exceeds {:.2}%",
            overhead.daemon_db_delta_pct, thresholds.max_daemon_db_delta_pct
        ));
    }

    AcceptanceEvaluation {
        passed: failures.is_empty(),
        failures,
    }
}

fn parse_env_usize(key: &str, default: usize) -> usize {
    env::var(key)
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

fn write_bench_report_to_path(report: &BenchReport, report_path: &Path) -> Result<(), String> {
    if let Some(parent) = report_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("Failed to create bench report directory: {}", err))?;
    }
    let mut payload = serde_json::to_vec_pretty(report)
        .map_err(|err| format!("Failed to serialize bench report: {}", err))?;
    payload.push(b'\n');
    fs::write(report_path, payload).map_err(|err| {
        format!(
            "Failed to write bench report to {}: {}",
            report_path.display(),
            err
        )
    })
}

fn write_bench_report_if_requested(report: &BenchReport) -> Result<Option<PathBuf>, String> {
    let Some(raw_path) = env::var(BENCH_REPORT_PATH_ENV).ok() else {
        return Ok(None);
    };
    if raw_path.trim().is_empty() {
        return Ok(None);
    }
    let path = PathBuf::from(raw_path);
    write_bench_report_to_path(report, &path)?;
    Ok(Some(path))
}

#[test]
fn write_bench_report_to_path_persists_json_payload() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let report_path = temp_dir.path().join("reports").join("hem-shadow.json");
    let report = sample_bench_report();

    write_bench_report_to_path(&report, &report_path).expect("write bench report");

    let content = fs::read_to_string(&report_path).expect("read bench report");
    let parsed: serde_json::Value =
        serde_json::from_str(&content).expect("parse bench report JSON");
    assert_eq!(
        parsed
            .get("acceptance")
            .and_then(|value| value.get("passed"))
            .and_then(|value| value.as_bool()),
        Some(report.acceptance.passed)
    );
    assert_eq!(
        parsed
            .get("shadow")
            .and_then(|value| value.get("burst_latency"))
            .and_then(|value| value.get("p95_ms"))
            .and_then(|value| value.as_f64()),
        Some(report.shadow.burst_latency.p95_ms)
    );
}

fn sample_bench_report() -> BenchReport {
    BenchReport {
        generated_at: "2026-02-13T12:00:00Z".to_string(),
        baseline: ScenarioMetrics {
            shadow_enabled: false,
            burst_events: 100,
            burst_sessions: 10,
            replay_sessions: 10,
            burst_latency: LatencyStats {
                count: 100,
                min_ms: 1.0,
                mean_ms: 10.0,
                p50_ms: 9.0,
                p95_ms: 25.0,
                p99_ms: 30.0,
                max_ms: 35.0,
            },
            replay_startup_ms: 30.0,
            replay_get_project_states_ms: 5.0,
            peak_rss_kb: 10000,
            peak_cpu_pct: 4.0,
            daemon_db_bytes: 200_000,
            hem_shadow_health: Some(HemShadowHealthSnapshot {
                enabled: false,
                mode: "shadow".to_string(),
                events_evaluated: 0,
                projects_evaluated: 0,
                gate_blocking_mismatches: 0,
                gate_critical_mismatches: 0,
                gate_important_mismatches: 0,
                blocking_mismatch_rate: 0.0,
                stable_state_samples: 0,
                stable_state_matches: 0,
                stable_state_agreement_rate: 0.0,
                stable_state_agreement_gate_target: 0.995,
                stable_state_agreement_gate_met: false,
            }),
        },
        shadow: ScenarioMetrics {
            shadow_enabled: true,
            burst_events: 100,
            burst_sessions: 10,
            replay_sessions: 10,
            burst_latency: LatencyStats {
                count: 100,
                min_ms: 1.0,
                mean_ms: 11.0,
                p50_ms: 10.0,
                p95_ms: 30.0,
                p99_ms: 35.0,
                max_ms: 40.0,
            },
            replay_startup_ms: 35.0,
            replay_get_project_states_ms: 6.0,
            peak_rss_kb: 11_000,
            peak_cpu_pct: 5.0,
            daemon_db_bytes: 210_000,
            hem_shadow_health: Some(HemShadowHealthSnapshot {
                enabled: true,
                mode: "shadow".to_string(),
                events_evaluated: 100,
                projects_evaluated: 100,
                gate_blocking_mismatches: 0,
                gate_critical_mismatches: 0,
                gate_important_mismatches: 0,
                blocking_mismatch_rate: 0.0,
                stable_state_samples: 10,
                stable_state_matches: 10,
                stable_state_agreement_rate: 1.0,
                stable_state_agreement_gate_target: 0.995,
                stable_state_agreement_gate_met: true,
            }),
        },
        overhead: OverheadSummary {
            burst_mean_delta_ms: 1.0,
            burst_p95_delta_ms: 5.0,
            burst_p99_delta_ms: 5.0,
            burst_mean_delta_pct: 10.0,
            burst_p95_delta_pct: 20.0,
            burst_p99_delta_pct: 16.7,
            replay_startup_delta_ms: 5.0,
            replay_startup_delta_pct: 16.7,
            rss_delta_kb: 1000,
            rss_delta_pct: 10.0,
            cpu_delta_pct: 1.0,
            daemon_db_delta_bytes: 10_000,
            daemon_db_delta_pct: 5.0,
        },
        thresholds: AcceptanceThresholds {
            max_shadow_burst_p95_ms: 50.0,
            max_shadow_burst_p99_ms: 90.0,
            max_burst_p95_delta_pct: 35.0,
            max_burst_p99_delta_pct: 45.0,
            max_replay_startup_delta_pct: 40.0,
            min_burst_p95_delta_ms_for_pct_gate: 4.0,
            min_burst_p99_delta_ms_for_pct_gate: 5.0,
            min_replay_startup_delta_ms_for_pct_gate: 5.0,
            min_burst_p95_baseline_ms_for_pct_gate: 20.0,
            min_burst_p99_baseline_ms_for_pct_gate: 25.0,
            min_replay_startup_baseline_ms_for_pct_gate: 25.0,
            max_rss_delta_pct: 35.0,
            max_cpu_delta_pct: 40.0,
            max_daemon_db_delta_pct: 35.0,
        },
        acceptance: AcceptanceEvaluation {
            passed: true,
            failures: Vec::new(),
        },
    }
}

#[test]
fn latency_stats_uses_nearest_rank_percentiles() {
    let samples = vec![
        Duration::from_millis(1),
        Duration::from_millis(2),
        Duration::from_millis(3),
        Duration::from_millis(4),
        Duration::from_millis(5),
    ];
    let stats = latency_stats(&samples);
    assert_eq!(stats.count, 5);
    assert!((stats.min_ms - 1.0).abs() < f64::EPSILON);
    assert!((stats.mean_ms - 3.0).abs() < f64::EPSILON);
    assert!((stats.p50_ms - 3.0).abs() < f64::EPSILON);
    assert!((stats.p95_ms - 5.0).abs() < f64::EPSILON);
    assert!((stats.p99_ms - 5.0).abs() < f64::EPSILON);
    assert!((stats.max_ms - 5.0).abs() < f64::EPSILON);
}

#[test]
fn evaluate_acceptance_fails_when_p95_threshold_exceeded() {
    let thresholds = AcceptanceThresholds {
        max_shadow_burst_p95_ms: 40.0,
        max_shadow_burst_p99_ms: 80.0,
        max_burst_p95_delta_pct: 20.0,
        max_burst_p99_delta_pct: 30.0,
        max_replay_startup_delta_pct: 25.0,
        min_burst_p95_delta_ms_for_pct_gate: 0.5,
        min_burst_p99_delta_ms_for_pct_gate: 0.5,
        min_replay_startup_delta_ms_for_pct_gate: 0.5,
        min_burst_p95_baseline_ms_for_pct_gate: 1.0,
        min_burst_p99_baseline_ms_for_pct_gate: 1.0,
        min_replay_startup_baseline_ms_for_pct_gate: 1.0,
        max_rss_delta_pct: 20.0,
        max_cpu_delta_pct: 20.0,
        max_daemon_db_delta_pct: 20.0,
    };
    let baseline = ScenarioMetrics {
        shadow_enabled: false,
        burst_events: 100,
        burst_sessions: 10,
        replay_sessions: 10,
        burst_latency: LatencyStats {
            count: 100,
            min_ms: 1.0,
            mean_ms: 9.0,
            p50_ms: 8.0,
            p95_ms: 20.0,
            p99_ms: 24.0,
            max_ms: 30.0,
        },
        replay_startup_ms: 20.0,
        replay_get_project_states_ms: 2.0,
        peak_rss_kb: 900,
        peak_cpu_pct: 5.0,
        daemon_db_bytes: 1000,
        hem_shadow_health: None,
    };
    let shadow = ScenarioMetrics {
        shadow_enabled: true,
        burst_events: 100,
        burst_sessions: 10,
        replay_sessions: 10,
        burst_latency: LatencyStats {
            count: 100,
            min_ms: 1.0,
            mean_ms: 10.0,
            p50_ms: 9.0,
            p95_ms: 45.0,
            p99_ms: 70.0,
            max_ms: 90.0,
        },
        replay_startup_ms: 10.0,
        replay_get_project_states_ms: 2.0,
        peak_rss_kb: 1000,
        peak_cpu_pct: 5.0,
        daemon_db_bytes: 1024,
        hem_shadow_health: None,
    };
    let overhead = OverheadSummary {
        burst_mean_delta_ms: 0.0,
        burst_p95_delta_ms: 1.0,
        burst_p99_delta_ms: 1.0,
        burst_mean_delta_pct: 1.0,
        burst_p95_delta_pct: 2.0,
        burst_p99_delta_pct: 3.0,
        replay_startup_delta_ms: 1.0,
        replay_startup_delta_pct: 2.0,
        rss_delta_kb: 0,
        rss_delta_pct: 1.0,
        cpu_delta_pct: 0.5,
        daemon_db_delta_bytes: 20,
        daemon_db_delta_pct: 2.0,
    };

    let evaluation = evaluate_acceptance(&baseline, &shadow, &overhead, &thresholds);
    assert!(!evaluation.passed);
    assert!(evaluation
        .failures
        .iter()
        .any(|failure| failure.contains("shadow burst p95")));
}

#[test]
fn evaluate_acceptance_ignores_pct_delta_when_absolute_delta_below_noise_gate() {
    let thresholds = AcceptanceThresholds {
        max_shadow_burst_p95_ms: 50.0,
        max_shadow_burst_p99_ms: 90.0,
        max_burst_p95_delta_pct: 35.0,
        max_burst_p99_delta_pct: 45.0,
        max_replay_startup_delta_pct: 40.0,
        min_burst_p95_delta_ms_for_pct_gate: 4.0,
        min_burst_p99_delta_ms_for_pct_gate: 5.0,
        min_replay_startup_delta_ms_for_pct_gate: 5.0,
        min_burst_p95_baseline_ms_for_pct_gate: 20.0,
        min_burst_p99_baseline_ms_for_pct_gate: 25.0,
        min_replay_startup_baseline_ms_for_pct_gate: 25.0,
        max_rss_delta_pct: 35.0,
        max_cpu_delta_pct: 40.0,
        max_daemon_db_delta_pct: 35.0,
    };
    let baseline = ScenarioMetrics {
        shadow_enabled: false,
        burst_events: 120,
        burst_sessions: 8,
        replay_sessions: 40,
        burst_latency: LatencyStats {
            count: 120,
            min_ms: 1.0,
            mean_ms: 7.0,
            p50_ms: 6.0,
            p95_ms: 10.0,
            p99_ms: 12.0,
            max_ms: 13.0,
        },
        replay_startup_ms: 20.0,
        replay_get_project_states_ms: 3.0,
        peak_rss_kb: 10000,
        peak_cpu_pct: 3.0,
        daemon_db_bytes: 200_000,
        hem_shadow_health: None,
    };
    let shadow = ScenarioMetrics {
        shadow_enabled: true,
        burst_events: 120,
        burst_sessions: 8,
        replay_sessions: 40,
        burst_latency: LatencyStats {
            count: 120,
            min_ms: 1.0,
            mean_ms: 8.0,
            p50_ms: 7.0,
            p95_ms: 14.0,
            p99_ms: 15.0,
            max_ms: 16.0,
        },
        replay_startup_ms: 30.0,
        replay_get_project_states_ms: 4.0,
        peak_rss_kb: 10000,
        peak_cpu_pct: 3.0,
        daemon_db_bytes: 200_000,
        hem_shadow_health: None,
    };
    let overhead = OverheadSummary {
        burst_mean_delta_ms: 3.0,
        burst_p95_delta_ms: 3.6,
        burst_p99_delta_ms: 2.5,
        burst_mean_delta_pct: 58.0,
        burst_p95_delta_pct: 36.5,
        burst_p99_delta_pct: 21.4,
        replay_startup_delta_ms: 4.5,
        replay_startup_delta_pct: 17.4,
        rss_delta_kb: 0,
        rss_delta_pct: 0.0,
        cpu_delta_pct: 0.0,
        daemon_db_delta_bytes: 0,
        daemon_db_delta_pct: 0.0,
    };

    let evaluation = evaluate_acceptance(&baseline, &shadow, &overhead, &thresholds);
    assert!(
        evaluation.passed,
        "unexpected failures: {:?}",
        evaluation.failures
    );
}

#[test]
#[ignore = "benchmark harness for manual perf runs"]
fn hem_shadow_burst_and_replay_benchmark_harness() {
    let probe_home = tempfile::Builder::new()
        .prefix("capacitor-bench-probe")
        .tempdir_in("/tmp")
        .expect("probe temp home");
    if !can_bind_socket(probe_home.path()) {
        eprintln!(
            "Skipping benchmark harness: unix socket binding not permitted in this environment."
        );
        return;
    }

    let burst_events = parse_env_usize("CAPACITOR_BENCH_BURST_EVENTS", 1500);
    let burst_sessions = parse_env_usize("CAPACITOR_BENCH_BURST_SESSIONS", 32);
    let replay_sessions = parse_env_usize("CAPACITOR_BENCH_REPLAY_SESSIONS", 300);

    let baseline = run_scenario(false, burst_events, burst_sessions, replay_sessions);
    let shadow = run_scenario(true, burst_events, burst_sessions, replay_sessions);
    assert_eq!(baseline.burst_latency.count, burst_events);
    assert_eq!(shadow.burst_latency.count, burst_events);

    let overhead = OverheadSummary {
        burst_mean_delta_ms: shadow.burst_latency.mean_ms - baseline.burst_latency.mean_ms,
        burst_p95_delta_ms: shadow.burst_latency.p95_ms - baseline.burst_latency.p95_ms,
        burst_p99_delta_ms: shadow.burst_latency.p99_ms - baseline.burst_latency.p99_ms,
        burst_mean_delta_pct: delta_pct(
            baseline.burst_latency.mean_ms,
            shadow.burst_latency.mean_ms,
        ),
        burst_p95_delta_pct: delta_pct(baseline.burst_latency.p95_ms, shadow.burst_latency.p95_ms),
        burst_p99_delta_pct: delta_pct(baseline.burst_latency.p99_ms, shadow.burst_latency.p99_ms),
        replay_startup_delta_ms: shadow.replay_startup_ms - baseline.replay_startup_ms,
        replay_startup_delta_pct: delta_pct(baseline.replay_startup_ms, shadow.replay_startup_ms),
        rss_delta_kb: shadow.peak_rss_kb as i64 - baseline.peak_rss_kb as i64,
        rss_delta_pct: delta_pct(baseline.peak_rss_kb as f64, shadow.peak_rss_kb as f64),
        cpu_delta_pct: shadow.peak_cpu_pct - baseline.peak_cpu_pct,
        daemon_db_delta_bytes: shadow.daemon_db_bytes as i64 - baseline.daemon_db_bytes as i64,
        daemon_db_delta_pct: delta_pct(
            baseline.daemon_db_bytes as f64,
            shadow.daemon_db_bytes as f64,
        ),
    };
    let thresholds = acceptance_thresholds_from_env();
    let acceptance = evaluate_acceptance(&baseline, &shadow, &overhead, &thresholds);
    let report = BenchReport {
        generated_at: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
        baseline,
        shadow,
        overhead,
        thresholds,
        acceptance: acceptance.clone(),
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&report).expect("serialize bench report")
    );
    if let Some(report_path) = write_bench_report_if_requested(&report).expect("write bench report")
    {
        eprintln!(
            "HEM shadow benchmark report written to {}",
            report_path.display()
        );
    }
    assert!(
        acceptance.passed,
        "HEM shadow benchmark acceptance failed: {}",
        acceptance.failures.join("; ")
    );
}
