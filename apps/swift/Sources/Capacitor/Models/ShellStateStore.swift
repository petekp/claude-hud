import Foundation
import os.log

private let logger = Logger(subsystem: "com.capacitor.app", category: "ShellStateStore")

struct ShellEntry: Codable, Equatable {
    let cwd: String
    let tty: String
    let parentApp: String?
    let tmuxSession: String?
    let tmuxClientTty: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case cwd, tty
        case parentApp = "parent_app"
        case tmuxSession = "tmux_session"
        case tmuxClientTty = "tmux_client_tty"
        case updatedAt = "updated_at"
    }
}

struct ShellCwdState: Codable {
    let version: Int
    let shells: [String: ShellEntry]
}

struct ShellRoutingStatus: Equatable {
    let hasActiveShells: Bool
    let hasAttachedTmuxClient: Bool
    let tmuxClientTty: String?
    let targetParentApp: String?
    let targetTmuxSession: String?
}

@MainActor
@Observable
final class ShellStateStore {
    private enum Constants {
        static let pollingIntervalNanoseconds: UInt64 = 2_000_000_000
        /// Shells not updated within this threshold are considered stale and won't be used for focus detection.
        /// 10 minutes allows for typical idle periods while filtering out truly abandoned shells.
        static let shellStalenessThresholdSeconds: TimeInterval = 10 * 60
    }

    private var pollTask: _Concurrency.Task<Void, Never>?
    private let daemonClient = DaemonClient.shared

    private(set) var state: ShellCwdState?

    init() {}

    func startPolling() {
        pollTask = _Concurrency.Task { @MainActor [weak self] in
            while !_Concurrency.Task.isCancelled {
                await self?.loadState()
                try? await _Concurrency.Task.sleep(nanoseconds: Constants.pollingIntervalNanoseconds)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func loadState() async {
        guard daemonClient.isEnabled else { return }
        do {
            let daemonState = try await daemonClient.fetchShellState()
            state = daemonState
            let summary = daemonState.shells.map { pid, entry in
                "\(pid) cwd=\(entry.cwd) tty=\(entry.tty) updated=\(entry.updatedAt)"
            }
            .sorted()
            .joined(separator: " | ")
            logger.info("Shell state updated: shells=\(daemonState.shells.count) summary=\(summary, privacy: .public)")
            DebugLog.write("ShellStateStore.loadState shells=\(daemonState.shells.count) summary=\(summary)")
            let threshold = Date().addingTimeInterval(-Constants.shellStalenessThresholdSeconds)
            let staleCount = daemonState.shells.values.count(where: { $0.updatedAt <= threshold })
            Telemetry.emit("shell_state_refresh", "Shell state updated", payload: [
                "shell_count": daemonState.shells.count,
                "stale_filtered_count": staleCount,
            ])
        } catch {
            logger.info("Shell state update failed: \(error.localizedDescription, privacy: .public)")
            DebugLog.write("ShellStateStore.loadState failed: \(error)")
            Telemetry.emit("shell_state_refresh", "Shell state update failed", payload: [
                "error": error.localizedDescription,
            ])
        }
    }

    /// Returns the most recently updated non-stale shell.
    /// Shells that haven't been updated within the staleness threshold are filtered out
    /// to prevent old, abandoned shell sessions from affecting focus detection.
    var mostRecentShell: (pid: String, entry: ShellEntry)? {
        mostRecentShell(matchingParentApp: nil)
    }

    /// Returns the most recently updated non-stale shell, optionally filtered by parent app.
    /// Prefers interactive TTYs (e.g., /dev/ttys*) to avoid background/non-interactive shells.
    /// If no shells match the requested parent app, falls back to the full shell list.
    func mostRecentShell(matchingParentApp parentApp: String?) -> (pid: String, entry: ShellEntry)? {
        var candidates = activeShellEntries()
        let interactive = candidates.filter { $0.value.tty.hasPrefix("/dev/tty") }
        if !interactive.isEmpty {
            candidates = interactive
        }
        if let parentApp {
            let normalized = parentApp.lowercased()
            let allowsTmux = ["terminal", "iterm2", "ghostty", "warp", "alacritty", "kitty"].contains(normalized)
            let filtered = candidates.filter {
                let entryApp = $0.value.parentApp?.lowercased()
                if entryApp == normalized {
                    return true
                }
                if allowsTmux, entryApp == "tmux" {
                    return true
                }
                return false
            }
            if !filtered.isEmpty {
                candidates = filtered
            }
        }

        return candidates
            .max(by: { $0.value.updatedAt < $1.value.updatedAt })
            .map { ($0.key, $0.value) }
    }

    /// Returns true if there are any non-stale active shells.
    var hasActiveShells: Bool {
        !activeShellEntries().isEmpty
    }

    /// Lightweight status used by the projects UI to explain activation behavior.
    var routingStatus: ShellRoutingStatus {
        let activeShells = activeShellEntries()
        let mostRecent = mostRecentShell

        let attachedTmuxShell = activeShells
            .filter { _, entry in
                guard let tty = entry.tmuxClientTty?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }
                return !tty.isEmpty
            }
            .max { lhs, rhs in
                lhs.value.updatedAt < rhs.value.updatedAt
            }

        let tmuxClientTty = attachedTmuxShell?.value.tmuxClientTty?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ShellRoutingStatus(
            hasActiveShells: !activeShells.isEmpty,
            hasAttachedTmuxClient: attachedTmuxShell != nil,
            tmuxClientTty: tmuxClientTty?.isEmpty == false ? tmuxClientTty : nil,
            targetParentApp: mostRecent?.entry.parentApp,
            targetTmuxSession: mostRecent?.entry.tmuxSession,
        )
    }

    private func activeShellEntries() -> [Dictionary<String, ShellEntry>.Element] {
        guard let shells = state?.shells else { return [] }
        let threshold = Date().addingTimeInterval(-Constants.shellStalenessThresholdSeconds)
        return shells.filter { $0.value.updatedAt > threshold }
    }

    #if DEBUG
        /// Test-only helper for deterministic resolution.
        func setStateForTesting(_ state: ShellCwdState?) {
            self.state = state
        }
    #endif
}
