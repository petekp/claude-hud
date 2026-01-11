import SwiftUI

struct ArtifactsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if appState.isLoading {
                    ProgressView()
                        .padding(.top, 40)
                } else {
                    Text("Artifacts view coming soon")
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 40)
                }
            }
            .padding()
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
    }
}
