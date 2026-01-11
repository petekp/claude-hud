import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @State private var searchText = ""
    @State private var draggingProject: Project?

    private var orderedProjects: [Project] {
        appState.orderedProjects(appState.projects)
    }

    private var filteredProjects: [Project] {
        guard !searchText.isEmpty else { return orderedProjects }
        return orderedProjects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var recentProjects: [Project] {
        filteredProjects.filter { project in
            if appState.isManuallyDormant(project) {
                return false
            }
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
                    VStack(spacing: 8) {
                        SkeletonCard()
                        SkeletonCard()
                        SkeletonCard()
                    }
                    .padding(.top, 8)
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
                                devServerPort: appState.getDevServerPort(for: project),
                                onTap: {
                                    appState.launchTerminal(for: project)
                                },
                                onInfoTap: {
                                    appState.showProjectDetail(project)
                                },
                                onMoveToDormant: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        appState.moveToDormant(project)
                                    }
                                },
                                onOpenBrowser: {
                                    appState.openInBrowser(project)
                                }
                            )
                            .opacity(draggingProject?.path == project.path ? 0.5 : 1)
                            .draggable(project.path) {
                                ProjectCardDragPreview(project: project)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let droppedPath = items.first,
                                      let fromIndex = recentProjects.firstIndex(where: { $0.path == droppedPath }),
                                      let toIndex = recentProjects.firstIndex(where: { $0.path == project.path }) else {
                                    return false
                                }
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    appState.moveProject(from: IndexSet(integer: fromIndex), to: toIndex > fromIndex ? toIndex + 1 : toIndex, in: recentProjects)
                                }
                                return true
                            }
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
                                isManuallyDormant: appState.isManuallyDormant(project),
                                onTap: {
                                    appState.launchTerminal(for: project)
                                },
                                onInfoTap: {
                                    appState.showProjectDetail(project)
                                },
                                onMoveToRecent: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        appState.moveToRecent(project)
                                    }
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
        .background(floatingMode ? Color.clear : Color.hudBackground)
    }
}

struct SectionHeader: View {
    let title: String
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.sectionAccent)
                .frame(width: 5, height: 5)
                .shadow(color: Color.sectionAccent.opacity(0.5), radius: 3)
                .scaleEffect(appeared ? 1.0 : 0.0)

            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(2)
                .foregroundColor(.white.opacity(0.5))

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.sectionAccent.opacity(0.4), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .scaleEffect(x: appeared ? 1.0 : 0.0, anchor: .leading)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1)) {
                appeared = true
            }
        }
    }
}

struct EmptyProjectsView: View {
    @EnvironmentObject var appState: AppState
    @State private var appeared = false
    @State private var isButtonHovered = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.hudAccent.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .blur(radius: 20)
                    .scaleEffect(appeared ? 1.0 : 0.5)
                    .opacity(appeared ? 1 : 0)

                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.5), .white.opacity(0.25)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .scaleEffect(appeared ? 1.0 : 0.8)
                    .opacity(appeared ? 1 : 0)
            }

            VStack(spacing: 6) {
                Text("No projects yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Text("Pin your first project to start tracking")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)

            Button(action: { appState.showAddProject() }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Add Project")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white.opacity(isButtonHovered ? 1 : 0.9))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [
                            Color.hudAccent.opacity(isButtonHovered ? 0.9 : 0.7),
                            Color.hudAccentDark.opacity(isButtonHovered ? 0.8 : 0.6)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isButtonHovered ? 0.2 : 0.1), lineWidth: 0.5)
                )
                .shadow(color: Color.hudAccent.opacity(isButtonHovered ? 0.4 : 0.2), radius: isButtonHovered ? 10 : 4, y: 2)
                .scaleEffect(isButtonHovered ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    isButtonHovered = hovering
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 15)
        }
        .padding(.top, 50)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool
    @State private var isClearHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(isFocused ? 0.6 : 0.4))
                .scaleEffect(isFocused ? 1.05 : 1.0)

            TextField("Search projects...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .focused($isFocused)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(isClearHovered ? 0.7 : 0.4))
                        .scaleEffect(isClearHovered ? 1.1 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.spring(response: 0.2)) {
                        isClearHovered = hovering
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(isFocused ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isFocused
                        ? Color.hudAccent.opacity(0.5)
                        : Color.white.opacity(0.08),
                    lineWidth: isFocused ? 1 : 0.5
                )
        )
        .shadow(color: isFocused ? Color.hudAccent.opacity(0.15) : .clear, radius: 6, y: 0)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }
}

struct ProjectCardDragPreview: View {
    let project: Project

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Text(project.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.hudCard)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.hudAccent.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}
