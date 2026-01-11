import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .background {
                    if floatingMode {
                        FloatingPanelBackground()
                    }
                }

            if !floatingMode {
                Divider()
            }

            ZStack {
                switch appState.activeTab {
                case .projects:
                    NavigationContainer()
                case .artifacts:
                    ArtifactsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .preferredColorScheme(.dark)
    }
}

struct FloatingPanelBackground: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.12),
                            .white.opacity(0.04),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(0.2), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))

            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.25),
                            .white.opacity(0.1),
                            .white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )

            NoiseOverlay()
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.2), radius: 15, y: 8)
    }
}

struct NoiseOverlay: View {
    var body: some View {
        Canvas { context, size in
            for _ in 0..<Int(size.width * size.height * 0.01) {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                let opacity = Double.random(in: 0.01...0.03)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
        .blendMode(.overlay)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
