use crate::are::registry::{TmuxClientSignal, TmuxSessionSignal};
use chrono::{DateTime, Utc};
use std::collections::{BTreeSet, HashMap};
use std::process::Command;

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
            "#{client_tty}\t#{session_name}\t#{pane_current_path}",
        ])?;
        let panes_output = run_tmux([
            "list-panes",
            "-a",
            "-F",
            "#{session_name}\t#{pane_current_path}",
        ])?;

        Ok(TmuxSnapshot {
            captured_at,
            clients: parse_tmux_clients(&clients_output, captured_at),
            sessions: parse_tmux_panes(&panes_output, captured_at),
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
    match Command::new("tmux").args(args).output() {
        Ok(output) if output.status.success() => {
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        }
        Ok(_) => Ok(String::new()),
        Err(_) => Ok(String::new()),
    }
}

fn parse_tmux_clients(output: &str, captured_at: DateTime<Utc>) -> Vec<TmuxClientSignal> {
    let mut clients = output
        .lines()
        .filter_map(|line| {
            let mut parts = line.split('\t');
            let client_tty = parts.next()?.trim();
            let session_name = parts.next()?.trim();
            if client_tty.is_empty() || session_name.is_empty() {
                return None;
            }
            let pane_current_path = parts
                .next()
                .map(str::trim)
                .filter(|value| !value.is_empty());
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
        let mut parts = line.split('\t');
        let Some(session_name) = parts
            .next()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        let Some(pane_path) = parts
            .next()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    use std::collections::VecDeque;
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
}
