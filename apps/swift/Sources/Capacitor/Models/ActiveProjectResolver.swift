import Foundation

// MARK: - Active Source

enum ActiveSource: Equatable {
    case claude(sessionId: String)
    case shell(pid: String, app: String?)
    case none
}

// MARK: - Active Project Resolver

@MainActor
@Observable
final class ActiveProjectResolver {
    private let sessionStateManager: SessionStateManager
    private let shellStateStore: ShellStateStore

    private(set) var activeProject: Project?
    private(set) var activeSource: ActiveSource = .none

    private var projects: [Project] = []
    private var manualOverride: Project?

    init(sessionStateManager: SessionStateManager, shellStateStore: ShellStateStore) {
        self.sessionStateManager = sessionStateManager
        self.shellStateStore = shellStateStore
    }

    // MARK: - Public API

    func updateProjects(_ projects: [Project]) {
        self.projects = projects
    }

    /// Set a manual override for the active project.
    /// The override persists until the user clicks on a different project
    /// or the overridden project's session ends.
    func setManualOverride(_ project: Project) {
        manualOverride = project
    }

    func resolve() {
        // Priority 0: Manual override (from clicking a project)
        // Persists until user clicks a different project.
        // This prevents auto-switching between multiple active sessions.
        if let override = manualOverride {
            // If the override project has an active session, use it
            if let sessionState = sessionStateManager.getSessionState(for: override),
               sessionState.isLocked {
                activeProject = override
                activeSource = .none
                return
            }
            // No active session for override project - still honor the override
            // but show as "manual" source. This lets users pin a project even without
            // an active session. Override clears when user clicks different project.
            activeProject = override
            activeSource = .none
            return
        }

        // Priority 1: Most recent Claude session (accurate timestamps from hook events)
        // Claude sessions update their timestamp on every hook event, making them
        // the most reliable signal for which project is actively being worked on.
        if let (project, sessionId) = findActiveClaudeSession() {
            activeProject = project
            activeSource = .claude(sessionId: sessionId)
            return
        }

        // Priority 2: Shell CWD (fallback when no Claude sessions are running)
        // Shell timestamps only update on prompt display, which doesn't happen
        // during long-running Claude sessions.
        if let (project, pid, app) = findActiveShellProject() {
            activeProject = project
            activeSource = .shell(pid: pid, app: app)
            return
        }

        activeProject = nil
        activeSource = .none
    }

    // MARK: - Private Resolution

    private func findActiveClaudeSession() -> (Project, String)? {
        var activeSessions: [(Project, String, Date)] = []
        var readySessions: [(Project, String, Date)] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for project in projects {
            guard let sessionState = sessionStateManager.getSessionState(for: project),
                  sessionState.isLocked,
                  let sessionId = sessionState.sessionId else {
                continue
            }

            // Use updated_at (updates on every hook event) for accurate activity tracking.
            // Falls back to stateChangedAt, then Date.distantPast.
            let updatedAt: Date
            if let dateStr = sessionState.updatedAt,
               let parsed = formatter.date(from: dateStr) {
                updatedAt = parsed
            } else if let dateStr = sessionState.stateChangedAt,
                      let parsed = formatter.date(from: dateStr) {
                updatedAt = parsed
            } else {
                updatedAt = Date.distantPast
            }

            // Separate active (Working/Waiting/Compacting) from passive (Ready) sessions.
            // Active sessions always take priority - a session you're using shouldn't
            // lose focus to one that just finished.
            let isActive = sessionState.state == .working ||
                           sessionState.state == .waiting ||
                           sessionState.state == .compacting

            if isActive {
                activeSessions.append((project, sessionId, updatedAt))
            } else {
                readySessions.append((project, sessionId, updatedAt))
            }
        }

        // Prefer active sessions over ready sessions, then sort by recency
        let candidates = activeSessions.isEmpty ? readySessions : activeSessions
        return candidates.max(by: { $0.2 < $1.2 }).map { ($0.0, $0.1) }
    }

    private func findActiveShellProject() -> (Project, String, String?)? {
        guard let (pid, shell) = shellStateStore.mostRecentShell else {
            return nil
        }

        guard let project = projectContaining(path: shell.cwd) else {
            return nil
        }

        return (project, pid, shell.parentApp)
    }

    private func projectContaining(path: String) -> Project? {
        for project in projects {
            if path == project.path || path.hasPrefix(project.path + "/") {
                return project
            }
        }
        return nil
    }
}
