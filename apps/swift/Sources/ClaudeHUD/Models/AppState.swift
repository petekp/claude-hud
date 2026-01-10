import Foundation
import SwiftUI

enum Tab: String, CaseIterable {
    case projects
    case artifacts
}

@MainActor
class AppState: ObservableObject {
    // Navigation
    @Published var activeTab: Tab = .projects
    @Published var selectedProject: Project?

    // Data
    @Published var dashboard: DashboardData?
    @Published var sessionStates: [String: ProjectSessionState] = [:]
    @Published var artifacts: [Artifact] = []
    @Published var projects: [Project] = []

    // UI State
    @Published var isLoading = true
    @Published var error: String?
    @Published var alwaysOnTop = false

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
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func refreshSessionStates() {
        guard let engine = engine else { return }
        sessionStates = engine.getAllSessionStates(projects: projects)
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
}
