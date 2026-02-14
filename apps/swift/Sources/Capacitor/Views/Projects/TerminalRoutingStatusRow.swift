import SwiftUI

struct TerminalRoutingStatusRow: View {
    @Environment(AppState.self) private var appState

    private var status: ShellRoutingStatus {
        appState.shellStateStore.routingStatus
    }

    private var targetSummary: String {
        if let session = status.targetTmuxSession, !session.isEmpty {
            return "target tmux:\(session)"
        }
        if let parent = status.targetParentApp, !parent.isEmpty {
            return "target \(parent)"
        }
        return "target unknown"
    }

    private var tmuxSummary: String {
        if status.hasAttachedTmuxClient {
            if let tty = status.tmuxClientTty {
                return "tmux attached (\(tty))"
            }
            return "tmux attached"
        }
        if status.hasActiveShells {
            return "tmux detached"
        }
        return "no live shell telemetry"
    }

    private var accentColor: Color {
        status.hasAttachedTmuxClient ? .statusReady : .statusWaiting
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accentColor)
                .frame(width: 7, height: 7)

            Text("\(tmuxSummary) · \(targetSummary)")
                .font(AppTypography.captionSmall)
                .foregroundColor(.white.opacity(0.62))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.045)),
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tmuxSummary), \(targetSummary)")
    }
}
