import SwiftUI

enum TerminalRoutingStatusCopy {
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

    private var targetSummary: String {
        TerminalRoutingStatusCopy.targetSummary(status)
    }

    private var tmuxSummary: String {
        TerminalRoutingStatusCopy.tmuxSummary(status)
    }

    private var tooltipText: String {
        TerminalRoutingStatusCopy.tooltip(status)
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
        .help(tooltipText)
    }
}
