import SwiftUI

extension Color {
    // Dark mode background (primary)
    static let hudBackground = Color(hue: 260/360, saturation: 0.045, brightness: 0.11)
    static let hudCard = Color(hue: 260/360, saturation: 0.055, brightness: 0.145)
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
    static let hudAccent = Color(hue: 24/360, saturation: 0.85, brightness: 0.95) // warm orange

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
}
