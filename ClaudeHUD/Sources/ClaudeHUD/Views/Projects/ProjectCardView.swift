import SwiftUI

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if let state = sessionState {
                    StatusPillView(state: state.state)
                }
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
        }
        .padding(12)
        .background(Color.hudCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.hudBorder, lineWidth: 1)
        )
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
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

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
