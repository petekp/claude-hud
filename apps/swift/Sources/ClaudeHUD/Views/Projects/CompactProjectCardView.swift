import SwiftUI

struct CompactProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let isManuallyDormant: Bool
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToRecent: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onMoveToRecent) {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(isHovered ? 0.8 : 0.5))
                    .lineLimit(1)

                Spacer()

                Text(relativeTime(from: project.lastActive))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(isHovered ? 0.4 : 0.25))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
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
        }
    }
}
