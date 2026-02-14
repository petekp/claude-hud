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
    let hasAnyShells: Bool
    let tmuxClientTty: String?
    let targetParentApp: String?
    let targetTmuxSession: String?
    let lastSeenAt: Date?
    let isUsingLastKnownTarget: Bool

    var hasStaleTelemetry: Bool {
        !hasActiveShells && hasAnyShells
    }

    func staleAgeMinutes(reference: Date = Date()) -> Int? {
        guard let lastSeenAt else { return nil }
        let interval = reference.timeIntervalSince(lastSeenAt)
        return max(0, Int(interval / 60.0))
    }
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
            let flags = AppConfig.current().featureFlags
            if flags.areStatusRow || flags.areShadowCompare {
                if let projectPath = mostRecentShell?.entry.cwd {
                    await refreshAERRoutingSnapshot(
                        projectPath: projectPath,
                        emitShadowCompare: flags.areShadowCompare,
                    )
                } else if flags.areStatusRow {
                    areRoutingSnapshot = nil
                }
            }
        } catch {
            logger.info("Shell state update failed: \(error.localizedDescription, privacy: .public)")
            DebugLog.write("ShellStateStore.loadState failed: \(error)")
            Telemetry.emit("shell_state_refresh", "Shell state update failed", payload: [
                "error": error.localizedDescription,
            ])
        }
    }

    private func refreshAERRoutingSnapshot(projectPath: String, emitShadowCompare: Bool) async {
        do {
            let snapshot = try await daemonClient.fetchRoutingSnapshot(
                projectPath: projectPath,
                workspaceId: nil,
            )
            areRoutingSnapshot = snapshot
            guard emitShadowCompare else {
                return
            }
            let local = Self.shadowComparableDecision(from: routingStatus)
            let statusMismatch = local.status != snapshot.status
            let targetMismatch = local.targetKind != snapshot.target.kind
                || local.targetValue != snapshot.target.value
            Telemetry.emit(
                "routing_shadow_compare",
                statusMismatch || targetMismatch ? "mismatch" : "match",
                payload: [
                    "project_path": projectPath,
                    "local_status": local.status,
                    "are_status": snapshot.status,
                    "local_target_kind": local.targetKind,
                    "are_target_kind": snapshot.target.kind,
                    "local_target_value": local.targetValue ?? "",
                    "are_target_value": snapshot.target.value ?? "",
                    "status_mismatch": statusMismatch,
                    "target_mismatch": targetMismatch,
                ],
            )
        } catch {
            Telemetry.emit(
                "routing_shadow_compare_error",
                "Routing shadow compare failed",
                payload: [
                    "project_path": projectPath,
                    "error": error.localizedDescription,
                ],
            )
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
        let allShells = state?.shells ?? [:]
        func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func hasUsableRoutingTarget(_ entry: ShellEntry) -> Bool {
            if normalized(entry.tmuxSession) != nil {
                return true
            }
            guard let parentApp = normalized(entry.parentApp)?.lowercased() else {
                return false
            }
            return parentApp != "unknown"
        }

        let mostRecentActive = mostRecentShell
        let mostRecentKnown = allShells
            .max(by: { $0.value.updatedAt < $1.value.updatedAt })
            .map { (pid: $0.key, entry: $0.value) }
        let mostRecentKnownUsable = allShells
            .filter { _, entry in hasUsableRoutingTarget(entry) }
            .max(by: { $0.value.updatedAt < $1.value.updatedAt })
            .map { (pid: $0.key, entry: $0.value) }

        let attachedTmuxShell = activeShells
            .filter { _, entry in
                normalized(entry.tmuxClientTty) != nil
            }
            .max { lhs, rhs in
                lhs.value.updatedAt < rhs.value.updatedAt
            }
        let activeTtys = Set(activeShells.compactMap { normalized($0.value.tty) })
        let inferredAttachedTmuxShell = attachedTmuxShell == nil ? allShells
            .filter { _, entry in
                guard let tmuxClientTty = normalized(entry.tmuxClientTty) else {
                    return false
                }
                return activeTtys.contains(tmuxClientTty)
            }
            .max(by: { $0.value.updatedAt < $1.value.updatedAt }) : nil
        let effectiveAttachedTmuxShell = attachedTmuxShell ?? inferredAttachedTmuxShell

        let tmuxClientTty = normalized(effectiveAttachedTmuxShell?.value.tmuxClientTty)
        let fallbackTarget = (effectiveAttachedTmuxShell.map { (pid: $0.key, entry: $0.value) } ?? mostRecentKnownUsable)
        let hasUsableActiveTarget = mostRecentActive.map { hasUsableRoutingTarget($0.entry) } ?? false
        let target: (pid: String, entry: ShellEntry)?
        let isUsingLastKnownTarget: Bool
        if hasUsableActiveTarget {
            target = mostRecentActive
            isUsingLastKnownTarget = false
        } else if let fallbackTarget {
            target = fallbackTarget
            isUsingLastKnownTarget = true
        } else if let mostRecentActive {
            target = mostRecentActive
            isUsingLastKnownTarget = false
        } else {
            target = mostRecentKnown
            isUsingLastKnownTarget = mostRecentKnown != nil
        }

        return ShellRoutingStatus(
            hasActiveShells: !activeShells.isEmpty,
            hasAttachedTmuxClient: effectiveAttachedTmuxShell != nil,
            hasAnyShells: !allShells.isEmpty,
            tmuxClientTty: tmuxClientTty,
            targetParentApp: target?.entry.parentApp,
            targetTmuxSession: target?.entry.tmuxSession,
            lastSeenAt: mostRecentKnown?.entry.updatedAt,
            isUsingLastKnownTarget: isUsingLastKnownTarget,
        )
    }

    private func activeShellEntries() -> [Dictionary<String, ShellEntry>.Element] {
        guard let shells = state?.shells else { return [] }
        let threshold = Date().addingTimeInterval(-Constants.shellStalenessThresholdSeconds)
        return shells.filter { $0.value.updatedAt > threshold }
    }

    static func shadowComparableDecision(from status: ShellRoutingStatus) -> (
        status: String, targetKind: String, targetValue: String?,
    ) {
        let targetKind: String
        let targetValue: String?
        if let tmuxSession = status.targetTmuxSession, !tmuxSession.isEmpty {
            targetKind = "tmux_session"
            targetValue = tmuxSession
        } else if let app = status.targetParentApp, !app.isEmpty, app.lowercased() != "unknown" {
            targetKind = "terminal_app"
            targetValue = app
        } else {
            targetKind = "none"
            targetValue = nil
        }

        let routingStatus = if status.hasAttachedTmuxClient {
            "attached"
        } else if status.hasAnyShells {
            "detached"
        } else {
            "unavailable"
        }

        return (routingStatus, targetKind, targetValue)
    }

    #if DEBUG
        /// Test-only helper for deterministic resolution.
        func setStateForTesting(_ state: ShellCwdState?) {
            self.state = state
        }
    #endif
}
