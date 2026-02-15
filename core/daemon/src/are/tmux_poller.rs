use crate::are::registry::{TmuxClientSignal, TmuxSessionSignal};
use chrono::{DateTime, Utc};
use std::collections::{BTreeSet, HashMap};
use std::io;
use std::process::Command;
const TMUX_FIELD_DELIMITER: &str = "__CAP_DELIM__";

#[derive(Debug, Clone)]
pub struct TmuxSnapshot {
    pub captured_at: DateTime<Utc>,
    pub clients: Vec<TmuxClientSignal>,
    pub sessions: Vec<TmuxSessionSignal>,
}

pub trait TmuxAdapter: Send + Sync {
    fn snapshot(&self) -> Result<TmuxSnapshot, String>;
}

#[derive(Debug, Clone, Default)]
pub struct CommandTmuxAdapter;

impl TmuxAdapter for CommandTmuxAdapter {
    fn snapshot(&self) -> Result<TmuxSnapshot, String> {
        let captured_at = Utc::now();
        let clients_output = run_tmux([
            "list-clients",
            "-F",
            "#{client_tty}__CAP_DELIM__#{session_name}__CAP_DELIM__#{pane_current_path}",
        ])?;
        let panes_output = run_tmux([
            "list-panes",
            "-a",
            "-F",
            "#{session_name}__CAP_DELIM__#{pane_current_path}",
        ])?;
        let clients = parse_tmux_clients(&clients_output, captured_at);
        let sessions = parse_tmux_panes(&panes_output, captured_at);

        Ok(TmuxSnapshot {
            captured_at,
            clients,
            sessions,
        })
    }
}

#[derive(Debug)]
pub struct TmuxPoller<A: TmuxAdapter> {
    adapter: A,
    previous_snapshot: Option<TmuxSnapshot>,
}

impl<A: TmuxAdapter> TmuxPoller<A> {
    pub fn new(adapter: A) -> Self {
        Self {
            adapter,
            previous_snapshot: None,
        }
    }

