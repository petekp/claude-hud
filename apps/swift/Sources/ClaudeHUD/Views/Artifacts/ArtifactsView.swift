import SwiftUI

struct ArtifactsView: View {
    @EnvironmentObject var appState: AppState

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
        .background(Color.hudBackground)
    }
}
