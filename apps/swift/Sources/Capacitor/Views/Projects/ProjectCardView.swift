import SwiftUI

// MARK: - Preference Key for Frame Tracking

private struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Main Card View

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let isStale: Bool
    let isActive: Bool
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToDormant: () -> Void
    var onCaptureIdea: ((CGRect) -> Void)?
    let onRemove: () -> Void
    var onDragStarted: (() -> NSItemProvider)?
    var isDragging: Bool = false

    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion
    @ObservedObject private var glassConfig = GlassConfig.shared

    @State private var isHovered = false
    @State private var isPressed = false
    @State private var flashOpacity: Double = 0
    @State private var previousState: SessionState?
    @State private var lastChimeTime: Date?

    private let chimeCooldown: TimeInterval = 3.0

    // MARK: - Computed Properties

    private var currentState: SessionState? {
        switch glassConfig.previewState {
        case .none: return sessionState?.state
        case .ready: return .ready
        case .working: return .working
        case .waiting: return .waiting
        case .compacting: return .compacting
        case .idle: return .idle
        }
    }

    private var isReady: Bool {
        currentState == .ready
    }

    private var isWaiting: Bool {
        currentState == .waiting
    }

    private var isWorking: Bool {
        currentState == .working
    }

    private var nameColor: Color {
        project.isMissing ? .white.opacity(0.5) : .white.opacity(0.9)
    }

    private var glassConfigForHandlers: GlassConfig? {
        glassConfig
    }

    private var cardScale: CGFloat {
        guard !reduceMotion else { return 1.0 }
        if isPressed || isDragging {
            return glassConfig.cardPressedScale(for: .vertical)
        } else if isHovered {
            return glassConfig.cardHoverScale(for: .vertical)
        }
        return glassConfig.cardIdleScale(for: .vertical)
    }

    private var cardAnimation: Animation {
        guard !reduceMotion else { return AppMotion.reducedMotionFallback }
        if isPressed {
            return .spring(
                response: glassConfig.cardPressedSpringResponse(for: .vertical),
                dampingFraction: glassConfig.cardPressedSpringDamping(for: .vertical)
            )
        }
        return .spring(
            response: glassConfig.cardHoverSpringResponse(for: .vertical),
            dampingFraction: glassConfig.cardHoverSpringDamping(for: .vertical)
        )
    }

    // MARK: - Body

    private var accessibilityStatusDescription: String {
        guard let state = currentState else { return "No active session" }
        switch state {
        case .ready: return "Ready for input"
        case .working: return "Working"
        case .waiting: return "Waiting for user action"
        case .compacting: return "Compacting history"
        case .idle: return "Idle"
        }
    }

    var body: some View {
        cardContent
            .cardStyling(
                isHovered: isHovered,
                isReady: isReady,
                isWaiting: isWaiting,
                isWorking: isWorking,
                isActive: isActive,
                flashState: flashState,
                flashOpacity: flashOpacity,
                floatingMode: floatingMode,
                floatingCardBackground: floatingCardBackground,
                solidCardBackground: solidCardBackground,
                animationSeed: project.path,
                isPressed: isPressed
            )
            .scaleEffect(cardScale)
            .animation(cardAnimation, value: cardScale)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                isPressed = pressing
            }, perform: {})
            .cardInteractions(
                isHovered: $isHovered,
                onTap: onTap,
                onDragStarted: onDragStarted
            )
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
            .contextMenu { cardContextMenu }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project.name)
            .accessibilityValue(accessibilityStatusDescription)
            .accessibilityHint("Double-tap to open in terminal. Use actions menu for more options.")
            .accessibilityAction(named: "Open in Terminal", onTap)
            .accessibilityAction(named: "View Details", onInfoTap)
            .accessibilityAction(named: "Move to Paused", onMoveToDormant)
    }

    // MARK: - Card Content

    private var cardContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ProjectCardHeader(
                    project: project,
                    nameColor: nameColor,
                    onInfoTap: onInfoTap
                )

                ProjectCardContent(
                    sessionState: sessionState,
                    blocker: projectStatus?.blocker
                )
            }

            CardActionButtons(
                isCardHovered: isHovered,
                onCaptureIdea: onCaptureIdea,
                onDetails: onInfoTap
            )
        }
        .padding(.horizontal, glassConfig.cardPaddingH)
        .padding(.vertical, glassConfig.cardPaddingV)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: projectStatus?.blocker)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var cardContextMenu: some View {
        if project.isMissing {
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label("Remove from HUD", systemImage: "trash")
            }
        } else {
            Button(action: onTap) {
                Label("Open in Terminal", systemImage: "terminal")
            }
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            if let onCaptureIdea = onCaptureIdea {
                Button(action: { onCaptureIdea(.zero) }) {
                    Label("Capture Idea...", systemImage: "lightbulb")
                }
            }
            Divider()
            Button(action: onMoveToDormant) {
                Label("Move to Paused", systemImage: "moon.zzz")
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove from HUD", systemImage: "trash")
            }
        }
    }

    // MARK: - Background Styles

    private var floatingCardBackground: some View {
        DarkFrostedCard(isHovered: isHovered, layoutMode: .vertical, config: glassConfig)
    }

    private var solidCardBackground: some View {
        let cornerRadius = GlassConfig.shared.cardCornerRadius(for: .vertical)
        return ZStack {
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
        }
    }
}

