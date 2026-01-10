import SwiftUI

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let onTap: () -> Void
    let onInfoTap: () -> Void

    @State private var isHovered = false
    @State private var flashOpacity: Double = 0

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    if let state = sessionState {
                        StatusPillView(state: state.state)
                    }

                    Button(action: {
                        onInfoTap()
                    }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(isHovered ? 0.6 : 0.3))
                    }
                    .buttonStyle(.plain)
                    .help("View details")
                }

                if let displayPath = project.displayPath.split(separator: "/").dropFirst().joined(separator: "/") as String?, !displayPath.isEmpty {
                    Text(displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }

                if let workingOn = sessionState?.workingOn, !workingOn.isEmpty {
                    Text(workingOn)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }

                if let blocker = projectStatus?.blocker, !blocker.isEmpty {
                    Text(blocker)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
                        .lineLimit(1)
                }
            }
            .padding(12)
            .background(Color.hudCard)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? Color.white.opacity(0.15) : Color.hudBorder, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(flashState.map { Color.flashColor(for: $0) } ?? .clear, lineWidth: 2)
                    .opacity(flashOpacity)
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isHovered ? Color.hudAccent.opacity(0.5) : Color.white.opacity(0.15))
                    .frame(width: 2)
                    .padding(.vertical, 12)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: flashState) { oldValue, newValue in
            if newValue != nil {
                withAnimation(.easeOut(duration: 0.1)) {
                    flashOpacity = 1.0
                }
                withAnimation(.easeOut(duration: 1.3).delay(0.1)) {
                    flashOpacity = 0
                }
            }
        }
    }
}

struct StatusPillView: View {
    let state: SessionState

    var statusColor: Color {
        switch state {
        case .ready:
            return .statusReady
        case .working:
            return .statusWorking
        case .waiting:
            return .statusWaiting
        case .compacting:
            return .statusCompacting
        case .idle:
            return .statusIdle
        }
    }

    var statusText: String {
        switch state {
        case .ready:
            return "Ready"
        case .working:
            return "Working"
        case .waiting:
            return "Waiting"
        case .compacting:
            return "Compacting"
        case .idle:
            return "Idle"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            BreathingDot(color: statusColor)

            Text(statusText)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.15))
        .clipShape(Capsule())
    }
}
