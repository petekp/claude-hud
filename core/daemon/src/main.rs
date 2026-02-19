//! Capacitor daemon entrypoint.
//!
//! This is a small, single-writer service that owns state updates for the app.
//! Phase 3 keeps it minimal: a socket listener, strict request validation, and
//! a SQLite-backed event log with a materialized shell state view.

use fs_err as fs;
use std::env;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

use capacitor_daemon_protocol::{
    parse_event, parse_process_liveness, parse_routing_diagnostics, parse_routing_snapshot,
    ErrorInfo, Method, Request, Response, ERROR_INVALID_PROJECT_PATH, ERROR_TOO_MANY_CONNECTIONS,
    ERROR_UNAUTHORIZED_PEER, MAX_REQUEST_BYTES, PROTOCOL_VERSION,
};
use serde_json::Value;

mod activity;
mod are;
mod backoff;
mod boundaries;
mod db;
mod hem;
mod process;
mod project_identity;
mod reducer;
mod replay;
mod session_store;
mod state;

use db::Db;
use state::SharedState;

const SOCKET_NAME: &str = "daemon.sock";
const READ_TIMEOUT_SECS: u64 = 2;
const READ_CHUNK_SIZE: usize = 4096;
const DEAD_SESSION_RECONCILE_INTERVAL_SECS: u64 = 15;
const MAX_ACTIVE_CONNECTIONS: usize = 64;

#[derive(Default)]
struct RuntimeStats {
    active_connections: AtomicUsize,
    rejected_connections: AtomicU64,
}

struct ConnectionGuard {
    stats: Arc<RuntimeStats>,
}

impl ConnectionGuard {
    fn try_acquire(stats: Arc<RuntimeStats>) -> Option<Self> {
        let previous = stats.active_connections.fetch_add(1, Ordering::SeqCst);
        if previous >= MAX_ACTIVE_CONNECTIONS {
            stats.active_connections.fetch_sub(1, Ordering::SeqCst);
            stats.rejected_connections.fetch_add(1, Ordering::SeqCst);
            return None;
        }
        Some(Self { stats })
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.stats.active_connections.fetch_sub(1, Ordering::SeqCst);
    }
}

fn main() {
    init_logging();

    if let Ok(path) = daemon_backoff_path() {
        backoff::apply_startup_backoff(&path);
    } else {
        warn!("Failed to resolve daemon backoff path");
    }

    let socket_path = match daemon_socket_path() {
        Ok(path) => path,
        Err(err) => {
            error!(error = %err, "Failed to resolve daemon socket path");
            std::process::exit(1);
        }
    };

    if let Err(err) = prepare_socket_dir(&socket_path) {
        error!(error = %err, "Failed to prepare daemon socket directory");
        std::process::exit(1);
    }

    if let Err(err) = remove_existing_socket(&socket_path) {
        error!(error = %err, path = %socket_path.display(), "Failed to remove existing socket");
        std::process::exit(1);
    }

    let listener = match UnixListener::bind(&socket_path) {
        Ok(listener) => listener,
        Err(err) => {
            error!(error = %err, path = %socket_path.display(), "Failed to bind daemon socket");
            std::process::exit(1);
        }
    };
    if let Err(err) = set_socket_permissions(&socket_path) {
        error!(error = %err, path = %socket_path.display(), "Failed to set daemon socket permissions");
        std::process::exit(1);
    }

    info!(path = %socket_path.display(), "Capacitor daemon started");

    let db_path = match daemon_db_path() {
        Ok(path) => path,
        Err(err) => {
            error!(error = %err, "Failed to resolve daemon database path");
            std::process::exit(1);
        }
    };

    let db = match Db::new(db_path) {
        Ok(db) => db,
        Err(err) => {
            error!(error = %err, "Failed to initialize daemon database");
            std::process::exit(1);
        }
    };

    let hem_config = match hem::load_runtime_config(None) {
        Ok(config) => config,
        Err(err) => {
            warn!(error = %err, "Failed to load HEM config; using safe defaults");
            hem::HemRuntimeConfig::default()
        }
    };
    let shared_state = Arc::new(SharedState::new_with_hem_config(db, hem_config.clone()));
    info!(
        hem_enabled = hem_config.engine.enabled,
        hem_mode = ?hem_config.engine.mode,
        provider = hem_config.provider.name,
        provider_version = hem_config.provider.version,
        routing_enabled = hem_config.routing.enabled,
        routing_dual_run = hem_config.routing.feature_flags.dual_run,
        routing_emit_diagnostics = hem_config.routing.feature_flags.emit_diagnostics,
        "HEM runtime config loaded"
    );
    spawn_dead_session_reconciler(Arc::clone(&shared_state));
    spawn_routing_tmux_poller(Arc::clone(&shared_state));
    let runtime = Arc::new(RuntimeStats::default());
    let expected_uid = unsafe { libc::geteuid() as u32 };

    for stream in listener.incoming() {
        match stream {
            Ok(mut stream) => {
                let Some(connection_guard) = ConnectionGuard::try_acquire(Arc::clone(&runtime))
                else {
                    let _ = write_response(
                        &mut stream,
                        Response::error(
                            None,
                            ERROR_TOO_MANY_CONNECTIONS,
                            "daemon connection limit reached",
                        ),
                    );
                    continue;
                };
                let state = Arc::clone(&shared_state);
                let runtime_stats = Arc::clone(&runtime);
                thread::spawn(move || {
                    let _connection_guard = connection_guard;
                    handle_connection(stream, state, runtime_stats, expected_uid)
                });
            }
            Err(err) => {
                warn!(error = %err, "Failed to accept daemon connection");
            }
        }
    }
}

