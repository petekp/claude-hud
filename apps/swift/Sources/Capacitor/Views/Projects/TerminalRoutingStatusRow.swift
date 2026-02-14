import SwiftUI

enum TerminalRoutingStatusCopy {
    struct AERRoutingPresentation: Equatable {
        let tmuxSummary: String
        let targetSummary: String
        let tooltip: String
        let isAttached: Bool
    }

    private static let tooltipDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss z"
        return formatter
    }()

    static func targetSummary(_ status: ShellRoutingStatus) -> String {
        let targetPrefix = status.isUsingLastKnownTarget ? "last target" : "target"
        if let session = status.targetTmuxSession, !session.isEmpty {
            return "\(targetPrefix) tmux:\(session)"
        }
        if let parent = status.targetParentApp, !parent.isEmpty {
            return "\(targetPrefix) \(parent)"
        }
        if status.hasAnyShells {
            return "last target unknown"
        }
        return "target unknown"
    }

    static func tmuxSummary(_ status: ShellRoutingStatus, referenceDate: Date = Date()) -> String {
        if status.hasAttachedTmuxClient {
            if let tty = status.tmuxClientTty {
                return "tmux attached (\(tty))"
            }
            return "tmux attached"
        }
        if status.hasActiveShells {
            return "tmux detached"
        }
        if status.hasStaleTelemetry {
            let staleLabel = targetsTmux(status) ? "tmux telemetry stale" : "shell telemetry stale"
            if let ageMinutes = status.staleAgeMinutes(reference: referenceDate) {
                return "\(staleLabel) (\(ageMinutes)m ago)"
            }
            return staleLabel
        }
        return "no shell telemetry"
    }

    static func tooltip(_ status: ShellRoutingStatus, referenceDate: Date = Date()) -> String {
        if status.hasAttachedTmuxClient {
            if let tty = status.tmuxClientTty {
                return "Live tmux client attached on \(tty)."
            }
            return "Live tmux client attached."
        }

        if status.hasActiveShells {
            return "Live shell telemetry is available. No attached tmux client detected."
        }

        if status.hasStaleTelemetry {
            let age = status.staleAgeMinutes(reference: referenceDate)
                .map { "\($0)m ago" } ?? "an unknown time ago"
            let timestamp = status.lastSeenAt
                .map { tooltipDateFormatter.string(from: $0) } ?? "unknown"
            return "Telemetry is stale (last update \(age), \(timestamp)). Showing the last known target."
        }

        return "No shell telemetry detected yet."
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

    private static func targetsTmux(_ status: ShellRoutingStatus) -> Bool {
        if let session = status.targetTmuxSession, !session.isEmpty {
            return true
        }
        if let parent = status.targetParentApp?.lowercased(), parent == "tmux" {
            return true
        }
        return false
    }
}

struct TerminalRoutingStatusRow: View {
    @Environment(AppState.self) private var appState

    private var status: ShellRoutingStatus {
        appState.shellStateStore.routingStatus
    }

    private var arePresentation: TerminalRoutingStatusCopy.AERRoutingPresentation? {
        guard appState.featureFlags.areStatusRow,
              let snapshot = appState.shellStateStore.areRoutingSnapshot
        else {
            return nil
        }
        return TerminalRoutingStatusCopy.arePresentation(snapshot)
    }

    private var targetSummary: String {
        if let arePresentation {
            return arePresentation.targetSummary
        }
        return TerminalRoutingStatusCopy.targetSummary(status)
    }

    private var tmuxSummary: String {
        if let arePresentation {
            return arePresentation.tmuxSummary
        }
        return TerminalRoutingStatusCopy.tmuxSummary(status)
    }

    private var tooltipText: String {
        if let arePresentation {
            return arePresentation.tooltip
        }
        return TerminalRoutingStatusCopy.tooltip(status)
    }

    private var accentColor: Color {
        if let arePresentation {
            return arePresentation.isAttached ? .statusReady : .statusWaiting
        }
        return status.hasAttachedTmuxClient ? .statusReady : .statusWaiting
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
        .help(tooltipText)
    }
}
