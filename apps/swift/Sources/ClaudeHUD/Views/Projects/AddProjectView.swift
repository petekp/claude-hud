import SwiftUI

struct AddProjectView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button(action: { appState.showProjectList() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.3))

                Text("Add Project")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))

                Text("Coming soon")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.3))
            }

            Spacer()
        }
        .background(Color.hudBackground)
    }
}
