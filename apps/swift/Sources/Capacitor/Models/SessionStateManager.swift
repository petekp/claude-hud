import Foundation

/// Manages session state display for projects.
///
/// This is a "dumb" client that:
/// - Caches states from the Rust engine
/// - Detects state changes for flash animations
/// - Provides state to views (direct passthrough)
///
/// All state logic (staleness, lock detection, resolution) lives in Rust.
@MainActor
final class SessionStateManager {
    private enum Constants {
        static let flashDurationSeconds: TimeInterval = 1.4
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private(set) var sessionStates: [String: ProjectSessionState] = [:]
    private(set) var flashingProjects: [String: SessionState] = [:]
    private var previousSessionStates: [String: SessionState] = [:]

    private let daemonClient = DaemonClient.shared
    private var daemonRefreshTask: _Concurrency.Task<Void, Never>?

    private weak var engine: HudEngine?

    func configure(engine: HudEngine?) {
        self.engine = engine
    }

    // MARK: - Refresh

    func refreshSessionStates(for projects: [Project]) {
        guard let engine else { return }

        // Direct passthrough from Rust - no client-side transformation
        sessionStates = engine.getAllSessionStates(projects: projects)
        checkForStateChanges()

        guard daemonClient.isEnabled else { return }

        daemonRefreshTask?.cancel()
        daemonRefreshTask = _Concurrency.Task.detached { [weak self] in
            guard let self else { return }
            do {
                let daemonSessions = try await daemonClient.fetchSessions()
                await MainActor.run {
                    let merged = self.mergeDaemonSessions(daemonSessions, projects: projects)
                    self.sessionStates = merged
                    self.checkForStateChanges()
                }
            } catch {
                return
            }
        }
    }

    // MARK: - Flash Animation

    private func checkForStateChanges() {
        for (path, sessionState) in sessionStates {
            let current = sessionState.state
            if let previous = previousSessionStates[path], previous != current {
                triggerFlashIfNeeded(for: path, state: current)
            }
            previousSessionStates[path] = current
        }
    }

    private func triggerFlashIfNeeded(for path: String, state: SessionState) {
        switch state {
        case .ready, .waiting, .compacting:
            flashingProjects[path] = state
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.flashDurationSeconds) { [weak self] in
                self?.flashingProjects.removeValue(forKey: path)
            }
        case .working, .idle:
            break
        }
    }

    func isFlashing(_ project: Project) -> SessionState? {
        flashingProjects[project.path]
    }

    // MARK: - State Retrieval

    func getSessionState(for project: Project) -> ProjectSessionState? {
        sessionStates[project.path]
    }

    private func mergeDaemonSessions(
        _ sessions: [DaemonSession],
        projects: [Project]
    ) -> [String: ProjectSessionState] {
        var merged = sessionStates
        let projectLookup = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0) })

        var latestByProject: [String: DaemonSession] = [:]
        for session in sessions {
            guard projectLookup[session.projectPath] != nil else { continue }
            if let existing = latestByProject[session.projectPath] {
                if compareSessionRecency(lhs: session, rhs: existing) {
                    latestByProject[session.projectPath] = session
                }
            } else {
                latestByProject[session.projectPath] = session
            }
        }

        for (projectPath, session) in latestByProject {
            let state = mapDaemonState(session.state)
            // Use daemon's is_alive field for liveness detection.
            // If is_alive is nil (unknown pid), fall back to state-based heuristic.
            // If is_alive is false (process dead), session is not locked.
            let isLocked: Bool
            if let isAlive = session.isAlive {
                isLocked = isAlive && state != .idle
            } else {
                // Fallback: unknown liveness, use state heuristic
                isLocked = state != .idle
            }
            let sessionState = ProjectSessionState(
                state: state,
                stateChangedAt: session.stateChangedAt,
                updatedAt: session.updatedAt,
                sessionId: session.sessionId,
                workingOn: nil,
                context: nil,
                thinking: nil,
                isLocked: isLocked
            )
            merged[projectPath] = sessionState
        }

        return merged
    }

    private func compareSessionRecency(
        lhs: DaemonSession,
        rhs: DaemonSession
    ) -> Bool {
        let lhsDate = parseDaemonDate(lhs.updatedAt)
            ?? parseDaemonDate(lhs.stateChangedAt)
            ?? Date.distantPast
        let rhsDate = parseDaemonDate(rhs.updatedAt)
            ?? parseDaemonDate(rhs.stateChangedAt)
            ?? Date.distantPast
        return lhsDate > rhsDate
    }

    private func parseDaemonDate(_ value: String) -> Date? {
        Self.fractionalFormatter.date(from: value) ?? Self.plainFormatter.date(from: value)
    }

    private func mapDaemonState(_ state: String) -> SessionState {
        switch state.lowercased() {
        case "working":
            return .working
        case "ready":
            return .ready
        case "compacting":
            return .compacting
        case "waiting":
            return .waiting
        case "idle":
            return .idle
        default:
            return .idle
        }
    }
}
