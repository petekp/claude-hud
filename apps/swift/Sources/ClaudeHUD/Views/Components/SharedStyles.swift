import SwiftUI

struct HoverButtonStyle: ButtonStyle {
    @Binding var isHovered: Bool
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct BackButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .offset(x: isHovered ? -2 : 0)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white.opacity(isHovered ? 0.95 : 0.55))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(isHovered ? 0.1 : 0))

                    if isHovered {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    }
                }
            }
            .scaleEffect(isPressed ? 0.96 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.spring(response: 0.15)) { isPressed = true }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { isPressed = false }
                }
        )
    }
}

struct ActionButton: View {
    let icon: String
    let title: String
    var isAccent: Bool = false
    var fullWidth: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: isAccent ? 11 : 12))
                Text(title)
                    .font(.system(size: 12, weight: isAccent ? .semibold : .medium))
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, isAccent ? 14 : 12)
            .padding(.vertical, isAccent ? 10 : 8)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(backgroundView)
            .clipShape(RoundedRectangle(cornerRadius: isAccent ? 8 : 6))
            .overlay(borderOverlay)
            .shadow(color: shadowColor, radius: isHovered ? 8 : 0, y: 2)
            .scaleEffect(isPressed ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.spring(response: 0.15)) { isPressed = true }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { isPressed = false }
                }
        )
    }

    private var foregroundColor: Color {
        if isAccent {
            return isHovered ? .white : .white.opacity(0.95)
        }
        return .white.opacity(isHovered ? 0.9 : 0.7)
    }

    @ViewBuilder
    private var backgroundView: some View {
        if isAccent {
            LinearGradient(
                colors: [
                    Color.hudAccent.opacity(isHovered ? 0.95 : 0.8),
                    Color.hudAccentDark.opacity(isHovered ? 0.85 : 0.7)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Color.white.opacity(isHovered ? 0.12 : 0.06)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if isAccent {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.3 : 0.2),
                            Color.hudAccent.opacity(isHovered ? 0.6 : 0.4)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        } else {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(isHovered ? 0.2 : 0.1), lineWidth: 1)
        }
    }

    private var shadowColor: Color {
        if isAccent && isHovered {
            return Color.hudAccent.opacity(0.4)
        }
        return .clear
    }
}

struct IconButton: View {
    let icon: String
    var size: CGFloat = 14
    var rotateOnHover: CGFloat = 0
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundColor(.white.opacity(isHovered ? 0.7 : 0.35))
                .rotationEffect(.degrees(isHovered ? rotateOnHover : 0))
                .scaleEffect(isHovered ? 1.1 : 1.0)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

struct CardBackground: View {
    let isHovered: Bool
    @Environment(\.floatingMode) private var floatingMode

    var body: some View {
        if floatingMode {
            floatingBackground
        } else {
            solidBackground
        }
    }

    private var floatingBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(isHovered ? 0.22 : 0.12),
                            .white.opacity(isHovered ? 0.08 : 0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isHovered ? 0.4 : 0.25),
                            .white.opacity(isHovered ? 0.15 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        }
    }

    private var solidBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.hudCardElevated.opacity(isHovered ? 1.0 : 0.0),
                            Color.hudCard
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: 12)
                .fill(Color.hudCard)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(isHovered ? 0.08 : 0.04), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)

                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isHovered ? 0.18 : 0.1),
                            .white.opacity(isHovered ? 0.08 : 0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        }
    }
}

struct SkeletonView: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.08),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .offset(x: isAnimating ? geometry.size.width : -geometry.size.width)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1.5)
                .repeatForever(autoreverses: false)
            ) {
                isAnimating = true
            }
        }
    }
}

struct SkeletonCard: View {
    @Environment(\.floatingMode) private var floatingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SkeletonView()
                    .frame(width: 120, height: 14)

                Spacer()

                SkeletonView()
                    .frame(width: 60, height: 20)
                    .clipShape(Capsule())
            }

            SkeletonView()
                .frame(height: 12)

            SkeletonView()
                .frame(width: 180, height: 12)
        }
        .padding(12)
        .background {
            if floatingMode {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .opacity(0.5)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.hudCard)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }
}
