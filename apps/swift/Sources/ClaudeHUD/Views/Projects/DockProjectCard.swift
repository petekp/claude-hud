import SwiftUI

struct DockProjectCard: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let devServerPort: UInt16?
    let isStale: Bool
    let isActive: Bool
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToDormant: () -> Void
    let onOpenBrowser: () -> Void
    var onCaptureIdea: (() -> Void)?
    var onRemove: (() -> Void)?

    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion

    #if DEBUG
    @ObservedObject private var glassConfig = GlassConfig.shared
    #endif

    @State private var isHovered = false
    @State private var flashOpacity: Double = 0
    @State private var previousState: SessionState?
    @State private var lastChimeTime: Date?
    @State private var lastKnownSummary: String?

    private let cornerRadius: CGFloat = 10
    private let chimeCooldown: TimeInterval = 3.0

    private var currentState: SessionState? {
        sessionState?.state
    }

    private var isReady: Bool {
        currentState == .ready
    }

    private var displaySummary: String? {
        if let current = sessionState?.workingOn, !current.isEmpty {
            return current
        }
        return lastKnownSummary
    }

    #if DEBUG
    private var glassConfigForHandlers: GlassConfig? {
        glassConfig
    }
    #else
    private var glassConfigForHandlers: Any? {
        nil
    }
    #endif

    var body: some View {
        cardContent
            .frame(width: 140, height: 95)
            .cardStyling(
                isHovered: isHovered,
                isReady: isReady,
                isActive: isActive,
                flashState: flashState,
                flashOpacity: flashOpacity,
                floatingMode: floatingMode,
                floatingCardBackground: floatingCardBackground,
                solidCardBackground: solidCardBackground,
                animationSeed: project.path,
                cornerRadius: cornerRadius
            )
            .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
            .animation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture(perform: onTap)
            .cardLifecycleHandlers(
                flashState: flashState,
                sessionState: sessionState,
                currentState: currentState,
                previousState: $previousState,
                lastChimeTime: $lastChimeTime,
                flashOpacity: $flashOpacity,
                chimeCooldown: chimeCooldown,
                glassConfig: glassConfigForHandlers
            )
            .contextMenu { contextMenuContent }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project.name)
            .accessibilityValue(statusDescription)
            .onChange(of: sessionState?.workingOn) { _, newValue in
                if let summary = newValue, !summary.isEmpty {
                    lastKnownSummary = summary
                }
            }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(project.name)
                    .font(AppTypography.labelMedium)
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let state = currentState {
                    DockStatusIndicator(state: state)
                }
            }

            if let summary = displaySummary, !summary.isEmpty {
                Text(summary)
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if let port = devServerPort {
                    DockPortBadge(port: port, onTap: onOpenBrowser)
                }

                if let blocker = projectStatus?.blocker, !blocker.isEmpty {
                    DockBlockerBadge()
                }

                Spacer()

                if isStale {
                    DockStaleBadge()
                }
            }
        }
        .padding(10)
    }

    private var floatingCardBackground: some View {
        #if DEBUG
        DarkFrostedCard(isHovered: isHovered, config: glassConfig)
        #else
        DarkFrostedCard(isHovered: isHovered)
        #endif
    }

    private var solidCardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
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
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            RoundedRectangle(cornerRadius: cornerRadius)
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

    @ViewBuilder
    private var contextMenuContent: some View {
        if project.isMissing {
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            Divider()
            if let onRemove = onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Missing Project", systemImage: "trash")
                }
            }
        } else {
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
            if let onCaptureIdea = onCaptureIdea {
                Button(action: onCaptureIdea) {
                    Label("Capture Idea...", systemImage: "lightbulb")
                }
            }
            Divider()
            Button(action: onMoveToDormant) {
                Label("Move to Paused", systemImage: "moon.zzz")
            }
        }
    }

    private var statusDescription: String {
        guard let state = currentState else { return "No active session" }
        switch state {
        case .ready: return "Ready for input"
        case .working: return "Working"
        case .waiting: return "Waiting for user action"
        case .compacting: return "Compacting history"
        case .idle: return "Idle"
        }
    }
}

private struct DockStatusIndicator: View {
    let state: SessionState
    @Environment(\.prefersReducedMotion) private var reduceMotion

    private var statusColor: Color {
        Color.statusColor(for: state)
    }

    private var statusText: String {
        switch state {
        case .ready: return "Ready"
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .compacting: return "Compact"
        case .idle: return "Idle"
        }
    }

    private var isActive: Bool {
        state != .idle
    }

    var body: some View {
        Text(statusText)
            .font(AppTypography.captionSmall)
            .foregroundColor(isActive ? statusColor : statusColor.opacity(0.55))
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? AppMotion.reducedMotionFallback : .smooth(duration: 0.3), value: state)
    }
}

private struct DockPortBadge: View {
    let port: UInt16
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text(":\(port)")
                .font(AppTypography.monoCaption)
                .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(isHovered ? 0.15 : 0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct DockBlockerBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(AppTypography.captionSmall)
            .foregroundColor(.orange)
    }
}

private struct DockStaleBadge: View {
    var body: some View {
        Text("stale")
            .font(AppTypography.captionSmall)
            .foregroundColor(.white.opacity(0.4))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
    }
}