// MARK: - Card Header Component

private struct ProjectCardHeader: View {
    let project: Project
    let nameColor: Color
    let onInfoTap: () -> Void

    var body: some View {
        HStack {
            if project.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.orange)
            }

            ClickableProjectTitle(
                name: project.name,
                nameColor: nameColor,
                isMissing: project.isMissing,
                action: onInfoTap
            )

            Spacer()
        }
    }
}

// MARK: - Card Content Component

private struct ProjectCardContent: View {
    let sessionState: ProjectSessionState?
    let blocker: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusChipsRow(sessionState: sessionState)

            if let blocker = blocker, !blocker.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(AppTypography.captionSmall)
                    Text(blocker)
                        .font(AppTypography.label)
                        .lineLimit(1)
                }
                .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Card Action Buttons

/// Container for action buttons that appear on card hover with staggered animation
struct CardActionButtons: View {
    let isCardHovered: Bool
    var onCaptureIdea: ((CGRect) -> Void)?
    let onDetails: () -> Void
    var style: VibrancyActionButton.Style = .normal

    var body: some View {
        HStack(spacing: 0) {
            if let onCaptureIdea = onCaptureIdea {
                VibrancyActionButton(
                    icon: "lightbulb",
                    action: { frame in onCaptureIdea(frame) },
                    isVisible: isCardHovered,
                    entranceDelay: 0,
                    style: style
                )
                .help("Capture idea")
                .accessibilityLabel("Capture idea for this project")
            }

            VibrancyActionButton(
                icon: "chevron.right",
                action: { _ in onDetails() },
                isVisible: isCardHovered,
                entranceDelay: 0.03,
                style: style
            )
            .help("View details")
            .accessibilityLabel("View project details")
        }
    }
}

// MARK: - Vibrancy Action Button

/// Rounded button with native macOS vibrancy and entrance animation
struct VibrancyActionButton: View {
    let icon: String
    let action: (CGRect) -> Void
    var isVisible: Bool = true
    var entranceDelay: Double = 0
    var style: Style = .normal

    enum Style {
        case normal
        case compact
    }

    @State private var isHovered = false
    @State private var buttonFrame: CGRect = .zero

    private var size: CGFloat {
        style == .compact ? 32 : 40
    }

    private var iconSize: CGFloat {
        style == .compact ? 13 : 15
    }

    private var entranceAnimation: Animation {
        .spring(response: 0.25, dampingFraction: 0.7)
            .delay(entranceDelay)
    }

