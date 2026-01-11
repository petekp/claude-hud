import SwiftUI

struct BreathingDot: View {
    @State private var isAnimating = false
    let color: Color
    var showGlow: Bool = true

    var body: some View {
        ZStack {
            if showGlow {
                Circle()
                    .fill(color.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .blur(radius: 5)
                    .scaleEffect(isAnimating ? 1.3 : 0.9)
                    .opacity(isAnimating ? 0.25 : 0.5)
            }

            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.6), radius: 3, x: 0, y: 0)
                .scaleEffect(isAnimating ? 0.85 : 1.0)
                .opacity(isAnimating ? 0.7 : 1.0)
        }
        .animation(
            .easeInOut(duration: 1.25)
            .repeatForever(autoreverses: true),
            value: isAnimating
        )
        .onAppear {
            isAnimating = true
        }
    }
}
