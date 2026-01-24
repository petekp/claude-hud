import Foundation

enum ActiveSource: Equatable {
    case claude(sessionId: String)
    case shell(pid: String, app: String?)
    case none
}

@MainActor
@Observable
final class ActiveProjectResolver {
    private let sessionStateManager: SessionStateManager
    private let shellStateStore: ShellStateStore

    private(set) var activeProject: Project?
    private(set) var activeSource: ActiveSource = .none

    private var projects: [Project] = []

    init(sessionStateManager: SessionStateManager, shellStateStore: ShellStateStore) {
        self.sessionStateManager = sessionStateManager
        self.shellStateStore = shellStateStore
    }

    func updateProjects(_ projects: [Project]) {
        self.projects = projects
    }

    func resolve() {
        // Priority 1: Shell CWD (terminal navigation is most immediate signal)
        if let (project, pid, app) = findActiveShellProject() {
            activeProject = project
            activeSource = .shell(pid: pid, app: app)
            return
        }

        // Priority 2: Most recent Claude session (fallback when not in a tracked project dir)
        if let (project, sessionId) = findActiveClaudeSession() {
            activeProject = project
            activeSource = .claude(sessionId: sessionId)
            return
        }

        activeProject = nil
        activeSource = .none
    }

    private func findActiveClaudeSession() -> (Project, String)? {
        var mostRecent: (Project, String, Date)?
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for project in projects {
            guard let sessionState = sessionStateManager.getSessionState(for: project),
                  sessionState.isLocked,
                  let sessionId = sessionState.sessionId else {
                continue
            }

            let stateChangedAt: Date
            if let dateStr = sessionState.stateChangedAt,
               let parsed = formatter.date(from: dateStr) {
                stateChangedAt = parsed
            } else {
                stateChangedAt = Date.distantPast
            }

            if mostRecent == nil || stateChangedAt > mostRecent!.2 {
                mostRecent = (project, sessionId, stateChangedAt)
            }
        }

        return mostRecent.map { ($0.0, $0.1) }
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
