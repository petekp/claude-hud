import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            Divider()

            Group {
                switch appState.activeTab {
                case .projects:
                    switch appState.projectView {
                    case .list:
                        ProjectsView()
                    case .detail(let project):
                        ProjectDetailView(project: project)
                    case .add:
                        AddProjectView()
                    }
                case .artifacts:
                    ArtifactsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.hudBackground)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