fn spawn_dead_session_reconciler(state: Arc<SharedState>) {
    thread::spawn(move || loop {
        thread::sleep(Duration::from_secs(DEAD_SESSION_RECONCILE_INTERVAL_SECS));
        if let Err(err) = state.reconcile_dead_non_idle_sessions("periodic") {
            warn!(
                error = %err,
                "Periodic dead-session reconciliation failed"
            );
        }
    });
}

fn spawn_routing_tmux_poller(state: Arc<SharedState>) {
    if !state.routing_poller_enabled() {
        info!("ARE tmux poller disabled by routing config");
        return;
    }

    let poll_interval_ms = state.routing_tmux_poll_interval_ms();
    thread::spawn(move || {
        let mut poller =
            crate::are::tmux_poller::TmuxPoller::new(crate::are::tmux_poller::CommandTmuxAdapter);
        loop {
            match poller.poll_once() {
                Ok((snapshot, diff)) => state.apply_tmux_snapshot(snapshot, diff),
                Err(err) => warn!(error = %err, "ARE tmux poll failed"),
            }
            thread::sleep(Duration::from_millis(poll_interval_ms));
        }
    });
}

fn init_logging() {
    let debug_enabled = env::var("CAPACITOR_DEBUG_LOG")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false);
    let filter = if debug_enabled {
        EnvFilter::new("debug")
    } else {
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"))
    };
    tracing_subscriber::fmt().with_env_filter(filter).init();
}

fn daemon_socket_path() -> Result<PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "Home directory not found".to_string())?;
    Ok(home.join(".capacitor").join(SOCKET_NAME))
}

fn daemon_db_path() -> Result<PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "Home directory not found".to_string())?;
    Ok(home.join(".capacitor").join("daemon").join("state.db"))
}

fn daemon_backoff_path() -> Result<PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "Home directory not found".to_string())?;
    Ok(home
        .join(".capacitor")
        .join("daemon")
        .join("daemon-backoff.json"))
}

fn prepare_socket_dir(socket_path: &Path) -> Result<(), String> {
    let parent = socket_path
        .parent()
        .ok_or_else(|| "Socket path has no parent".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|err| format!("Failed to create socket directory: {}", err))?;
    fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))
        .map_err(|err| format!("Failed to set socket directory permissions: {}", err))
}

fn remove_existing_socket(socket_path: &Path) -> Result<(), String> {
    if socket_path.exists() {
        fs::remove_file(socket_path)
            .map_err(|err| format!("Failed to remove existing socket: {}", err))?;
    }
    Ok(())
}

fn set_socket_permissions(socket_path: &Path) -> Result<(), String> {
    fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600))
        .map_err(|err| format!("Failed to set socket permissions: {}", err))
}

