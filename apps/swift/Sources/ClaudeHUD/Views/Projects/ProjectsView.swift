import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""

    private var filteredProjects: [Project] {
        guard !searchText.isEmpty else { return appState.projects }
        return appState.projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var recentProjects: [Project] {
        filteredProjects.filter { project in
            let state = appState.getSessionState(for: project)
            if let s = state?.state {
                switch s {
                case .working, .ready, .compacting, .waiting:
                    return true
                case .idle:
                    break
                }
            }
            if let stateChangedAt = state?.stateChangedAt,
               let date = ISO8601DateFormatter().date(from: stateChangedAt),
               Date().timeIntervalSince(date) < 86400 {
                return true
            }
            if let lastActive = project.lastActive,
               let date = ISO8601DateFormatter().date(from: lastActive),
               Date().timeIntervalSince(date) < 86400 {
                return true
            }
            return false
        }
    }

    private var dormantProjects: [Project] {
        filteredProjects.filter { project in
            !recentProjects.contains { $0.path == project.path }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if appState.isLoading {
                    ProgressView()
                        .padding(.top, 40)
                } else if appState.projects.isEmpty {
                    EmptyProjectsView()
                } else {
                    if appState.projects.count > 3 {
                        SearchField(text: $searchText)
                            .padding(.bottom, 4)
                    }

                    if !searchText.isEmpty && recentProjects.isEmpty && dormantProjects.isEmpty {
                        Text("No projects match \"\(searchText)\"")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.top, 20)
                    }
                    if !recentProjects.isEmpty {
                        SectionHeader(title: "RECENT")
                            .padding(.top, 4)
                            .transition(.opacity)

                        ForEach(Array(recentProjects.enumerated()), id: \.element.path) { index, project in
                            ProjectCardView(
                                project: project,
                                sessionState: appState.getSessionState(for: project),
                                projectStatus: appState.getProjectStatus(for: project),
                                flashState: appState.isFlashing(project),
                                onTap: {
                                    appState.launchTerminal(for: project)
                                },
                                onInfoTap: {
                                    appState.showProjectDetail(project)
                                }
                            )
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            ))
                            .animation(
                                .spring(response: 0.4, dampingFraction: 0.8)
                                .delay(Double(index) * 0.03),
                                value: recentProjects.count
                            )
                        }
                    }

                    if !dormantProjects.isEmpty {
                        SectionHeader(title: recentProjects.isEmpty ? "PROJECTS" : "DORMANT (\(dormantProjects.count))")
                            .padding(.top, recentProjects.isEmpty ? 4 : 12)
                            .transition(.opacity)

                        ForEach(Array(dormantProjects.enumerated()), id: \.element.path) { index, project in
                            CompactProjectCardView(
                                project: project,
                                sessionState: appState.getSessionState(for: project),
                                projectStatus: appState.getProjectStatus(for: project),
                                onTap: {
                                    appState.launchTerminal(for: project)
                                },
                                onInfoTap: {
                                    appState.showProjectDetail(project)
                                }
                            )
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            ))
                            .animation(
                                .spring(response: 0.4, dampingFraction: 0.8)
                                .delay(Double(recentProjects.count + index) * 0.03),
                                value: dormantProjects.count
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.hudBackground)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(.white.opacity(0.4))

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
        }
    }
}

struct EmptyProjectsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))

            Text("No projects pinned")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            Text("Add projects from Add Project panel")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.top, 60)
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))

            TextField("Search projects...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