    var body: some View {
        Button(action: { action(buttonFrame) }) {
            ZStack {
                // Vibrancy background (only on hover)
                if isHovered {
                    Circle()
                        .fill(.clear)
                        .background(
                            VibrancyView(
                                material: .hudWindow,
                                blendingMode: .behindWindow,
                                isEmphasized: true,
                                forceDarkAppearance: true
                            )
                        )
                        .clipShape(Circle())

                    // Light tint overlay
                    Circle()
                        .fill(Color.black.opacity(0.15))

                    // Subtle border
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.15),
                            lineWidth: 0.5
                        )
                }

                // Icon
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.5))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .scaleEffect(isVisible ? 1.0 : 0.9)
        .blur(radius: isVisible ? 0 : 4)
        .opacity(isVisible ? 1.0 : 0)
        .animation(entranceAnimation, value: isVisible)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: FramePreferenceKey.self,
                    value: geo.frame(in: .named("contentView"))
                )
            }
        )
        .onPreferenceChange(FramePreferenceKey.self) { frame in
            buttonFrame = frame
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Ticker Text Component

private struct TickerText: View {
    let text: String
    let isShimmering: Bool

    var body: some View {
        Text(text)
            .font(AppTypography.body)
            .foregroundColor(.white.opacity(0.6))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
            .overlay {
                if isShimmering {
                    ShimmerEffect()
                        .mask(
                            Text(text)
                                .font(AppTypography.body)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        )
                }
            }
            .id(text)
    }
}

// MARK: - Shimmer Effect

private struct ShimmerEffect: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0), location: phase - 0.2),
                    .init(color: .white.opacity(0.4), location: phase),
                    .init(color: .white.opacity(0), location: phase + 0.2),
                    .init(color: .white.opacity(0), location: 1)
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .onAppear {
                withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
        }
    }
}

// Note: StaleBadge and StatusIndicator are in ProjectCardComponents.swift

// View modifiers and glow effects are now in separate files:
// - ProjectCardModifiers.swift (cardStyling, cardInteractions, cardLifecycleHandlers)
// - ProjectCardGlow.swift (ReadyAmbientGlow, ReadyBorderGlow)

// MARK: - Unused Legacy Components (kept for compatibility)

struct PressableButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

struct HealthBadge: View {
    let project: Project
    @State private var showingPopover = false

    private var healthResult: HealthScoreResult {
        ClaudeMdHealthScorer.score(content: project.claudeMdPreview)
    }

    private var badgeColor: Color {
        switch healthResult.grade {
        case .a: return Color(hue: 0.35, saturation: 0.7, brightness: 0.75)
        case .b: return Color(hue: 0.28, saturation: 0.6, brightness: 0.8)
        case .c: return Color(hue: 0.12, saturation: 0.6, brightness: 0.85)
        case .d: return Color(hue: 0.06, saturation: 0.6, brightness: 0.85)
        case .f: return Color(hue: 0.0, saturation: 0.6, brightness: 0.75)
        case .none: return Color.white.opacity(0.3)
        }
    }

    var body: some View {
        if project.claudeMdPath != nil {
            Button(action: { showingPopover.toggle() }) {
                Text(healthResult.grade.rawValue)
                    .font(AppTypography.badge)
                    .foregroundColor(badgeColor)
                    .frame(width: 14, height: 14)
                    .background(badgeColor.opacity(0.15))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(badgeColor.opacity(0.3), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("CLAUDE.md health: \(healthResult.grade.rawValue) (\(healthResult.score)/100) - Click for details")
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                HealthDetailPopover(result: healthResult, projectPath: project.claudeMdPath ?? "")
            }
        }
    }
}

struct HealthDetailPopover: View {
    let result: HealthScoreResult
    let projectPath: String
    @State private var copiedTemplate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CLAUDE.md Health")
                    .font(AppTypography.cardTitle)
                Spacer()
                Text("\(result.score)/\(result.maxScore)")
                    .font(AppTypography.mono.weight(.medium))
                    .foregroundColor(.secondary)
            }

            Divider()

            ForEach(result.details, id: \.name) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "circle")
                        .font(AppTypography.bodySecondary)
                        .foregroundColor(check.passed ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.name)
                            .font(AppTypography.cardSubtitle)

                        if !check.passed, let suggestion = check.suggestion {
                            Text(suggestion)
                                .font(AppTypography.label)
                                .foregroundColor(.secondary)
                        }

                        if !check.passed, let template = check.template {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(template, forType: .string)
                                copiedTemplate = check.name
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    if copiedTemplate == check.name {
                                        copiedTemplate = nil
                                    }
                                }
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: copiedTemplate == check.name ? "checkmark" : "doc.on.doc")
                                        .font(AppTypography.captionSmall)
                                    Text(copiedTemplate == check.name ? "Copied!" : "Copy template")
                                        .font(AppTypography.captionSmall)
                                }
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer()

                    Text("+\(check.points)")
                        .font(AppTypography.monoCaption.weight(.medium))
                        .foregroundColor(check.passed ? .green : .secondary.opacity(0.5))
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
