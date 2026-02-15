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
    private var routingProjectPath: String?

    private(set) var state: ShellCwdState?
    private(set) var areRoutingSnapshot: DaemonRoutingSnapshot?

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

    func setRoutingProjectPath(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        routingProjectPath = normalized
        if normalized == nil {
            areRoutingSnapshot = nil
        }
    }

    private func loadState() async {
        guard daemonClient.isEnabled else {
            areRoutingSnapshot = nil
            return
        }
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
            await refreshAERRoutingSnapshot()
        } catch {
            logger.info("Shell state update failed: \(error.localizedDescription, privacy: .public)")
            DebugLog.write("ShellStateStore.loadState failed: \(error)")
            Telemetry.emit("shell_state_refresh", "Shell state update failed", payload: [
                "error": error.localizedDescription,
            ])
            areRoutingSnapshot = nil
        }
    }

    private func refreshAERRoutingSnapshot() async {
        guard let projectPath = routingProjectPath else {
            areRoutingSnapshot = nil
            return
        }

        do {
            areRoutingSnapshot = try await daemonClient.fetchRoutingSnapshot(
                projectPath: projectPath,
                workspaceId: nil,
            )
        } catch {
            areRoutingSnapshot = nil
            Telemetry.emit(
                "routing_snapshot_refresh_error",
                "Routing snapshot refresh failed",
                payload: [
                    "project_path": projectPath,
                    "error": error.localizedDescription,
                ],
            )
        }
    }

    #if DEBUG
        /// Test-only helper for deterministic routing snapshot behavior.
        func setRoutingSnapshotForTesting(_ snapshot: DaemonRoutingSnapshot?) {
            areRoutingSnapshot = snapshot
        }
    #endif
}
