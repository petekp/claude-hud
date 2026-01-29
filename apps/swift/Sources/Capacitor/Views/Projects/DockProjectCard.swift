import SwiftUI

struct DockProjectCard: View {
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

    private var cornerRadius: CGFloat {
        GlassConfig.shared.cardCornerRadius(for: .dock)
    }

    private var currentState: SessionState? {
        sessionState?.state
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

    private var glassConfigForHandlers: GlassConfig? {
        glassConfig
    }

    private var cardScale: CGFloat {
        guard !reduceMotion else { return 1.0 }
        if isPressed || isDragging {
            return glassConfig.cardPressedScale(for: .dock)
        } else if isHovered {
            return glassConfig.cardHoverScale(for: .dock)
        }
        return glassConfig.cardIdleScale(for: .dock)
    }

    private var cardAnimation: Animation {
        guard !reduceMotion else { return AppMotion.reducedMotionFallback }
        if isPressed {
            return .spring(
                response: glassConfig.cardPressedSpringResponse(for: .dock),
                dampingFraction: glassConfig.cardPressedSpringDamping(for: .dock)
            )
        }
        return .spring(
            response: glassConfig.cardHoverSpringResponse(for: .dock),
            dampingFraction: glassConfig.cardHoverSpringDamping(for: .dock)
        )
    }

    var body: some View {
        cardContent
            .frame(width: 262)
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
                layoutMode: .dock,
                isPressed: isPressed
            )
            .scaleEffect(cardScale)
            .animation(cardAnimation, value: cardScale)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                isPressed = pressing
            }, perform: {})
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture(perform: onTap)
            .onDrag {
                onDragStarted?() ?? NSItemProvider(object: project.path as NSString)
            } preview: {
                Text(project.name)
                    .font(AppTypography.sectionTitle.monospaced())
                    .padding(8)
                    .background(Color.hudCard.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
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
            .contextMenu {
                ProjectContextMenu(
                    project: project,
                    onTap: onTap,
                    onInfoTap: onInfoTap,
                    onMoveToDormant: onMoveToDormant,
                    onCaptureIdea: onCaptureIdea.map { action in { action(.zero) } },
                    onRemove: onRemove
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project.name)
            .accessibilityValue(statusDescription)
    }

    private var cardContent: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ClickableProjectTitle(
                        name: project.name,
                        nameColor: .white.opacity(0.9),
                        isMissing: project.isMissing,
                        action: onInfoTap,
                        font: AppTypography.sectionTitle.monospaced()
                    )
                    .lineLimit(1)

                    Spacer(minLength: 0)
                }

                StatusChipsRow(sessionState: sessionState, style: .compact)
                    .padding(.top, 4)

                Spacer(minLength: 0)

                if let blocker = projectStatus?.blocker, !blocker.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(AppTypography.captionSmall)
                        Text(blocker)
                            .font(AppTypography.label)
                            .lineLimit(1)
                    }
                    .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CardActionButtons(
                isCardHovered: isHovered,
                onCaptureIdea: onCaptureIdea,
                onDetails: onInfoTap,
                style: .compact
            )
        }
        .padding(.horizontal, glassConfig.dockCardPaddingH)
        .padding(.vertical, glassConfig.dockCardPaddingV)
    }

    private var floatingCardBackground: some View {
        DarkFrostedCard(isHovered: isHovered, layoutMode: .dock, config: glassConfig)
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

// Note: DockStatusIndicator, DockBlockerBadge, DockStaleBadge have been replaced
// with shared components from ProjectCardComponents.swift:
// - StatusIndicator(state:, style: .compact)
// - BlockerBadge(style: .compact)
// - StaleBadge(style: .compact)