fn handle_connection(
    mut stream: UnixStream,
    state: Arc<SharedState>,
    runtime: Arc<RuntimeStats>,
    expected_uid: u32,
) {
    match peer_uid(&stream) {
        Ok(peer_uid) if peer_uid == expected_uid => {}
        Ok(peer_uid) => {
            runtime.rejected_connections.fetch_add(1, Ordering::SeqCst);
            let response = Response::error(
                None,
                ERROR_UNAUTHORIZED_PEER,
                format!(
                    "unauthorized peer uid {} (expected {})",
                    peer_uid, expected_uid
                ),
            );
            let _ = write_response(&mut stream, response);
            return;
        }
        Err(err) => {
            runtime.rejected_connections.fetch_add(1, Ordering::SeqCst);
            let response = Response::error(
                None,
                ERROR_UNAUTHORIZED_PEER,
                format!("failed to verify peer credentials: {}", err),
            );
            let _ = write_response(&mut stream, response);
            return;
        }
    }

    let request = match read_request(&mut stream) {
        Ok(request) => request,
        Err(err) => {
            warn!(code = %err.code, message = %err.message, "Failed to read request");
            let response = Response::error_with_info(None, err);
            let _ = write_response(&mut stream, response);
            return;
        }
    };

    tracing::debug!(method = ?request.method, id = ?request.id, "Daemon request received");
    let response = handle_request(request, state, runtime);
    let _ = write_response(&mut stream, response);
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "openbsd",
    target_os = "netbsd",
    target_os = "dragonfly"
))]
fn peer_uid(stream: &UnixStream) -> Result<u32, String> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(uid as u32)
}

#[cfg(target_os = "linux")]
fn peer_uid(stream: &UnixStream) -> Result<u32, String> {
    let fd = stream.as_raw_fd();
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut cred as *mut _ as *mut libc::c_void,
            &mut len as *mut _,
        )
    };
    if rc != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(cred.uid)
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "openbsd",
    target_os = "netbsd",
    target_os = "dragonfly",
    target_os = "linux"
)))]
fn peer_uid(_stream: &UnixStream) -> Result<u32, String> {
    Err("peer credential verification unsupported on this platform".to_string())
}

fn read_request(stream: &mut UnixStream) -> Result<Request, ErrorInfo> {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(READ_TIMEOUT_SECS)));

    let mut buffer = Vec::new();
    let mut chunk = [0u8; READ_CHUNK_SIZE];

    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buffer.extend_from_slice(&chunk[..n]);
                if buffer.len() > MAX_REQUEST_BYTES {
                    return Err(ErrorInfo::new(
                        "request_too_large",
                        "request exceeded maximum size",
                    ));
                }
                if chunk[..n].contains(&b'\n') {
                    break;
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                return Err(ErrorInfo::new("read_timeout", "request timed out"));
            }
            Err(err) => {
                return Err(ErrorInfo::new(
                    "read_error",
                    format!("failed to read request: {}", err),
                ));
            }
        }
    }

    if buffer.is_empty() {
        return Err(ErrorInfo::new("empty_request", "request body was empty"));
    }

    let newline_index = buffer.iter().position(|b| *b == b'\n');
    let request_bytes = match newline_index {
        Some(index) => {
            if buffer.len() > index + 1 {
                let trailing = &buffer[index + 1..];
                if trailing.iter().any(|b| !b.is_ascii_whitespace()) {
                    warn!("Extra bytes detected after newline; ignoring trailing data");
                }
            }
            &buffer[..index]
        }
        None => buffer.as_slice(),
    };

    if request_bytes.iter().all(|b| b.is_ascii_whitespace()) {
        return Err(ErrorInfo::new("empty_request", "request body was empty"));
    }

    serde_json::from_slice(request_bytes).map_err(|err| {
        ErrorInfo::new(
            "invalid_json",
            format!("request was not valid JSON: {}", err),
        )
    })
}

fn daemon_build_hash() -> String {
    option_env!("CAPACITOR_DAEMON_BUILD_HASH")
        .unwrap_or(env!("CARGO_PKG_VERSION"))
        .to_string()
}

