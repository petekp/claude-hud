import SwiftUI

extension Color {
    // Dark mode background (primary)
    static let hudBackground = Color(hue: 260/360, saturation: 0.045, brightness: 0.11)
    static let hudCard = Color(hue: 260/360, saturation: 0.055, brightness: 0.145)
    static let hudCardElevated = Color(hue: 260/360, saturation: 0.06, brightness: 0.17)
    static let hudBorder = Color.white.opacity(0.10)

    // Status colors
    static let statusReady = Color(hue: 145/360, saturation: 0.75, brightness: 0.70)
    static let statusWorking = Color(hue: 45/360, saturation: 0.65, brightness: 0.75)
    static let statusWaiting = Color(hue: 85/360, saturation: 0.70, brightness: 0.80)
    static let statusCompacting = Color(hue: 55/360, saturation: 0.55, brightness: 0.70)
    static let statusIdle = Color.white.opacity(0.4)

    // Flash colors (for state change animations)
    static let flashReady = Color(hue: 145/360, saturation: 0.75, brightness: 0.70).opacity(0.25)
    static let flashWaiting = Color(hue: 85/360, saturation: 0.70, brightness: 0.80).opacity(0.25)
    static let flashCompacting = Color(hue: 55/360, saturation: 0.55, brightness: 0.70).opacity(0.20)

    // Accent
    static let hudAccent = Color(hue: 24/360, saturation: 0.85, brightness: 0.95)
    static let hudAccentDark = Color(hue: 24/360, saturation: 0.90, brightness: 0.75)

    // Section header accent
    static let sectionAccent = Color(hue: 24/360, saturation: 0.70, brightness: 0.85)

    static func flashColor(for state: SessionState) -> Color {
        switch state {
        case .ready:
            return .statusReady
        case .waiting:
            return .statusWaiting
        case .compacting:
            return .statusCompacting
        default:
            return .clear
        }
    }

    static func statusColor(for state: SessionState) -> Color {
        switch state {
        case .ready: return .statusReady
        case .working: return .statusWorking
        case .waiting: return .statusWaiting
        case .compacting: return .statusCompacting
        case .idle: return .statusIdle
        }
    }
}

struct HudGradients {
    static let accent = LinearGradient(
        colors: [Color.hudAccent, Color.hudAccentDark],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cardHighlight = LinearGradient(
        colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cardBorder = LinearGradient(
        colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let sectionLine = LinearGradient(
        colors: [Color.sectionAccent.opacity(0.6), Color.clear],
        startPoint: .leading,
        endPoint: .trailing
    )

    static func glowGradient(for color: Color) -> RadialGradient {
        RadialGradient(
            colors: [color.opacity(0.4), color.opacity(0.0)],
            center: .center,
            startRadius: 0,
            endRadius: 20
        )
    }
}
