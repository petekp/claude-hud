import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject var appState: AppState
    let project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                Text(project.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                Text(project.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))

                if let sessionState = appState.getSessionState(for: project) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STATUS")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(.white.opacity(0.4))

                        StatusPillView(state: sessionState.state)

                        if let workingOn = sessionState.workingOn {
                            Text(workingOn)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.hudCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.hudBorder, lineWidth: 1)
                    )
                }

                Spacer()
            }
            .padding(16)
        }
        .background(Color.hudBackground)
    }
}
