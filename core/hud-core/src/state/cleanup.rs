//! Startup cleanup for daemon-era artifacts.
//!
//! Only legacy orphaned lock-holder processes are cleaned up here.

use sysinfo::{Pid, ProcessRefreshKind, System, UpdateKind};

/// Kills orphaned lock-holder processes whose monitored PID is dead.
///
/// Legacy lock-holder processes (`hud-hook lock-holder --pid <PID>`) monitored Claude
/// processes and released locks when they exited. If the lock-holder itself was killed
/// before cleanup, the process became orphaned.
///
/// This function:
/// 1. Enumerates all processes whose command contains "hud-hook" and "lock-holder"
/// 2. Parses the --pid argument to find the monitored PID
/// 3. Sends SIGTERM to lock-holders whose monitored PID is dead
///
/// Safety: Only kills processes where the monitored PID is confirmed dead.
/// This prevents killing any still-legitimate legacy lock-holders.
pub fn cleanup_orphaned_lock_holders() -> CleanupStats {
    let mut stats = CleanupStats::default();

    // Initialize sysinfo with command line info
    let mut sys = System::new();
    sys.refresh_processes_specifics(ProcessRefreshKind::new().with_cmd(UpdateKind::Always));

    for (pid, process) in sys.processes() {
        let cmd = process.cmd();

        // Look for legacy lock-holder processes
        // Command format: hud-hook lock-holder --session_id <ID> --cwd <PATH> --pid <PID>
        let is_lock_holder = cmd.iter().any(|arg| arg.contains("hud-hook"))
            && cmd.iter().any(|arg| arg == "lock-holder");

        if !is_lock_holder {
            continue;
        }

        // Parse the --pid argument to find which PID this holder is monitoring
        let monitored_pid = parse_monitored_pid(cmd);

        let Some(monitored) = monitored_pid else {
            // Can't determine which PID is being monitored - skip to be safe
            continue;
        };

        // Check if the monitored PID is still alive
        if is_monitored_pid_alive(monitored, &sys) {
            // Monitored process is still alive - this is a legitimate lock holder
            continue;
        }

        // Monitored PID is dead - this lock holder is orphaned
        // Send SIGTERM to give it a chance to clean up gracefully
        #[cfg(unix)]
        {
            let holder_pid = pid.as_u32() as i32;
            // SAFETY: libc::kill with SIGTERM is a standard POSIX signal delivery.
            // The holder_pid is obtained from sysinfo enumeration, so it's a valid PID.
            // SIGTERM allows graceful shutdown. If the process already exited, we get ESRCH.
            #[allow(unsafe_code)]
            unsafe {
                if libc::kill(holder_pid, libc::SIGTERM) == 0 {
                    stats.orphaned_processes_killed += 1;
                } else {
                    // Failed to kill - might have already exited
                    let errno = *libc::__error();
                    if errno != libc::ESRCH {
                        // ESRCH = no such process (already dead), not an error
                        stats.errors.push(format!(
                            "Failed to kill orphaned lock-holder PID {}: errno {}",
                            holder_pid, errno
                        ));
                    }
                }
            }
        }
    }

    stats
}

fn is_monitored_pid_alive(pid: u32, sys: &System) -> bool {
    if let Some(snapshot) = super::daemon::process_liveness(pid) {
        if snapshot.is_alive == Some(false) {
            return false;
        }
        if let Some(identity_matches) = snapshot.identity_matches {
            return identity_matches;
        }
        if snapshot.is_alive == Some(true) {
            return true;
        }
    }

    sys.process(Pid::from_u32(pid)).is_some()
}

/// Parses the --pid argument from a lock-holder command line.
fn parse_monitored_pid(cmd: &[String]) -> Option<u32> {
    let mut found_pid_flag = false;
    for arg in cmd {
        if found_pid_flag {
            return arg.parse().ok();
        }
        if arg == "--pid" {
            found_pid_flag = true;
        }
    }
    None
}

/// Results from a cleanup operation.
#[derive(Debug, Default, Clone, uniffi::Record)]
pub struct CleanupStats {
    /// Number of orphaned legacy lock directories removed (dead PIDs).
    pub locks_removed: u32,
    /// Number of legacy MD5-hash locks removed (dead PIDs).
    pub legacy_locks_removed: u32,
    /// Number of orphaned lock-holder processes killed (monitoring dead PIDs).
    pub orphaned_processes_killed: u32,
    /// Number of orphaned session records removed (stale + no active lock).
    pub orphaned_sessions_removed: u32,
    /// Number of expired session records removed (> 24 hours old).
    pub sessions_removed: u32,
    /// Number of old tombstone files removed (> 1 minute old).
    pub tombstones_removed: u32,
    /// Number of old file activity entries cleaned up (> 24 hours old).
    pub activity_entries_removed: u32,
    /// Errors encountered during cleanup.
    pub errors: Vec<String>,
}

/// Performs startup cleanup on daemon-era artifacts.
///
/// The daemon is authoritative; no file-based cleanup is performed.
pub fn run_startup_cleanup() -> CleanupStats {
    let mut stats = CleanupStats::default();
    let process_stats = cleanup_orphaned_lock_holders();
    stats.orphaned_processes_killed = process_stats.orphaned_processes_killed;
    stats.errors.extend(process_stats.errors);
    stats
}
