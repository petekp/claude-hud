import SwiftUI

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let devServerPort: UInt16?
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToDormant: () -> Void
    let onOpenBrowser: () -> Void

    @Environment(\.floatingMode) private var floatingMode
    @State private var isHovered = false
    @State private var isPressed = false
    @State private var flashOpacity: Double = 0
    @State private var isInfoHovered = false
    @State private var isBrowserHovered = false

    @State private var readyGlowIntensity: Double = 0
    @State private var colorWashProgress: Double = -0.3
    @State private var isColorWashActive = false
    @State private var previousState: SessionState?
    @State private var lastReadyAnimationTime: Date?

    private let readyAnimationCooldown: TimeInterval = 3.0

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    if let state = sessionState {
                        StatusPillView(state: state.state)
                    }

                    if let port = devServerPort {
                        Button(action: onOpenBrowser) {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                    .font(.system(size: 11))
                                Text(":\(port)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(.white.opacity(isBrowserHovered ? 0.85 : (isHovered ? 0.55 : 0.35)))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(isBrowserHovered ? 0.12 : (isHovered ? 0.06 : 0.03)))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(isBrowserHovered ? 0.15 : 0), lineWidth: 0.5)
                            )
                            .scaleEffect(isBrowserHovered ? 1.02 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                                isBrowserHovered = hovering
                            }
                        }
                        .help("Open localhost:\(port) in browser")
                    }

                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(isInfoHovered ? 0.8 : (isHovered ? 0.45 : 0.25)))
                            .rotationEffect(.degrees(isInfoHovered ? 15 : 0))
                            .scaleEffect(isInfoHovered ? 1.15 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                            isInfoHovered = hovering
                        }
                    }
                    .help("View details")
                }

                if let workingOn = sessionState?.workingOn, !workingOn.isEmpty {
                    Text(workingOn)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }

                if let blocker = projectStatus?.blocker, !blocker.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(blocker)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
                }
            }
            .padding(12)
            .background {
                if floatingMode {
                    floatingCardBackground
                } else {
                    solidCardBackground
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(flashState.map { Color.flashColor(for: $0) } ?? .clear, lineWidth: 2)
                    .opacity(flashOpacity)
            )
            .overlay {
                if isColorWashActive {
                    ColorWashOverlay(progress: colorWashProgress)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .shadow(
                color: readyGlowIntensity > 0
                    ? Color.statusReady.opacity(0.4 * readyGlowIntensity)
                    : (floatingMode ? .black.opacity(0.25) : (isHovered ? .black.opacity(0.2) : .black.opacity(0.08))),
                radius: readyGlowIntensity > 0
                    ? 20 * readyGlowIntensity
                    : (floatingMode ? 8 : (isHovered ? 12 : 4)),
                y: readyGlowIntensity > 0 ? 0 : (floatingMode ? 3 : (isHovered ? 4 : 2))
            )
            .shadow(
                color: readyGlowIntensity > 0 ? Color.statusReady.opacity(0.25 * readyGlowIntensity) : .clear,
                radius: 35 * readyGlowIntensity,
                y: 0
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .animation(.snappy(duration: 0.15), value: isPressed)
            .animation(.easeOut(duration: 0.2), value: isHovered)
            .animation(.easeOut(duration: 0.3), value: readyGlowIntensity)
        }
        .buttonStyle(PressableButtonStyle(isPressed: $isPressed))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onChange(of: flashState) { oldValue, newValue in
            if newValue != nil {
                withAnimation(.easeOut(duration: 0.1)) {
                    flashOpacity = 1.0
                }
                withAnimation(.easeOut(duration: 1.3).delay(0.1)) {
                    flashOpacity = 0
                }
            }
        }
        .onChange(of: sessionState?.state) { oldValue, newValue in
            if newValue == .ready && oldValue != .ready && oldValue != nil {
                let now = Date()
                let shouldAnimate = lastReadyAnimationTime.map { now.timeIntervalSince($0) >= readyAnimationCooldown } ?? true
                if shouldAnimate {
                    lastReadyAnimationTime = now
                    triggerReadyAnimation()
                }
            }
            previousState = newValue
        }
        .onAppear {
            previousState = sessionState?.state
        }
        .contextMenu {
            Button(action: onTap) {
                Label("Open in Terminal", systemImage: "terminal")
            }
            if devServerPort != nil {
                Button(action: onOpenBrowser) {
                    Label("Open in Browser", systemImage: "globe")
                }
            }
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onMoveToDormant) {
                Label("Move to Dormant", systemImage: "moon.zzz")
            }
        }
    }

    private var floatingCardBackground: some View {
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

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(isHovered ? 0.25 : 0.15), .clear],
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

    private var solidCardBackground: some View {
        ZStack {
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

    private func triggerReadyAnimation() {
        ReadyChime.shared.play()

        colorWashProgress = -0.3
        isColorWashActive = true

        withAnimation(.easeOut(duration: 0.15)) {
            readyGlowIntensity = 1.0
        }

        withAnimation(.easeInOut(duration: 0.7)) {
            colorWashProgress = 1.3
        }

        withAnimation(.easeOut(duration: 1.2).delay(0.3)) {
            readyGlowIntensity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            isColorWashActive = false
            colorWashProgress = -0.3
        }
    }
}

struct ColorWashOverlay: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let washWidth: CGFloat = geometry.size.width * 0.4
            let position = geometry.size.width * progress

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.statusReady.opacity(0.12), location: 0.3),
                    .init(color: Color.statusReady.opacity(0.18), location: 0.5),
                    .init(color: Color.statusReady.opacity(0.12), location: 0.7),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: washWidth)
            .offset(x: position - washWidth / 2)
            .blendMode(.plusLighter)
        }
    }
}

