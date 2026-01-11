import SwiftUI

struct CompactProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let isManuallyDormant: Bool
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToRecent: () -> Void

    @Environment(\.floatingMode) private var floatingMode
    @State private var isHovered = false
    @State private var isInfoHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.7))
                        .lineLimit(1)

                    Spacer()

                    Text(relativeTime(from: project.lastActive))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(isHovered ? 0.5 : 0.35))

                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(isInfoHovered ? 0.7 : 0.4))
                            .scaleEffect(isInfoHovered ? 1.1 : 1.0)
                            .rotationEffect(.degrees(isInfoHovered ? 10 : 0))
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                            isInfoHovered = hovering
                        }
                    }
                }

                if let workingOn = projectStatus?.workingOn ?? sessionState?.workingOn, !workingOn.isEmpty {
                    Text(workingOn)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if floatingMode {
                    floatingBackground
                } else {
                    solidBackground
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(
                color: isHovered ? .black.opacity(floatingMode ? 0.2 : 0.1) : .clear,
                radius: isHovered ? 6 : 0,
                y: isHovered ? 2 : 0
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
        }
        .buttonStyle(PressableButtonStyle(isPressed: $isPressed))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button(action: onTap) {
                Label("Open in Terminal", systemImage: "terminal")
            }
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            if isManuallyDormant {
                Divider()
                Button(action: onMoveToRecent) {
                    Label("Move to Recent", systemImage: "sun.max")
                }
            }
        }
    }

    @ViewBuilder
    private var floatingBackground: some View {
        if isHovered {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.15), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.25), .white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var solidBackground: some View {
        if isHovered {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.hudCard.opacity(0.6))

                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.12), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
        } else {
            Color.clear
        }
    }
}
