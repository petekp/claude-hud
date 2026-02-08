import AppKit
import SwiftUI

enum CardEffectAnimationPolicy {
    static func shouldAnimate(isActive: Bool, isHovered: Bool, isWaiting: Bool, isWorking: Bool) -> Bool {
        isActive || isHovered || isWaiting || isWorking
    }
}

extension View {
    func cardStyling(
        isHovered: Bool,
        isReady: Bool,
        isWaiting: Bool = false,
        isWorking: Bool = false,
        isActive: Bool,
        flashState: SessionState?,
        flashOpacity: Double,
        floatingMode: Bool,
        floatingCardBackground: some View,
        solidCardBackground: some View,
        animationSeed: String,
        layoutMode: LayoutMode = .vertical,
        isPressed: Bool = false
    ) -> some View {
        // Single source of truth for corner radius
        let cornerRadius = GlassConfig.shared.cardCornerRadius(for: layoutMode)

        // Only animate effects for active, hovered, waiting, or working cards to reduce GPU load during scroll
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: isActive,
            isHovered: isHovered,
            isWaiting: isWaiting,
            isWorking: isWorking
        )

        return background {
            ZStack {
                if floatingMode {
                    floatingCardBackground
                        .id(GlassConfig.shared.cardConfigHash)
                } else {
                    solidCardBackground
                }

                if isWorking {
                    WorkingStripeOverlay(layoutMode: layoutMode, animate: shouldAnimate)
                        .transition(.opacity.animation(.easeInOut(duration: GlassConfig.shared.glowFadeDuration)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            let config = GlassConfig.shared
            let borderOpacity = isHovered ? config.cardHoverBorderOpacity : config.cardBorderOpacity
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(borderOpacity),
                            .white.opacity(borderOpacity * 0.4),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(flashState.map { Color.flashColor(for: $0) } ?? .clear, lineWidth: 2)
                .opacity(flashOpacity)
        )
        .overlay {
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            Color.white.opacity(0.3),
                            lineWidth: 3
                        )
                        .blur(radius: 4)

                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            Color.white.opacity(0.8),
                            lineWidth: 1.5
                        )
                }
            }
        }
        .overlay {
            let cfg = GlassConfig.shared
            if isReady {
                ReadyAmbientGlow(layoutMode: layoutMode, animate: shouldAnimate)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .transition(.opacity.animation(.easeOut(duration: cfg.glowFadeDuration)))
            }
        }
        .overlay {
            let cfg = GlassConfig.shared
            if isReady {
                ReadyBorderGlow(seed: animationSeed, layoutMode: layoutMode, animate: shouldAnimate)
                    .transition(.opacity.animation(.easeOut(duration: cfg.glowFadeDuration + cfg.glowBorderDelay).delay(cfg.glowBorderDelay)))
            }
        }
        .overlay {
            let cfg = GlassConfig.shared
            if isWaiting {
                WaitingAmbientPulse(layoutMode: layoutMode, animate: shouldAnimate)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .transition(.opacity.animation(.easeOut(duration: cfg.glowFadeDuration)))
            }
        }
        .overlay {
            let cfg = GlassConfig.shared
            if isWaiting {
                WaitingBorderPulse(seed: animationSeed, layoutMode: layoutMode, animate: shouldAnimate)
                    .transition(.opacity.animation(.easeOut(duration: cfg.glowFadeDuration + cfg.glowBorderDelay).delay(cfg.glowBorderDelay)))
            }
        }
        .overlay {
            let cfg = GlassConfig.shared
            if isWorking {
                WorkingBorderGlow(seed: animationSeed, layoutMode: layoutMode, animate: shouldAnimate)
                    .transition(.opacity.animation(.easeOut(duration: cfg.glowFadeDuration + cfg.glowBorderDelay).delay(cfg.glowBorderDelay)))
            }
        }
        .shadow(
            color: .black.opacity(shadowOpacity(isHovered: isHovered, isPressed: isPressed, floatingMode: floatingMode, layoutMode: layoutMode)),
            radius: shadowRadius(isHovered: isHovered, isPressed: isPressed, floatingMode: floatingMode, layoutMode: layoutMode),
            y: shadowY(isHovered: isHovered, isPressed: isPressed, floatingMode: floatingMode, layoutMode: layoutMode)
        )
    }

    func cardInteractions(
        isHovered: Binding<Bool>,
        onTap: @escaping () -> Void,
        onDragStarted: (() -> NSItemProvider)?
    ) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.return) {
                onTap()
                return .handled
            }
            .onKeyPress(.space) {
                onTap()
                return .handled
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: GlassConfig.shared.hoverTransitionDuration)) {
                    isHovered.wrappedValue = hovering
                }
            }
            .onDrag {
                _ = onDragStarted?()
                return NSItemProvider(object: "" as NSString)
            } preview: {
                Color.clear.frame(width: 1, height: 1)
            }
    }

    func cardLifecycleHandlers(
        flashState: SessionState?,
        sessionState: ProjectSessionState?,
        currentState: SessionState,
        previousState: Binding<SessionState?>,
        lastChimeTime: Binding<Date?>,
        flashOpacity: Binding<Double>,
        chimeCooldown: TimeInterval,
        glassConfig: GlassConfig?
    ) -> some View {
        animation(.easeOut(duration: GlassConfig.shared.stateTransitionDuration), value: currentState)
            .onChange(of: flashState) { _, newValue in
                guard newValue != nil else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    flashOpacity.wrappedValue = 1.0
                }
                withAnimation(.easeOut(duration: 1.3).delay(0.1)) {
                    flashOpacity.wrappedValue = 0
                }
            }
            .onChange(of: sessionState?.state) { oldValue, newValue in
                if let preview = glassConfig?.previewState, preview != .none { return }

                if newValue == .ready, oldValue != .ready, oldValue != nil {
                    let now = Date()
                    let shouldPlayChime = lastChimeTime.wrappedValue.map { now.timeIntervalSince($0) >= chimeCooldown } ?? true
                    if shouldPlayChime {
                        lastChimeTime.wrappedValue = now
                        ReadyChime.shared.play()
                    }
                }
                previousState.wrappedValue = newValue
            }
            .onChange(of: glassConfig?.previewState) { oldValue, newValue in
                if newValue == .ready, oldValue != .ready {
                    ReadyChime.shared.play()
                }
            }
            .onAppear {
                previousState.wrappedValue = sessionState?.state
            }
    }

    func preventWindowDrag() -> some View {
        WindowDragPreventer { self }
    }

    func windowDraggable() -> some View {
        WindowDragHandle { self }
    }
}

