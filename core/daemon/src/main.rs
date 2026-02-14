//! Capacitor daemon entrypoint.
//!
//! This is a small, single-writer service that owns state updates for the app.
//! Phase 3 keeps it minimal: a socket listener, strict request validation, and
//! a SQLite-backed event log with a materialized shell state view.

use fs_err as fs;
use std::env;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

use capacitor_daemon_protocol::{
    parse_event, parse_process_liveness, ErrorInfo, Method, Request, Response, MAX_REQUEST_BYTES,
    PROTOCOL_VERSION,
};
use serde_json::Value;

mod activity;
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
        "HEM runtime config loaded"
    );
    spawn_dead_session_reconciler(Arc::clone(&shared_state));

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = Arc::clone(&shared_state);
                thread::spawn(|| handle_connection(stream, state));
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
    fs::create_dir_all(parent).map_err(|err| format!("Failed to create socket directory: {}", err))
}

fn remove_existing_socket(socket_path: &Path) -> Result<(), String> {
    if socket_path.exists() {
        fs::remove_file(socket_path)
            .map_err(|err| format!("Failed to remove existing socket: {}", err))?;
    }
    Ok(())
}

fn handle_connection(mut stream: UnixStream, state: Arc<SharedState>) {
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
    let response = handle_request(request, state);
    let _ = write_response(&mut stream, response);
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

fn handle_request(request: Request, state: Arc<SharedState>) -> Response {
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
            });
            if let Ok(value) = serde_json::to_value(state.dead_session_reconcile_snapshot()) {
                data["dead_session_reconcile"] = value;
            }
            if let Ok(value) = serde_json::to_value(state.hem_shadow_metrics_snapshot()) {
                data["hem_shadow"] = value;
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
