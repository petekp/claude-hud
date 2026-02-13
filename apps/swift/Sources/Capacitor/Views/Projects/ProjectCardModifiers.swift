import AppKit
import SwiftUI

enum CardEffectAnimationPolicy {
    static func shouldAnimate(isActive: Bool, isHovered: Bool, isWaiting: Bool, isWorking: Bool) -> Bool {
        isActive || isHovered || isWaiting || isWorking
    }
}

struct CardLayerOpacities: Equatable {
    let readyAmbient: Double
    let readyBorder: Double
    let waitingAmbient: Double
    let waitingBorder: Double
    let workingStripe: Double
    let workingBorder: Double
    let activeRing: Double
    let baseBorderBoost: Double
}

enum CardLayerOpacityPolicy {
    static func opacities(for state: SessionState) -> CardLayerOpacities {
        switch state {
        case .idle:
            CardLayerOpacities(
                readyAmbient: 0,
                readyBorder: 0,
                waitingAmbient: 0,
                waitingBorder: 0,
                workingStripe: 0,
                workingBorder: 0,
                activeRing: 0,
                baseBorderBoost: 0,
            )
        case .ready:
            CardLayerOpacities(
                readyAmbient: 1.0,
                readyBorder: 1.0,
                waitingAmbient: 0,
                waitingBorder: 0,
                workingStripe: 0,
                workingBorder: 0,
                activeRing: 0.5,
                baseBorderBoost: 0.06,
            )
        case .working:
            CardLayerOpacities(
                readyAmbient: 0,
                readyBorder: 0,
                waitingAmbient: 0.24,
                waitingBorder: 0.18,
                workingStripe: 1.0,
                workingBorder: 1.0,
                activeRing: 0.72,
                baseBorderBoost: 0.13,
            )
        case .waiting:
            CardLayerOpacities(
                readyAmbient: 0,
                readyBorder: 0,
                waitingAmbient: 1.0,
                waitingBorder: 1.0,
                workingStripe: 0,
                workingBorder: 0,
                activeRing: 0.62,
                baseBorderBoost: 0.1,
            )
        case .compacting:
            CardLayerOpacities(
                readyAmbient: 0,
                readyBorder: 0,
                waitingAmbient: 0.46,
                waitingBorder: 0.56,
                workingStripe: 0,
                workingBorder: 0,
                activeRing: 0.55,
                baseBorderBoost: 0.09,
            )
        }
    }
}

enum ReadyChimePolicy {
    static func shouldPlay(
        playReadyChime: Bool,
        oldState: SessionState?,
        newState: SessionState?,
        lastChimeTime: Date?,
        now: Date,
        chimeCooldown: TimeInterval,
    ) -> Bool {
        guard playReadyChime else { return false }
        guard newState == .ready, oldState != .ready, oldState != nil else { return false }
        if let lastChimeTime {
            return now.timeIntervalSince(lastChimeTime) >= chimeCooldown
        }
        return true
    }
}

extension View {
    func cardStyling(
        isHovered: Bool,
        currentState: SessionState,
        isActive: Bool,
        flashState: SessionState?,
        flashOpacity: Double,
        floatingMode: Bool,
        floatingCardBackground: some View,
        solidCardBackground: some View,
        animationSeed: String,
        layoutMode: LayoutMode = .vertical,
        isPressed: Bool = false,
    ) -> some View {
        let cornerRadius = GlassConfig.shared.cardCornerRadius(for: layoutMode)
        let cfg = GlassConfig.shared
        let layerOpacities = CardLayerOpacityPolicy.opacities(for: currentState)

        // Only run TimelineView animations for cards that need them
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: isActive,
            isHovered: isHovered,
            isWaiting: layerOpacities.waitingAmbient > 0 || layerOpacities.waitingBorder > 0,
            isWorking: layerOpacities.workingStripe > 0 || layerOpacities.workingBorder > 0,
        )

        // Layer-specific timing keeps transitions smooth while preserving in-place identity.
        let ambientCrossFade = Animation.easeInOut(duration: cfg.glowFadeDuration)
        let borderCrossFade = Animation.easeInOut(duration: cfg.glowFadeDuration + cfg.glowBorderDelay)
            .delay(cfg.glowBorderDelay)
        let trailFade = Animation.easeOut(duration: cfg.glowFadeDuration * 1.25)