struct StatusPillView: View {
    let state: SessionState
    @Environment(\.floatingMode) private var floatingMode
    @State private var glowAnimation = false

    var statusColor: Color {
        Color.statusColor(for: state)
    }

    var statusText: String {
        switch state {
        case .ready: return "Ready"
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .compacting: return "Compacting"
        case .idle: return "Idle"
        }
    }

    var isActive: Bool {
        switch state {
        case .ready, .working, .waiting, .compacting: return true
        case .idle: return false
        }
    }

    var body: some View {
        ZStack {
            if isActive {
                Capsule()
                    .fill(statusColor.opacity(0.35))
                    .blur(radius: 10)
                    .scaleEffect(glowAnimation ? 1.15 : 0.95)
                    .opacity(glowAnimation ? 0.6 : 0.3)
            }

            if floatingMode && isActive {
                vibrantPill
            } else {
                solidPill
            }
        }
        .onAppear {
            if isActive {
                withAnimation(
                    .easeInOut(duration: 2.0)
                    .repeatForever(autoreverses: true)
                ) {
                    glowAnimation = true
                }
            }
        }
    }

    private var pillContent: some View {
        HStack(spacing: 5) {
            BreathingDot(color: statusColor, showGlow: false)

            Text(statusText)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    isActive
                        ? AnyShapeStyle(LinearGradient(
                            colors: [statusColor, statusColor.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                          ))
                        : AnyShapeStyle(statusColor)
                )
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
    }

    private var vibrantPill: some View {
        ZStack {
            Capsule()
                .fill(statusColor)
                .shadow(color: statusColor.opacity(0.5), radius: 6, y: 0)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )

            HStack(spacing: 5) {
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 6, height: 6)
                    .shadow(color: .white.opacity(0.5), radius: 2)

                Text(statusText)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
        }
        .fixedSize()
    }

    private var solidPill: some View {
        pillContent
            .background {
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    statusColor.opacity(isActive ? 0.25 : 0.12),
                                    statusColor.opacity(isActive ? 0.15 : 0.08)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    if isActive {
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        statusColor.opacity(0.5),
                                        statusColor.opacity(0.2)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    }
                }
            }
            .shadow(color: isActive ? statusColor.opacity(0.35) : .clear, radius: 6, y: 0)
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}
