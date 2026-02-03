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

    private(set) var sessionStates: [String: ProjectSessionState] = [:]
    private(set) var flashingProjects: [String: SessionState] = [:]
    private var previousSessionStates: [String: SessionState] = [:]

    private let daemonClient = DaemonClient.shared
    private var daemonRefreshTask: _Concurrency.Task<Void, Never>?

    // MARK: - Refresh

    func refreshSessionStates(for projects: [Project]) {
        let daemonEnabled = daemonClient.isEnabled
        DebugLog.write("SessionStateManager.refresh daemonEnabled=\(daemonEnabled) projects=\(projects.count)")

        guard daemonEnabled else {
            DebugLog.write("SessionStateManager.refresh daemonEnabled=false clearingStates")
            sessionStates = [:]
            pruneCachedStates()
            return
        }

        // Daemon is the single source of truth. Keep prior state until refreshed
        // to avoid flicker if the daemon request is delayed.
        DebugLog.write("SessionStateManager.refresh daemonEnabled=true existingStates=\(sessionStates.count)")
        checkForStateChanges()

        daemonRefreshTask?.cancel()
        daemonRefreshTask = _Concurrency.Task.detached { [weak self] in
            guard let self else { return }
            do {
                let daemonProjects = try await daemonClient.fetchProjectStates()
                await MainActor.run {
                    DebugLog.write("SessionStateManager.fetchProjectStates success count=\(daemonProjects.count)")
                    let merged = self.mergeDaemonProjectStates(daemonProjects, projects: projects)
                    if !merged.isEmpty {
                        let summary = merged
                            .map { "\($0.key) state=\($0.value.state) updated=\($0.value.updatedAt ?? "nil") session=\($0.value.sessionId ?? "nil")" }
                            .sorted()
                            .joined(separator: " | ")
                        DebugLog.write("SessionStateManager.merge summary=\(summary)")
                    } else {
                        DebugLog.write("SessionStateManager.merge summary=empty")
                    }
                    self.sessionStates = merged
                    self.pruneCachedStates()
                    self.checkForStateChanges()
                }
            } catch {
                await MainActor.run {
                    DebugLog.write("SessionStateManager.fetchProjectStates error=\(error)")
                }
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

    private func pruneCachedStates() {
        let active = Set(sessionStates.keys)
        previousSessionStates = previousSessionStates.filter { active.contains($0.key) }
        flashingProjects = flashingProjects.filter { active.contains($0.key) }
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

    private func mergeDaemonProjectStates(
        _ states: [DaemonProjectState],
        projects: [Project]
    ) -> [String: ProjectSessionState] {
        var merged: [String: ProjectSessionState] = [:]
        let projectLookup = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0) })
        if !states.isEmpty {
            let unmatched = states.filter { projectLookup[$0.projectPath] == nil }
            if !unmatched.isEmpty {
                let sample = unmatched.prefix(3).map { "\($0.projectPath) [\($0.state)]" }.joined(separator: ", ")
                DebugLog.write("SessionStateManager.mergeDaemonProjectStates unmatched=\(unmatched.count) sample=\(sample)")
            }
        }

        for state in states {
            let projectPath = state.projectPath
            guard projectLookup[projectPath] != nil else { continue }
            let mappedState = mapDaemonState(state.state)
            let sessionState = ProjectSessionState(
                state: mappedState,
                stateChangedAt: state.stateChangedAt,
                updatedAt: state.updatedAt,
                sessionId: state.sessionId,
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: state.hasSession
            )
            merged[projectPath] = sessionState
        }

        return merged
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
