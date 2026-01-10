import SwiftUI

struct HeaderView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            TabButton(
                title: "Projects",
                count: appState.projects.count,
                isActive: appState.activeTab == .projects
            ) {
                appState.activeTab = .projects
            }

            TabButton(
                title: "Artifacts",
                count: appState.artifacts.count,
                isActive: appState.activeTab == .artifacts
            ) {
                appState.activeTab = .artifacts
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.hudBackground)
    }
}

struct TabButton: View {
    let title: String
    let count: Int
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .medium))

                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isActive ? Color.hudAccent.opacity(0.2) : Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.6))
        }
        .buttonStyle(.plain)
    }
}
