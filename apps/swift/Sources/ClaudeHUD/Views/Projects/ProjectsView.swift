import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if appState.isLoading {
                    ProgressView()
                        .padding(.top, 40)
                } else if appState.projects.isEmpty {
                    EmptyProjectsView()
                } else {
                    ForEach(appState.projects, id: \.path) { project in
                        ProjectCardView(
                            project: project,
                            sessionState: appState.getSessionState(for: project)
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.hudBackground)
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