        return background {
            ZStack {
                if floatingMode {
                    floatingCardBackground
                        .id(GlassConfig.shared.cardConfigHash)
                } else {
                    solidCardBackground
                }

                // Working stripes — always present, cross-fade via opacity
                // Gate animate per-effect: only run TimelineView when this effect is visible
                WorkingStripeOverlay(layoutMode: layoutMode, animate: shouldAnimate && layerOpacities.workingStripe > 0)
                    .opacity(layerOpacities.workingStripe)
                    .animation(trailFade, value: layerOpacities.workingStripe)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            let borderOpacity = isHovered ? cfg.cardHoverBorderOpacity : cfg.cardBorderOpacity
            let boostedBorderOpacity = min(1.0, borderOpacity + layerOpacities.baseBorderBoost)
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(boostedBorderOpacity),
                            .white.opacity(boostedBorderOpacity * 0.4),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    ),
                    lineWidth: 0.5,
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(flashState.map { Color.flashColor(for: $0) } ?? .clear, lineWidth: 2)
                .opacity(flashOpacity),
        )
        .overlay {
            let activeRingOpacity = isActive ? layerOpacities.activeRing : 0
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        Color.white.opacity(0.3),
                        lineWidth: 3,
                    )
                    .blur(radius: 4)

                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        Color.white.opacity(0.8),
                        lineWidth: 1.5,
                    )
            }
            .opacity(activeRingOpacity)
            .animation(borderCrossFade, value: activeRingOpacity)
        }
        // Ready effects — always present, cross-fade via opacity
        // Gate animate per-effect: only run TimelineView when this effect is visible
        // Suppress ambient ripple on hover for non-focused cards (border glow only)
        .overlay {
            let effectiveReadyAmbient = (isHovered && !isActive) ? 0.0 : layerOpacities.readyAmbient
            ReadyAmbientGlow(layoutMode: layoutMode, animate: shouldAnimate && effectiveReadyAmbient > 0)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .opacity(effectiveReadyAmbient)
                .animation(ambientCrossFade, value: effectiveReadyAmbient)
        }
        .overlay {
            ReadyBorderGlow(seed: animationSeed, layoutMode: layoutMode, animate: shouldAnimate && layerOpacities.readyBorder > 0)
                .opacity(layerOpacities.readyBorder)
                .animation(borderCrossFade, value: layerOpacities.readyBorder)
        }
        // Waiting effects — always present, cross-fade via opacity
        .overlay {
            WaitingAmbientPulse(layoutMode: layoutMode, animate: shouldAnimate && layerOpacities.waitingAmbient > 0)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .opacity(layerOpacities.waitingAmbient)
                .animation(ambientCrossFade, value: layerOpacities.waitingAmbient)
        }
        .overlay {
            WaitingBorderPulse(seed: animationSeed, layoutMode: layoutMode, animate: shouldAnimate && layerOpacities.waitingBorder > 0)
                .opacity(layerOpacities.waitingBorder)
                .animation(borderCrossFade, value: layerOpacities.waitingBorder)
        }
        // Working border — always present, cross-fade via opacity
        .overlay {
            WorkingBorderGlow(seed: animationSeed, layoutMode: layoutMode, animate: shouldAnimate && layerOpacities.workingBorder > 0)
                .opacity(layerOpacities.workingBorder)
                .animation(borderCrossFade, value: layerOpacities.workingBorder)
        }
        .shadow(
            color: .black.opacity(shadowOpacity(isHovered: isHovered, isPressed: isPressed, floatingMode: floatingMode, layoutMode: layoutMode)),
            radius: shadowRadius(isHovered: isHovered, isPressed: isPressed, floatingMode: floatingMode, layoutMode: layoutMode),
            y: shadowY(isHovered: isHovered, isPressed: isPressed, floatingMode: floatingMode, layoutMode: layoutMode),
        )
    }

    func cardInteractions(
        isHovered: Binding<Bool>,
        onTap: @escaping () -> Void,
        onDragStarted: (() -> NSItemProvider)?,
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
        playReadyChime: Bool,
        glassConfig: GlassConfig?,
    ) -> some View {
        animation(.easeInOut(duration: GlassConfig.shared.stateTransitionDuration), value: currentState)
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
                let now = Date()
                if ReadyChimePolicy.shouldPlay(
                    playReadyChime: playReadyChime,
                    oldState: oldValue,
                    newState: newValue,
                    lastChimeTime: lastChimeTime.wrappedValue,
                    now: now,
                    chimeCooldown: chimeCooldown,
                ) {
                    lastChimeTime.wrappedValue = now
                    ReadyChime.shared.play()
                }
                previousState.wrappedValue = newValue
            }
            .onChange(of: glassConfig?.previewState) { oldValue, newValue in
                if playReadyChime, newValue == .ready, oldValue != .ready {
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
    @ViewBuilder let content: Content

    func makeNSView(context _: Context) -> NonDraggableHostingView<Content> {
        NonDraggableHostingView(rootView: content)
    }

    func updateNSView(_ nsView: NonDraggableHostingView<Content>, context _: Context) {
        nsView.rootView = content
    }
}

struct WindowDragHandle<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: Content

    func makeNSView(context _: Context) -> DraggableHostingView<Content> {
        DraggableHostingView(rootView: content)
    }

    func updateNSView(_ nsView: DraggableHostingView<Content>, context _: Context) {
        nsView.rootView = content
    }
}

final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