fn handle_request(
    request: Request,
    state: Arc<SharedState>,
    runtime: Arc<RuntimeStats>,
) -> Response {
    if request.protocol_version != PROTOCOL_VERSION {
        return Response::error(
            request.id,
            "protocol_mismatch",
            "unsupported protocol version",
        );
    }

    match request.method {
        Method::GetHealth => {
            let mut data = serde_json::json!({
                "status": "ok",
                "pid": std::process::id(),
                "version": env!("CARGO_PKG_VERSION"),
                "protocol_version": PROTOCOL_VERSION,
                "dead_session_reconcile_interval_secs": DEAD_SESSION_RECONCILE_INTERVAL_SECS,
                "security": {
                    "peer_auth_mode": "same_user",
                    "rejected_connections": runtime.rejected_connections.load(Ordering::SeqCst),
                },
                "runtime": {
                    "active_connections": runtime.active_connections.load(Ordering::SeqCst),
                    "max_active_connections": MAX_ACTIVE_CONNECTIONS,
                    "build_hash": daemon_build_hash(),
                },
            });
            if let Ok(value) = serde_json::to_value(state.dead_session_reconcile_snapshot()) {
                data["dead_session_reconcile"] = value;
            }
            if let Ok(value) = serde_json::to_value(state.hem_shadow_metrics_snapshot()) {
                data["hem_shadow"] = value;
            }
            if let Ok(value) = serde_json::to_value(state.routing_metrics_snapshot()) {
                data["routing"] = value;
            }
            if let Ok(path) = daemon_backoff_path() {
                if let Some(snapshot) = backoff::snapshot(&path) {
                    if let Ok(value) = serde_json::to_value(snapshot) {
                        data["backoff"] = value;
                    }
                }
            }
            Response::ok(request.id, data)
        }
        Method::GetShellState => {
            let snapshot = state.shell_state_snapshot();
            tracing::debug!(shells = snapshot.shells.len(), "Shell state snapshot");
            match serde_json::to_value(snapshot) {
                Ok(value) => Response::ok(request.id, value),
                Err(err) => Response::error(
                    request.id,
                    "serialization_error",
                    format!("Failed to serialize shell state: {}", err),
                ),
            }
        }
        Method::GetProcessLiveness => {
            let params = match request.params {
                Some(params) => params,
                None => return Response::error(request.id, "invalid_params", "pid is required"),
            };
            let parsed = match parse_process_liveness(params) {
                Ok(parsed) => parsed,
                Err(err) => return Response::error_with_info(request.id, err),
            };

            match state.process_liveness_snapshot(parsed.pid) {
                Ok(Some(snapshot)) => match serde_json::to_value(snapshot) {
                    Ok(value) => Response::ok(request.id, value),
                    Err(err) => Response::error(
                        request.id,
                        "serialization_error",
                        format!("Failed to serialize process liveness: {}", err),
                    ),
                },
                Ok(None) => Response::ok(
                    request.id,
                    serde_json::json!({ "found": false, "pid": parsed.pid }),
                ),
                Err(err) => Response::error(
                    request.id,
                    "liveness_error",
                    format!("Failed to fetch process liveness: {}", err),
                ),
            }
        }
        Method::GetRoutingSnapshot => {
            let params = match request.params {
                Some(params) => params,
                None => {
                    return Response::error(
                        request.id,
                        "invalid_params",
                        "project_path is required",
                    );
                }
            };
            let parsed = match parse_routing_snapshot(params) {
                Ok(parsed) => parsed,
                Err(err) => return Response::error_with_info(request.id, err),
            };
            match state.routing_snapshot(&parsed.project_path, parsed.workspace_id.as_deref()) {
                Ok(snapshot) => match serde_json::to_value(snapshot) {
                    Ok(value) => Response::ok(request.id, value),
                    Err(err) => Response::error(
                        request.id,
                        "serialization_error",
                        format!("Failed to serialize routing snapshot: {}", err),
                    ),
                },
                Err(err) => {
                    if let Some(message) = err.strip_prefix("invalid_project_path:") {
                        Response::error(request.id, ERROR_INVALID_PROJECT_PATH, message.trim())
                    } else {
                        Response::error(
                            request.id,
                            "routing_error",
                            format!("Failed to resolve routing snapshot: {}", err),
                        )
                    }
                }
            }
        }
        Method::GetRoutingDiagnostics => {
            let params = match request.params {
                Some(params) => params,
                None => {
                    return Response::error(
                        request.id,
                        "invalid_params",
                        "project_path is required",
                    );
                }
            };
            let parsed = match parse_routing_diagnostics(params) {
                Ok(parsed) => parsed,
                Err(err) => return Response::error_with_info(request.id, err),
            };
            match state.routing_diagnostics(&parsed.project_path, parsed.workspace_id.as_deref()) {
                Ok(diagnostics) => match serde_json::to_value(diagnostics) {
                    Ok(value) => Response::ok(request.id, value),
                    Err(err) => Response::error(
                        request.id,
                        "serialization_error",
                        format!("Failed to serialize routing diagnostics: {}", err),
                    ),
                },
                Err(err) => {
                    if let Some(message) = err.strip_prefix("invalid_project_path:") {
                        Response::error(request.id, ERROR_INVALID_PROJECT_PATH, message.trim())
                    } else {
                        Response::error(
                            request.id,
                            "routing_error",
                            format!("Failed to resolve routing diagnostics: {}", err),
                        )
                    }
                }
            }
        }
        Method::GetConfig => match serde_json::to_value(state.routing_config_view()) {
            Ok(value) => Response::ok(request.id, value),
            Err(err) => Response::error(
                request.id,
                "serialization_error",
                format!("Failed to serialize runtime config: {}", err),
            ),
        },
        Method::GetSessions => match state.sessions_snapshot() {
            Ok(sessions) => {
                let count = sessions.len();
                match serde_json::to_value(&sessions) {
                    Ok(value) => {
                        tracing::debug!(sessions = count, "Sessions snapshot");
                        Response::ok(request.id, value)
                    }
                    Err(err) => Response::error(
                        request.id,
                        "serialization_error",
                        format!("Failed to serialize sessions: {}", err),
                    ),
                }
            }
            Err(err) => Response::error(
                request.id,
                "sessions_error",
                format!("Failed to fetch sessions: {}", err),
            ),
        },
        Method::GetProjectStates => match state.project_states_snapshot() {
            Ok(projects) => {
                let count = projects.len();
                match serde_json::to_value(&projects) {
                    Ok(value) => {
                        tracing::debug!(projects = count, "Project states snapshot");
                        Response::ok(request.id, value)
                    }
                    Err(err) => Response::error(
                        request.id,
                        "serialization_error",
                        format!("Failed to serialize project states: {}", err),
                    ),
                }
            }
            Err(err) => Response::error(
                request.id,
                "project_states_error",
                format!("Failed to fetch project states: {}", err),
            ),
        },
        Method::GetActivity => {
            let (session_id, limit) = match parse_activity_params(request.params) {
                Ok(values) => values,
                Err(err) => return Response::error_with_info(request.id, err),
            };
            tracing::debug!(
                session_id = ?session_id,
                limit,
                "Activity snapshot request"
            );
            match state.activity_snapshot(session_id.as_deref(), limit) {
                Ok(entries) => match serde_json::to_value(entries) {
                    Ok(value) => Response::ok(request.id, value),
                    Err(err) => Response::error(
                        request.id,
                        "serialization_error",
                        format!("Failed to serialize activity: {}", err),
                    ),
                },
                Err(err) => Response::error(
                    request.id,
                    "activity_error",
                    format!("Failed to fetch activity: {}", err),
                ),
            }
        }
        Method::GetTombstones => match state.tombstones_snapshot() {
            Ok(entries) => {
                let count = entries.len();
                match serde_json::to_value(&entries) {
                    Ok(value) => {
                        tracing::debug!(tombstones = count, "Tombstone snapshot");
                        Response::ok(request.id, value)
                    }
                    Err(err) => Response::error(
                        request.id,
                        "serialization_error",
                        format!("Failed to serialize tombstones: {}", err),
                    ),
                }
            }
            Err(err) => Response::error(
                request.id,
                "tombstone_error",
                format!("Failed to fetch tombstones: {}", err),
            ),
        },
        Method::Event => handle_event(request, state),
    }
}

