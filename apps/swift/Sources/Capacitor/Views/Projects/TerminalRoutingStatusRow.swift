import SwiftUI

enum TerminalRoutingStatusCopy {
    struct AERRoutingPresentation: Equatable {
        let tmuxSummary: String
        let targetSummary: String
        let tooltip: String
        let isAttached: Bool
    }

    static func arePresentation(_ snapshot: DaemonRoutingSnapshot) -> AERRoutingPresentation {
        let targetSummary = switch snapshot.target.kind {
        case "tmux_session":
            if let value = snapshot.target.value, !value.isEmpty {
                "target tmux:\(value)"
            } else {
                "target tmux"
            }
        case "terminal_app":
            if let value = snapshot.target.value, !value.isEmpty {
                "target \(value)"
            } else {
                "target terminal"
            }
        default:
            "target unknown"
        }

        let tmuxSummary = switch snapshot.status {
        case "attached":
            "tmux attached"
        case "detached":
            "tmux detached"
        default:
            "routing unavailable"
        }

        let tooltip = areTooltip(reasonCode: snapshot.reasonCode)
        return AERRoutingPresentation(
            tmuxSummary: tmuxSummary,
            targetSummary: targetSummary,
            tooltip: tooltip,
            isAttached: snapshot.status == "attached",
        )
    }

    static func unavailablePresentation() -> AERRoutingPresentation {
        AERRoutingPresentation(
            tmuxSummary: "routing unavailable",
            targetSummary: "target unknown",
            tooltip: "Routing snapshot unavailable.",
            isAttached: false,
        )
    }

    private static func areTooltip(reasonCode: String) -> String {
        switch reasonCode {
        case "TMUX_CLIENT_ATTACHED":
            "Attached tmux client detected for this workspace."
        case "TMUX_SESSION_DETACHED":
            "Tmux session exists but no attached tmux client is active."
        case "SHELL_FALLBACK_ACTIVE":
            "Using fresh shell telemetry fallback for routing."
        case "SHELL_FALLBACK_STALE":
            "Using stale shell telemetry fallback; routing confidence is reduced."
        case "ROUTING_SCOPE_AMBIGUOUS":
            "Workspace scope is ambiguous across candidate routing targets."
        case "ROUTING_CONFLICT_DETECTED":
            "Conflicting routing candidates were detected; deterministic tie-breakers were applied."
        case "NO_TRUSTED_EVIDENCE":
            "No trusted routing evidence is currently available."
        case "PROCESS_IDENTITY_MISMATCH":
            "Process identity mismatch detected between routing signals."
        default:
            "Routing status is available."
        }
    }
}

struct TerminalRoutingStatusRow: View {
    @Environment(AppState.self) private var appState

    private var presentation: TerminalRoutingStatusCopy.AERRoutingPresentation {
        if let snapshot = appState.shellStateStore.areRoutingSnapshot {
            return TerminalRoutingStatusCopy.arePresentation(snapshot)
        }
        return TerminalRoutingStatusCopy.unavailablePresentation()
    }

    private var accentColor: Color {
        presentation.isAttached ? .statusReady : .statusWaiting
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accentColor)
                .frame(width: 7, height: 7)

            Text("\(presentation.tmuxSummary) · \(presentation.targetSummary)")
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
        .accessibilityLabel("\(presentation.tmuxSummary), \(presentation.targetSummary)")
        .help(presentation.tooltip)
    }
}
