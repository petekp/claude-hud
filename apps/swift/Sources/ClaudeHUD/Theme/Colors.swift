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

    // Accent
    static let hudAccent = Color(hue: 24/360, saturation: 0.85, brightness: 0.95) // warm orange
}
