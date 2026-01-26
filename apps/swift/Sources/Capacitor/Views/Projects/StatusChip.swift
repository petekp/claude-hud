import SwiftUI

/// Combines the animated StatusIndicator with recency for quick scanning.
/// Uses the existing StatusIndicator animations (ellipsis, compacting, numericText transitions).
struct StatusChip: View {
    let state: SessionState?
    let stateChangedAt: String?
    var style: ChipStyle = .normal

    @Environment(\.prefersReducedMotion) private var reduceMotion

    enum ChipStyle {
        case normal
        case compact
    }

    private var effectiveState: SessionState {
        state ?? .idle
    }

    private var recencyText: String {
        RelativeTimeFormatter.format(iso8601: stateChangedAt)
    }

    private var isStale: Bool {
        guard let timestamp = stateChangedAt,
              let date = RelativeTimeFormatter.parseISO8601(timestamp) else {
            return true
        }
        let hoursSince = Date().timeIntervalSince(date) / 3600
        return hoursSince > 24
    }

    private var chipOpacity: Double {
        if effectiveState == .idle || isStale {
            return 0.6
        }
        return 1.0
    }

    var body: some View {
        HStack(spacing: style == .compact ? 4 : 6) {
            if let state = state {
                StatusIndicator(state: state)
                    .scaleEffect(style == .compact ? 0.85 : 1.0, anchor: .leading)
            } else {
                Text("IDLE")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .tracking(0.5)
                    .foregroundColor(.white.opacity(0.35))
            }

            Text("·")
                .font(style == .compact ? AppTypography.captionSmall : .system(.callout, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))

            Text(recencyText)
                .font(style == .compact ? AppTypography.captionSmall : .system(.callout, design: .monospaced).weight(.medium))
                .foregroundColor(.white.opacity(0.5))
                .contentTransition(reduceMotion ? .identity : .numericText())
        }
        .opacity(chipOpacity)
        .animation(reduceMotion ? AppMotion.reducedMotionFallback : .smooth(duration: 0.3), value: effectiveState)
        .animation(reduceMotion ? AppMotion.reducedMotionFallback : .smooth(duration: 0.3), value: recencyText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(effectiveState), \(recencyText)")
    }
}

/// A row of status chips for project cards.
/// Shows state + recency in a compact, scannable format.
struct StatusChipsRow: View {
    let sessionState: ProjectSessionState?
    var style: StatusChip.ChipStyle = .normal

    var body: some View {
        HStack(spacing: 8) {
            StatusChip(
                state: sessionState?.state,
                stateChangedAt: sessionState?.stateChangedAt,
                style: style
            )
        }
    }
}

#Preview("Status Chips") {
    VStack(alignment: .leading, spacing: 16) {
        Group {
            StatusChip(state: .ready, stateChangedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120)))
            StatusChip(state: .working, stateChangedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300)))
            StatusChip(state: .waiting, stateChangedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)))
            StatusChip(state: .idle, stateChangedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400 * 3)))
            StatusChip(state: nil, stateChangedAt: nil)
        }

        Divider()

        Text("Compact Style").font(.caption).foregroundColor(.secondary)

        Group {
            StatusChip(state: .ready, stateChangedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120)), style: .compact)
            StatusChip(state: .working, stateChangedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300)), style: .compact)
        }
    }
    .padding()
    .background(Color.hudCard)
}
