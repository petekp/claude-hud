import Foundation
import SwiftUI

enum Tab: String, CaseIterable {
    case projects
    case artifacts
}

enum ProjectView: Equatable {
    case list
    case detail(Project)
    case add

    static func == (lhs: ProjectView, rhs: ProjectView) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list), (.add, .add):
            return true
        case let (.detail(p1), .detail(p2)):
            return p1.path == p2.path
        default:
            return false
        }
    }
}

@MainActor
class AppState: ObservableObject {
    // Navigation
    @Published var activeTab: Tab = .projects
    @Published var projectView: ProjectView = .list
    @Published var selectedProject: Project?

    // Data
    @Published var dashboard: DashboardData?
    @Published var sessionStates: [String: ProjectSessionState] = [:]
    @Published var projectStatuses: [String: ProjectStatus] = [:]
    @Published var artifacts: [Artifact] = []
    @Published var projects: [Project] = []

    // UI State
    @Published var isLoading = true
    @Published var error: String?
    @Published var alwaysOnTop = false
    @Published var flashingProjects: [String: SessionState] = [:]

    // Internal state tracking (non-published)
    private var previousSessionStates: [String: SessionState] = [:]

    // Rust bridge
    private var engine: HudEngine?

    init() {
        do {
            engine = try HudEngine()
            loadDashboard()
        } catch {
            self.error = error.localizedDescription
            self.isLoading = false
        }
    }

    func loadDashboard() {
        guard let engine = engine else { return }
        isLoading = true

        do {
            dashboard = try engine.loadDashboard()
            projects = dashboard?.projects ?? []
            refreshSessionStates()
            refreshProjectStatuses()
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func refreshSessionStates() {
        guard let engine = engine else { return }
        sessionStates = engine.getAllSessionStates(projects: projects)
        checkForStateChanges()
    }

    private func checkForStateChanges() {
        for (path, sessionState) in sessionStates {
            let current = sessionState.state
            if let previous = previousSessionStates[path], previous != current {
                switch current {
                case .ready, .waiting, .compacting:
                    flashingProjects[path] = current
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                        self?.flashingProjects.removeValue(forKey: path)
                    }
                case .working, .idle:
                    break
                }
            }
            previousSessionStates[path] = current
        }
    }

    func isFlashing(_ project: Project) -> SessionState? {
        flashingProjects[project.path]
    }

    func refreshProjectStatuses() {
        guard let engine = engine else { return }
        for project in projects {
            if let status = engine.getProjectStatus(projectPath: project.path) {
                projectStatuses[project.path] = status
            }
        }
    }

    func getProjectStatus(for project: Project) -> ProjectStatus? {
        projectStatuses[project.path]
    }

    func addProject(_ path: String) {
        guard let engine = engine else { return }
        do {
            try engine.addProject(path: path)
            loadDashboard()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeProject(_ path: String) {
        guard let engine = engine else { return }
        do {
            try engine.removeProject(path: path)
            loadDashboard()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func getSessionState(for project: Project) -> ProjectSessionState? {
        sessionStates[project.path]
    }

    func launchTerminal(for project: Project) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            SESSION="\(project.name)"

            # Check if session already exists
            if tmux has-session -t "$SESSION" 2>/dev/null; then
                # Session exists - just switch to it
                tmux switch-client -t "$SESSION" 2>/dev/null || true
            else
                # Create new session
                tmux new-session -d -s "$SESSION" -c "\(project.path)"
                tmux switch-client -t "$SESSION" 2>/dev/null || true
            fi

            # Activate whichever terminal app is running tmux
            # Check common terminal apps in order of likelihood
            if pgrep -xq "iTerm2"; then
                osascript -e 'tell application "iTerm" to activate'
            elif pgrep -xq "WarpTerminal"; then
                osascript -e 'tell application "Warp" to activate'
            elif pgrep -xq "Alacritty"; then
                osascript -e 'tell application "Alacritty" to activate'
            elif pgrep -xq "kitty"; then
                osascript -e 'tell application "kitty" to activate'
            elif pgrep -xq "Terminal"; then
                osascript -e 'tell application "Terminal" to activate'
            fi
        """]
        try? process.run()
    }

    func showProjectDetail(_ project: Project) {
        selectedProject = project
        projectView = .detail(project)
    }

    func showProjectList() {
        selectedProject = nil
        projectView = .list
    }
}