    pub fn poll_once(&mut self) -> Result<(TmuxSnapshot, TmuxDiff), String> {
        let snapshot = self.adapter.snapshot()?;
        let diff = compute_diff(self.previous_snapshot.as_ref(), &snapshot);
        self.previous_snapshot = Some(snapshot.clone());
        Ok((snapshot, diff))
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TmuxDiff {
    pub clients_added: usize,
    pub clients_removed: usize,
    pub clients_updated: usize,
    pub sessions_added: usize,
    pub sessions_removed: usize,
    pub sessions_updated: usize,
}

pub fn compute_diff(previous: Option<&TmuxSnapshot>, current: &TmuxSnapshot) -> TmuxDiff {
    let Some(previous) = previous else {
        return TmuxDiff {
            clients_added: current.clients.len(),
            sessions_added: current.sessions.len(),
            ..TmuxDiff::default()
        };
    };

    let mut diff = TmuxDiff::default();

    let mut previous_clients = std::collections::HashMap::new();
    for client in &previous.clients {
        previous_clients.insert(client.client_tty.as_str(), client);
    }
    let mut current_clients = std::collections::HashMap::new();
    for client in &current.clients {
        current_clients.insert(client.client_tty.as_str(), client);
    }

    for (tty, current_client) in &current_clients {
        match previous_clients.get(tty) {
            None => diff.clients_added = diff.clients_added.saturating_add(1),
            Some(previous_client) => {
                if previous_client.session_name != current_client.session_name
                    || previous_client.pane_current_path != current_client.pane_current_path
                {
                    diff.clients_updated = diff.clients_updated.saturating_add(1);
                }
            }
        }
    }
    for tty in previous_clients.keys() {
        if !current_clients.contains_key(tty) {
            diff.clients_removed = diff.clients_removed.saturating_add(1);
        }
    }

    let mut previous_sessions = std::collections::HashMap::new();
    for session in &previous.sessions {
        previous_sessions.insert(session.session_name.as_str(), session);
    }
    let mut current_sessions = std::collections::HashMap::new();
    for session in &current.sessions {
        current_sessions.insert(session.session_name.as_str(), session);
    }

    for (session_name, current_session) in &current_sessions {
        match previous_sessions.get(session_name) {
            None => diff.sessions_added = diff.sessions_added.saturating_add(1),
            Some(previous_session) => {
                if previous_session.pane_paths != current_session.pane_paths {
                    diff.sessions_updated = diff.sessions_updated.saturating_add(1);
                }
            }
        }
    }
    for session_name in previous_sessions.keys() {
        if !current_sessions.contains_key(session_name) {
            diff.sessions_removed = diff.sessions_removed.saturating_add(1);
        }
    }

    diff
}

fn run_tmux<const N: usize>(args: [&str; N]) -> Result<String, String> {
    run_tmux_with_runner(args, |binary, args| {
        Command::new(binary).args(args).output()
    })
}

fn run_tmux_with_runner<const N: usize, F>(args: [&str; N], mut runner: F) -> Result<String, String>
where
    F: FnMut(&str, [&str; N]) -> io::Result<std::process::Output>,
{
    for binary in tmux_binary_candidates() {
        match runner(binary, args) {
            Ok(output) if output.status.success() => {
                return Ok(String::from_utf8_lossy(&output.stdout).to_string());
            }
            Ok(_output) => {
                // Continue across candidates because PATH "tmux" may point to a
                // binary that cannot talk to the active server/socket.
                continue;
            }
            Err(err) if err.kind() == io::ErrorKind::NotFound => continue,
            Err(_err) => continue,
        }
    }

    Ok(String::new())
}

fn tmux_binary_candidates() -> &'static [&'static str] {
    &[
        "tmux",
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "/usr/bin/tmux",
    ]
}

fn parse_tmux_clients(output: &str, captured_at: DateTime<Utc>) -> Vec<TmuxClientSignal> {
    let mut clients = output
        .lines()
        .filter_map(|line| {
            let (client_tty, session_name, pane_current_path) = parse_client_line(line)?;
            if client_tty.is_empty() || session_name.is_empty() {
                return None;
            }
            Some(TmuxClientSignal {
                client_tty: client_tty.to_string(),
                session_name: session_name.to_string(),
                pane_current_path: pane_current_path.map(str::to_string),
                captured_at,
            })
        })
        .collect::<Vec<_>>();
    clients.sort_by(|left, right| left.client_tty.cmp(&right.client_tty));
    clients
}

fn parse_tmux_panes(output: &str, captured_at: DateTime<Utc>) -> Vec<TmuxSessionSignal> {
    let mut session_paths: HashMap<String, BTreeSet<String>> = HashMap::new();
    for line in output.lines() {
        let Some((session_name, pane_path)) = parse_session_line(line) else {
            continue;
        };
        let entry = session_paths.entry(session_name.to_string()).or_default();
        entry.insert(pane_path.to_string());
    }

    let mut sessions = session_paths
        .into_iter()
        .map(|(session_name, pane_paths)| TmuxSessionSignal {
            session_name,
            pane_paths: pane_paths.into_iter().collect(),
            captured_at,
        })
        .collect::<Vec<_>>();
    sessions.sort_by(|left, right| left.session_name.cmp(&right.session_name));
    sessions
}

fn parse_client_line(line: &str) -> Option<(&str, &str, Option<&str>)> {
    if let Some((client_tty, session_name, pane_path)) = split_fields(line, 3) {
        let pane_current_path = pane_path.filter(|value| !value.is_empty());
        return Some((client_tty, session_name, pane_current_path));
    }
    None
}

fn parse_session_line(line: &str) -> Option<(&str, &str)> {
    if let Some((session_name, pane_path, _)) = split_fields(line, 2) {
        if pane_path.is_empty() {
            return None;
        }
        return Some((session_name, pane_path));
    }
    None
}

fn split_fields(line: &str, expected: usize) -> Option<(&str, &str, Option<&str>)> {
    if line.contains(TMUX_FIELD_DELIMITER) {
        return split_fields_with_delimiter(line, TMUX_FIELD_DELIMITER, expected);
    }
    split_fields_with_delimiter(line, "\t", expected)
}

fn split_fields_with_delimiter<'a>(
    line: &'a str,
    delimiter: &str,
    expected: usize,
) -> Option<(&'a str, &'a str, Option<&'a str>)> {
    let mut parts = line.splitn(expected, delimiter);
    let first = parts.next()?.trim();
    let second = parts.next()?.trim();
    let third = parts.next().map(str::trim);
    Some((first, second, third))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    use std::collections::VecDeque;
    use std::os::unix::process::ExitStatusExt;
    use std::sync::{Arc, Mutex};

    fn at(value: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(value)
            .expect("parse")
            .with_timezone(&Utc)
    }

    #[test]
    fn compute_diff_detects_client_add_remove_and_update() {
        let previous = TmuxSnapshot {
            captured_at: at("2026-02-14T10:00:00Z"),
            clients: vec![
                TmuxClientSignal {
                    client_tty: "/dev/ttys001".to_string(),
                    session_name: "alpha".to_string(),
                    pane_current_path: Some("/repo/a".to_string()),
                    captured_at: at("2026-02-14T10:00:00Z"),
                },
                TmuxClientSignal {
                    client_tty: "/dev/ttys002".to_string(),
                    session_name: "beta".to_string(),
                    pane_current_path: Some("/repo/b".to_string()),
                    captured_at: at("2026-02-14T10:00:00Z"),
                },
            ],
            sessions: vec![TmuxSessionSignal {
                session_name: "alpha".to_string(),
                pane_paths: vec!["/repo/a".to_string()],
                captured_at: at("2026-02-14T10:00:00Z"),
            }],
        };

        let current = TmuxSnapshot {
            captured_at: previous.captured_at + Duration::seconds(1),
            clients: vec![
                TmuxClientSignal {
                    client_tty: "/dev/ttys001".to_string(),
                    session_name: "alpha".to_string(),
                    pane_current_path: Some("/repo/a/next".to_string()),
                    captured_at: at("2026-02-14T10:00:01Z"),
                },
                TmuxClientSignal {
                    client_tty: "/dev/ttys003".to_string(),
                    session_name: "gamma".to_string(),
                    pane_current_path: Some("/repo/c".to_string()),
                    captured_at: at("2026-02-14T10:00:01Z"),
                },
            ],
            sessions: vec![
                TmuxSessionSignal {
                    session_name: "alpha".to_string(),
                    pane_paths: vec!["/repo/a/next".to_string()],
                    captured_at: at("2026-02-14T10:00:01Z"),
                },
                TmuxSessionSignal {
                    session_name: "gamma".to_string(),
                    pane_paths: vec!["/repo/c".to_string()],
                    captured_at: at("2026-02-14T10:00:01Z"),
                },
            ],
        };

        let diff = compute_diff(Some(&previous), &current);
        assert_eq!(diff.clients_added, 1);
        assert_eq!(diff.clients_removed, 1);
        assert_eq!(diff.clients_updated, 1);
        assert_eq!(diff.sessions_added, 1);
        assert_eq!(diff.sessions_removed, 0);
        assert_eq!(diff.sessions_updated, 1);
    }

    #[test]
    fn compute_diff_is_zero_for_identical_snapshot() {
        let snapshot = TmuxSnapshot {
            captured_at: at("2026-02-14T10:00:00Z"),
            clients: vec![TmuxClientSignal {
                client_tty: "/dev/ttys001".to_string(),
                session_name: "alpha".to_string(),
                pane_current_path: Some("/repo/a".to_string()),
                captured_at: at("2026-02-14T10:00:00Z"),
            }],
            sessions: vec![TmuxSessionSignal {
                session_name: "alpha".to_string(),
                pane_paths: vec!["/repo/a".to_string()],
                captured_at: at("2026-02-14T10:00:00Z"),
            }],
        };

        let diff = compute_diff(Some(&snapshot), &snapshot);
        assert_eq!(diff, TmuxDiff::default());
    }

    #[test]
    fn parse_tmux_clients_ignores_invalid_lines_and_normalizes_paths() {
        let captured_at = at("2026-02-14T10:00:00Z");
        let raw = "\
/dev/ttys001\talpha\t/Users/pete/Code/capacitor\n\
/dev/ttys002\tbeta\t\n\
invalid\n";

        let parsed = parse_tmux_clients(raw, captured_at);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].client_tty, "/dev/ttys001");
        assert_eq!(parsed[0].session_name, "alpha");
        assert_eq!(
            parsed[0].pane_current_path.as_deref(),
            Some("/Users/pete/Code/capacitor")
        );
        assert_eq!(parsed[1].client_tty, "/dev/ttys002");
        assert_eq!(parsed[1].session_name, "beta");
        assert!(parsed[1].pane_current_path.is_none());
    }

    #[test]
    fn parse_tmux_clients_supports_custom_delimiter_format() {
        let captured_at = at("2026-02-14T10:00:00Z");
        let raw = "\
/dev/ttys001__CAP_DELIM__alpha__CAP_DELIM__/Users/pete/Code/capacitor\n\
/dev/ttys002__CAP_DELIM__beta__CAP_DELIM__\n";

        let parsed = parse_tmux_clients(raw, captured_at);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].client_tty, "/dev/ttys001");
        assert_eq!(parsed[0].session_name, "alpha");
        assert_eq!(
            parsed[0].pane_current_path.as_deref(),
            Some("/Users/pete/Code/capacitor")
        );
        assert_eq!(parsed[1].client_tty, "/dev/ttys002");
        assert_eq!(parsed[1].session_name, "beta");
        assert!(parsed[1].pane_current_path.is_none());
    }

    #[test]
    fn parse_tmux_panes_groups_paths_by_session() {
        let captured_at = at("2026-02-14T10:00:00Z");
        let raw = "\
alpha\t/Users/pete/Code/a\n\
alpha\t/Users/pete/Code/a\n\
alpha\t/Users/pete/Code/a/sub\n\
beta\t/Users/pete/Code/b\n\
invalid\n";

        let sessions = parse_tmux_panes(raw, captured_at);
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].session_name, "alpha");
        assert_eq!(
            sessions[0].pane_paths,
            vec![
                "/Users/pete/Code/a".to_string(),
                "/Users/pete/Code/a/sub".to_string()
            ]
        );
        assert_eq!(sessions[1].session_name, "beta");
        assert_eq!(
            sessions[1].pane_paths,
            vec!["/Users/pete/Code/b".to_string()]
        );
    }

    #[test]
    fn parse_tmux_panes_supports_custom_delimiter_format() {
        let captured_at = at("2026-02-14T10:00:00Z");
        let raw = "\
alpha__CAP_DELIM__/Users/pete/Code/a\n\
alpha__CAP_DELIM__/Users/pete/Code/a/sub\n\
beta__CAP_DELIM__/Users/pete/Code/b\n";

        let sessions = parse_tmux_panes(raw, captured_at);
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].session_name, "alpha");
        assert_eq!(
            sessions[0].pane_paths,
            vec![
                "/Users/pete/Code/a".to_string(),
                "/Users/pete/Code/a/sub".to_string()
            ]
        );
        assert_eq!(sessions[1].session_name, "beta");
        assert_eq!(
            sessions[1].pane_paths,
            vec!["/Users/pete/Code/b".to_string()]
        );
    }

    #[derive(Clone)]
    struct FakeAdapter {
        snapshots: Arc<Mutex<VecDeque<TmuxSnapshot>>>,
    }

    impl TmuxAdapter for FakeAdapter {
        fn snapshot(&self) -> Result<TmuxSnapshot, String> {
            self.snapshots
                .lock()
                .expect("lock snapshots")
                .pop_front()
                .ok_or_else(|| "no snapshot".to_string())
        }
    }

    #[test]
    fn poller_tracks_previous_snapshot_for_incremental_diffing() {
        let snapshot1 = TmuxSnapshot {
            captured_at: at("2026-02-14T10:00:00Z"),
            clients: vec![TmuxClientSignal {
                client_tty: "/dev/ttys001".to_string(),
                session_name: "alpha".to_string(),
                pane_current_path: Some("/repo/a".to_string()),
                captured_at: at("2026-02-14T10:00:00Z"),
            }],
            sessions: vec![TmuxSessionSignal {
                session_name: "alpha".to_string(),
                pane_paths: vec!["/repo/a".to_string()],
                captured_at: at("2026-02-14T10:00:00Z"),
            }],
        };
        let snapshot2 = TmuxSnapshot {
            captured_at: at("2026-02-14T10:00:01Z"),
            clients: vec![
                TmuxClientSignal {
                    client_tty: "/dev/ttys001".to_string(),
                    session_name: "alpha".to_string(),
                    pane_current_path: Some("/repo/a/next".to_string()),
                    captured_at: at("2026-02-14T10:00:01Z"),
                },
                TmuxClientSignal {
                    client_tty: "/dev/ttys002".to_string(),
                    session_name: "beta".to_string(),
                    pane_current_path: Some("/repo/b".to_string()),
                    captured_at: at("2026-02-14T10:00:01Z"),
                },
            ],
            sessions: vec![
                TmuxSessionSignal {
                    session_name: "alpha".to_string(),
                    pane_paths: vec!["/repo/a/next".to_string()],
                    captured_at: at("2026-02-14T10:00:01Z"),
                },
                TmuxSessionSignal {
                    session_name: "beta".to_string(),
                    pane_paths: vec!["/repo/b".to_string()],
                    captured_at: at("2026-02-14T10:00:01Z"),
                },
            ],
        };
        let adapter = FakeAdapter {
            snapshots: Arc::new(Mutex::new(VecDeque::from(vec![
                snapshot1.clone(),
                snapshot2.clone(),
            ]))),
        };

        let mut poller = TmuxPoller::new(adapter);
        let (_, first_diff) = poller.poll_once().expect("first poll");
        assert_eq!(first_diff.clients_added, 1);
        assert_eq!(first_diff.sessions_added, 1);

        let (_, second_diff) = poller.poll_once().expect("second poll");
        assert_eq!(second_diff.clients_added, 1);
        assert_eq!(second_diff.clients_updated, 1);
        assert_eq!(second_diff.sessions_added, 1);
        assert_eq!(second_diff.sessions_updated, 1);
    }

    #[test]
    fn run_tmux_falls_back_to_absolute_binary_when_tmux_not_in_path() {
        let attempted = Arc::new(Mutex::new(Vec::<String>::new()));
        let attempted_clone = Arc::clone(&attempted);

        let output = run_tmux_with_runner(["list-clients"], move |binary, _args| {
            attempted_clone
                .lock()
                .expect("lock attempted binaries")
                .push(binary.to_string());

            if binary == "tmux" {
                return Err(io::Error::new(io::ErrorKind::NotFound, "tmux not found"));
            }

            if binary == "/opt/homebrew/bin/tmux" {
                let mut out = std::process::Output {
                    status: std::process::ExitStatus::from_raw(0),
                    stdout: Vec::new(),
                    stderr: Vec::new(),
                };
                out.stdout = b"/dev/ttys010\tcaps\t/Users/pete/Code/capacitor\n".to_vec();
                return Ok(out);
            }

            Err(io::Error::new(io::ErrorKind::NotFound, "missing"))
        })
        .expect("runner should return output");

        let attempted = attempted.lock().expect("lock attempted binaries");
        assert_eq!(
            attempted.as_slice(),
            ["tmux".to_string(), "/opt/homebrew/bin/tmux".to_string()]
        );
        assert!(output.contains("/dev/ttys010"));
    }

    #[test]
    fn run_tmux_falls_back_after_non_success_status_on_first_binary() {
        let attempted = Arc::new(Mutex::new(Vec::<String>::new()));
        let attempted_clone = Arc::clone(&attempted);

        let output = run_tmux_with_runner(["list-clients"], move |binary, _args| {
            attempted_clone
                .lock()
                .expect("lock attempted binaries")
                .push(binary.to_string());

            if binary == "tmux" {
                return Ok(std::process::Output {
                    status: std::process::ExitStatus::from_raw(1 << 8),
                    stdout: Vec::new(),
                    stderr: b"protocol version mismatch".to_vec(),
                });
            }

            if binary == "/opt/homebrew/bin/tmux" {
                return Ok(std::process::Output {
                    status: std::process::ExitStatus::from_raw(0),
                    stdout: b"/dev/ttys020\tcaps\t/Users/pete/Code/capacitor\n".to_vec(),
                    stderr: Vec::new(),
                });
            }

            Err(io::Error::new(io::ErrorKind::NotFound, "missing"))
        })
        .expect("runner should return output");

        let attempted = attempted.lock().expect("lock attempted binaries");
        assert_eq!(
            attempted.as_slice(),
            ["tmux".to_string(), "/opt/homebrew/bin/tmux".to_string()]
        );
        assert!(output.contains("/dev/ttys020"));
    }
}