fn handle_event(request: Request, state: Arc<SharedState>) -> Response {
    let params = match request.params {
        Some(params) => params,
        None => return Response::error(request.id, "invalid_params", "event payload is required"),
    };

    let event = match parse_event(params) {
        Ok(event) => event,
        Err(err) => return Response::error_with_info(request.id, err),
    };

    info!(
        event_type = ?event.event_type,
        session_id = ?event.session_id,
        pid = ?event.pid,
        cwd = ?event.cwd,
        parent_app = ?event.parent_app,
        tty = ?event.tty,
        tmux_session = ?event.tmux_session,
        tmux_client_tty = ?event.tmux_client_tty,
        "Received event"
    );

    state.update_from_event(&event);

    Response::ok(request.id, serde_json::json!({"accepted": true}))
}

fn parse_activity_params(params: Option<Value>) -> Result<(Option<String>, usize), ErrorInfo> {
    let mut session_id = None;
    let mut limit = 100usize;

    if let Some(params) = params {
        if !params.is_object() {
            return Err(ErrorInfo::new("invalid_params", "params must be an object"));
        }
        if let Some(value) = params.get("session_id").and_then(|v| v.as_str()) {
            if !value.trim().is_empty() {
                session_id = Some(value.to_string());
            }
        }
        if let Some(value) = params.get("limit").and_then(|v| v.as_u64()) {
            limit = value.min(1000) as usize;
        }
    }

    Ok((session_id, limit))
}

fn write_response(stream: &mut UnixStream, response: Response) -> std::io::Result<()> {
    serde_json::to_writer(&mut *stream, &response)?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    Ok(())
}