// MARK: - Shadow Helpers

private func shadowOpacity(isHovered: Bool, isPressed: Bool, floatingMode: Bool, layoutMode _: LayoutMode) -> Double {
    guard !floatingMode else { return 0.25 }
    let config = GlassConfig.shared
    if isPressed {
        return config.cardPressedShadowOpacity
    } else if isHovered {
        return config.cardHoverShadowOpacity
    }
    return config.cardIdleShadowOpacity
}

private func shadowRadius(isHovered: Bool, isPressed: Bool, floatingMode: Bool, layoutMode _: LayoutMode) -> CGFloat {
    guard !floatingMode else { return 8 }
    let config = GlassConfig.shared
    if isPressed {
        return config.cardPressedShadowRadius
    } else if isHovered {
        return config.cardHoverShadowRadius
    }
    return config.cardIdleShadowRadius
}

private func shadowY(isHovered: Bool, isPressed: Bool, floatingMode: Bool, layoutMode _: LayoutMode) -> CGFloat {
    guard !floatingMode else { return 3 }
    let config = GlassConfig.shared
    if isPressed {
        return config.cardPressedShadowY
    } else if isHovered {
        return config.cardHoverShadowY
    }
    return config.cardIdleShadowY
}

// MARK: - Window Drag Handling

struct WindowDragPreventer<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context _: Context) -> NonDraggableHostingView<Content> {
        NonDraggableHostingView(rootView: content)
    }

    func updateNSView(_ nsView: NonDraggableHostingView<Content>, context _: Context) {
        nsView.rootView = content
    }
}

struct WindowDragHandle<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context _: Context) -> DraggableHostingView<Content> {
        DraggableHostingView(rootView: content)
    }

    func updateNSView(_ nsView: DraggableHostingView<Content>, context _: Context) {
        nsView.rootView = content
    }
}

final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
