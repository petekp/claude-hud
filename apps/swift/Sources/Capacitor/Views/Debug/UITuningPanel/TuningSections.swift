import SwiftUI

#if DEBUG

    // MARK: - Card Appearance

    struct CardAppearanceSection: View {
        @ObservedObject var config: GlassConfig

        var body: some View {
            Group(content: {
                StickySection(title: "Background", onReset: resetBackground) {
                    TuningRow(label: "Tint Opacity", value: $config.cardTintOpacity, range: 0 ... 1)
                    TuningRow(label: "Corner Radius", value: $config.cardCornerRadius, range: 4 ... 24)
                }

                StickySection(title: "Border & Highlight", onReset: resetBorder) {
                    TuningRow(label: "Border Opacity", value: $config.cardBorderOpacity, range: 0 ... 1)
                    TuningRow(label: "Highlight Opacity", value: $config.cardHighlightOpacity, range: 0 ... 0.5)

                    SectionDivider()

                    Text("Hover State")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    TuningRow(label: "Hover Border", value: $config.cardHoverBorderOpacity, range: 0 ... 1)
                    TuningRow(label: "Hover Highlight", value: $config.cardHoverHighlightOpacity, range: 0 ... 0.5)
                }
            })
        }

        private func resetBackground() {
            config.cardTintOpacity = 0.46
            config.cardCornerRadius = 17.59
        }

        private func resetBorder() {
            config.cardBorderOpacity = 0.18
            config.cardHighlightOpacity = 0.10
            config.cardHoverBorderOpacity = 0.34
            config.cardHoverHighlightOpacity = 0.15
        }
    }

    // MARK: - Card Material

    struct CardMaterialSection: View {
        @ObservedObject var config: GlassConfig

        var body: some View {
            Group(content: {
                StickySection(title: "Vibrancy (NSVisualEffectView)", onReset: resetVibrancy) {
                    TuningPickerRow(
                        label: "Material",
                        selection: $config.cardMaterialType,
                        options: [
                            ("HUD Window", 0),
                            ("Popover", 1),
                            ("Menu", 2),
                            ("Sidebar", 3),
                            ("Full Screen UI", 4),
                        ]
                    )

                    TuningPickerRow(
                        label: "Blending Mode",
                        selection: $config.cardBlendingMode,
                        options: [
                            ("Behind Window", 0),
                            ("Within Window", 1),
                        ]
                    )

                    TuningToggleRow(label: "Emphasized", isOn: $config.cardEmphasized)
                    TuningToggleRow(label: "Force Dark", isOn: $config.cardForceDarkAppearance)
                }

                StickySection(title: "SwiftUI Blend Mode", onReset: resetBlendMode) {
                    TuningPickerRow(
                        label: "Highlight Blend",
                        selection: $config.cardSwiftUIBlendMode,
                        options: [
                            ("Normal", 0),
                            ("Plus Lighter", 1),
                            ("Soft Light", 2),
                            ("Overlay", 3),
                            ("Screen", 4),
                            ("Multiply", 5),
                        ]
                    )
                }
            })
        }

        private func resetVibrancy() {
            config.cardMaterialType = 0
            config.cardBlendingMode = 1
            config.cardEmphasized = true
            config.cardForceDarkAppearance = true
        }

        private func resetBlendMode() {
            config.cardSwiftUIBlendMode = 5
        }
    }

    // MARK: - Card Interactions

    struct CardInteractionsSection: View {
        @ObservedObject var config: GlassConfig

        var body: some View {
            Group(content: {
                StickySection(title: "Idle State", onReset: resetIdle) {
                    TuningRow(label: "Scale", value: $config.cardIdleScale, range: 0.9 ... 1.1)
                    TuningRow(label: "Shadow Opacity", value: $config.cardIdleShadowOpacity, range: 0 ... 0.5)
                    TuningRow(label: "Shadow Radius", value: $config.cardIdleShadowRadius, range: 0 ... 20)
                    TuningRow(label: "Shadow Y", value: $config.cardIdleShadowY, range: 0 ... 10)
                }

                StickySection(title: "Hover State", onReset: resetHover) {
                    TuningRow(label: "Scale", value: $config.cardHoverScale, range: 0.9 ... 1.1)

                    SectionDivider()

                    Text("Spring Animation")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    TuningRow(label: "Response", value: $config.cardHoverSpringResponse, range: 0.05 ... 0.5)
                    TuningRow(label: "Damping", value: $config.cardHoverSpringDamping, range: 0.3 ... 1.0)

                    SectionDivider()

                    Text("Shadow")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    TuningRow(label: "Shadow Opacity", value: $config.cardHoverShadowOpacity, range: 0 ... 0.5)
                    TuningRow(label: "Shadow Radius", value: $config.cardHoverShadowRadius, range: 0 ... 30)
                    TuningRow(label: "Shadow Y", value: $config.cardHoverShadowY, range: 0 ... 15)
                }

                StickySection(title: "Pressed State", onReset: resetPressed) {
                    TuningRow(label: "Scale", value: $config.cardPressedScale, range: 0.85 ... 1.0)

                    SectionDivider()

                    Text("Spring Animation")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    TuningRow(label: "Response", value: $config.cardPressedSpringResponse, range: 0.05 ... 0.3)
                    TuningRow(label: "Damping", value: $config.cardPressedSpringDamping, range: 0.3 ... 1.0)

                    SectionDivider()

                    Text("Shadow")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    TuningRow(label: "Shadow Opacity", value: $config.cardPressedShadowOpacity, range: 0 ... 0.3)
                    TuningRow(label: "Shadow Radius", value: $config.cardPressedShadowRadius, range: 0 ... 10)
                    TuningRow(label: "Shadow Y", value: $config.cardPressedShadowY, range: 0 ... 5)
                }
            })
        }

        private func resetIdle() {
            config.cardIdleScale = 1.0
            config.cardIdleShadowOpacity = 0.17
            config.cardIdleShadowRadius = 8.07
            config.cardIdleShadowY = 3.89
        }

        private func resetHover() {
            config.cardHoverScale = 1.01
            config.cardHoverSpringResponse = 0.26
            config.cardHoverSpringDamping = 0.90
            config.cardHoverShadowOpacity = 0.2
            config.cardHoverShadowRadius = 12.0
            config.cardHoverShadowY = 4.0
        }

        private func resetPressed() {
            config.cardPressedScale = 1.00
            config.cardPressedSpringResponse = 0.09
            config.cardPressedSpringDamping = 0.64
            config.cardPressedShadowOpacity = 0.12
            config.cardPressedShadowRadius = 2.0
            config.cardPressedShadowY = 1.0
        }
    }

    // MARK: - State Transitions

    struct StateTransitionsSection: View {
        @ObservedObject var config: GlassConfig

        var body: some View {
            Group(content: {
                StickySection(title: "Timing", onReset: resetTiming) {
                    TuningRow(label: "State Change", value: $config.stateTransitionDuration, range: 0.05 ... 0.5)
                    TuningRow(label: "Glow Fade", value: $config.glowFadeDuration, range: 0.05 ... 0.4)
                    TuningRow(label: "Border Delay", value: $config.glowBorderDelay, range: 0 ... 0.1)
                    TuningRow(label: "Hover Speed", value: $config.hoverTransitionDuration, range: 0.05 ... 0.3)
                }

                StickySection(title: "Card List Stagger", onReset: resetStagger) {
                    TuningRow(label: "Insert Stagger", value: $config.cardInsertStagger, range: 0 ... 0.1)
                    TuningRow(label: "Removal Duration", value: $config.cardRemovalDuration, range: 0.05 ... 0.3)
                    TuningRow(label: "Paused Stagger", value: $config.pausedCardStagger, range: 0 ... 0.08)

                    SectionDivider()

                    Text("Insert Spring")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    TuningRow(label: "Response", value: $config.cardInsertSpringResponse, range: 0.1 ... 0.5)
                    TuningRow(label: "Damping", value: $config.cardInsertSpringDamping, range: 0.5 ... 1.0)
                }

                StickySection(title: "Section Toggle", onReset: resetSectionToggle) {
                    TuningRow(label: "Spring Response", value: $config.sectionToggleSpringResponse, range: 0.1 ... 0.4)
                }
            })
        }

        private func resetTiming() {
            config.stateTransitionDuration = 0.18
            config.glowFadeDuration = 0.15
            config.glowBorderDelay = 0.03
            config.hoverTransitionDuration = 0.12
        }

        private func resetStagger() {
            config.cardInsertStagger = 0.04
            config.cardRemovalDuration = 0.15
            config.cardInsertSpringResponse = 0.25
            config.cardInsertSpringDamping = 0.8
            config.pausedCardStagger = 0.025
        }

        private func resetSectionToggle() {
            config.sectionToggleSpringResponse = 0.18
        }
    }

    // MARK: - Card Layout

    struct CardLayoutSection: View {
        @ObservedObject var config: GlassConfig

        var body: some View {
            Group(content: {
                StickySection(title: "List Layout", onReset: resetList) {
                    TuningRow(label: "Card Spacing", value: $config.cardListSpacing, range: 0 ... 24, step: 1, format: "%.0f")
                    TuningRow(label: "Card Padding H", value: $config.cardPaddingHorizontal, range: 4 ... 24, step: 1, format: "%.0f")
                    TuningRow(label: "Card Padding V", value: $config.cardPaddingVertical, range: 4 ... 24, step: 1, format: "%.0f")
                    TuningRow(label: "List Padding H", value: $config.listHorizontalPadding, range: 0 ... 32, step: 1, format: "%.0f")
                }

                StickySection(title: "Dock Layout", onReset: resetDock) {
                    TuningRow(label: "Card Spacing", value: $config.dockCardSpacing, range: 0 ... 32, step: 1, format: "%.0f")
                    TuningRow(label: "Card Padding H", value: $config.dockCardPaddingHorizontal, range: 4 ... 24, step: 1, format: "%.0f")
                    TuningRow(label: "Card Padding V", value: $config.dockCardPaddingVertical, range: 4 ... 24, step: 1, format: "%.0f")
                    TuningRow(label: "Dock Padding H", value: $config.dockHorizontalPadding, range: 0 ... 32, step: 1, format: "%.0f")
                }
            })
        }

        private func resetList() {
            config.cardListSpacing = 8.0
            config.cardPaddingHorizontal = 12.0
            config.cardPaddingVertical = 12.0
            config.listHorizontalPadding = 12.0
        }

        private func resetDock() {
            config.dockCardSpacing = 14.0
            config.dockCardPaddingHorizontal = 14.0
            config.dockCardPaddingVertical = 14.0
            config.dockHorizontalPadding = 16.0
        }
    }

    // MARK: - Card State Effects

    struct CardStateEffectsSection: View {
        @ObservedObject var config: GlassConfig

        @ViewBuilder
        var body: some View {
            StickySection(title: "Ready — Ripple", onReset: resetReady) {
                TuningRow(label: "Speed", value: $config.rippleSpeed, range: 1 ... 10)
                TuningRow(label: "Count", value: .init(get: { Double(config.rippleCount) }, set: { config.rippleCount = Int($0) }), range: 1 ... 8, format: "%.0f")
                TuningRow(label: "Max Opacity", value: $config.rippleMaxOpacity, range: 0 ... 1)
                TuningRow(label: "Line Width", value: $config.rippleLineWidth, range: 5 ... 60)
                TuningRow(label: "Blur Amount", value: $config.rippleBlurAmount, range: 0 ... 60)
                TuningRow(label: "Origin X", value: $config.rippleOriginX, range: 0 ... 1)
                TuningRow(label: "Origin Y", value: $config.rippleOriginY, range: 0 ... 1)
                TuningRow(label: "Fade In Zone", value: $config.rippleFadeInZone, range: 0 ... 0.5)
                TuningRow(label: "Fade Out Power", value: $config.rippleFadeOutPower, range: 1 ... 10)

                SectionDivider()

                Text("Border Glow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Inner Width", value: $config.borderGlowInnerWidth, range: 0.1 ... 2)
                TuningRow(label: "Outer Width", value: $config.borderGlowOuterWidth, range: 0.5 ... 6)
                TuningRow(label: "Inner Blur", value: $config.borderGlowInnerBlur, range: 0 ... 4)
                TuningRow(label: "Outer Blur", value: $config.borderGlowOuterBlur, range: 0 ... 8)
                TuningRow(label: "Base Opacity", value: $config.borderGlowBaseOpacity, range: 0 ... 1)
                TuningRow(label: "Pulse Intensity", value: $config.borderGlowPulseIntensity, range: 0 ... 1)
            }

            StickySection(title: "Working — Stripes", onReset: resetWorkingStripes) {
                TuningRow(label: "Stripe Width", value: $config.workingStripeWidth, range: 8 ... 48)
                TuningRow(label: "Stripe Spacing", value: $config.workingStripeSpacing, range: 12 ... 80)
                TuningRow(label: "Stripe Angle", value: $config.workingStripeAngle, range: 20 ... 70)
                TuningRow(label: "Scroll Speed", value: $config.workingScrollSpeed, range: 1 ... 10)
                TuningRow(label: "Stripe Opacity", value: $config.workingStripeOpacity, range: 0 ... 1)

                SectionDivider()

                Text("Emissive Glow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Glow Intensity", value: $config.workingGlowIntensity, range: 0 ... 3)
                TuningRow(label: "Glow Blur", value: $config.workingGlowBlurRadius, range: 0 ... 30)
                TuningRow(label: "Core Brightness", value: $config.workingCoreBrightness, range: 0 ... 2)
                TuningRow(label: "Gradient Falloff", value: $config.workingGradientFalloff, range: 0 ... 1)

                SectionDivider()

                Text("Vignette")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Inner Radius", value: $config.workingVignetteInnerRadius, range: 0 ... 0.8)
                TuningRow(label: "Outer Radius", value: $config.workingVignetteOuterRadius, range: 0 ... 2)
                TuningRow(label: "Center Opacity", value: $config.workingVignetteCenterOpacity, range: 0 ... 0.5)

                SectionDivider()

                Text("Vignette Color")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                HStack {
                    Circle()
                        .fill(Color(hue: config.workingVignetteColorHue, saturation: config.workingVignetteColorSaturation, brightness: config.workingVignetteColorBrightness))
                        .frame(width: 14, height: 14)
                        .shadow(color: Color(hue: config.workingVignetteColorHue, saturation: config.workingVignetteColorSaturation, brightness: config.workingVignetteColorBrightness).opacity(0.5), radius: 4)
                    Spacer()
                }

                TuningRow(label: "Hue", value: $config.workingVignetteColorHue, range: 0 ... 1)
                TuningRow(label: "Saturation", value: $config.workingVignetteColorSaturation, range: 0 ... 1)
                TuningRow(label: "Brightness", value: $config.workingVignetteColorBrightness, range: 0 ... 1)
                TuningRow(label: "Intensity", value: $config.workingVignetteColorIntensity, range: 0 ... 1)
            }

            StickySection(title: "Working — Border", onReset: resetWorkingBorder) {
                TuningRow(label: "Border Width", value: $config.workingBorderWidth, range: 0.5 ... 4)
                TuningRow(label: "Base Opacity", value: $config.workingBorderBaseOpacity, range: 0 ... 0.6)
                TuningRow(label: "Pulse Intensity", value: $config.workingBorderPulseIntensity, range: 0 ... 0.5)
                TuningRow(label: "Pulse Speed", value: $config.workingBorderPulseSpeed, range: 0.5 ... 5)
                TuningRow(label: "Blur Amount", value: $config.workingBorderBlurAmount, range: 0 ... 12)
            }

            StickySection(title: "Waiting — Pulse", onReset: resetWaiting) {
                TuningRow(label: "Cycle Length", value: $config.waitingCycleLength, range: 1 ... 5)
                TuningRow(label: "1st Pulse Duration", value: $config.waitingFirstPulseDuration, range: 0.05 ... 0.5)
                TuningRow(label: "1st Pulse Fade", value: $config.waitingFirstPulseFadeOut, range: 0.1 ... 0.6)
                TuningRow(label: "2nd Pulse Delay", value: $config.waitingSecondPulseDelay, range: 0 ... 0.5)
                TuningRow(label: "2nd Pulse Duration", value: $config.waitingSecondPulseDuration, range: 0.05 ... 0.5)
                TuningRow(label: "2nd Pulse Fade", value: $config.waitingSecondPulseFadeOut, range: 0.1 ... 0.6)
                TuningRow(label: "1st Pulse Intensity", value: $config.waitingFirstPulseIntensity, range: 0 ... 1)
                TuningRow(label: "2nd Pulse Intensity", value: $config.waitingSecondPulseIntensity, range: 0 ... 1)
                TuningRow(label: "Max Opacity", value: $config.waitingMaxOpacity, range: 0 ... 1)
                TuningRow(label: "Blur Amount", value: $config.waitingBlurAmount, range: 0 ... 60)
                TuningRow(label: "Pulse Scale", value: $config.waitingPulseScale, range: 1 ... 3)
                TuningRow(label: "Scale Amount", value: $config.waitingScaleAmount, range: 0 ... 1)
                TuningRow(label: "Origin X", value: $config.waitingOriginX, range: 0 ... 1)
                TuningRow(label: "Origin Y", value: $config.waitingOriginY, range: 0 ... 1)
            }

            StickySection(title: "Waiting — Border", onReset: resetWaitingBorder) {
                TuningRow(label: "Base Opacity", value: $config.waitingBorderBaseOpacity, range: 0 ... 0.5)
                TuningRow(label: "Pulse Opacity", value: $config.waitingBorderPulseOpacity, range: 0 ... 1)
                TuningRow(label: "Inner Width", value: $config.waitingBorderInnerWidth, range: 0.5 ... 4)
                TuningRow(label: "Outer Width", value: $config.waitingBorderOuterWidth, range: 1 ... 8)
                TuningRow(label: "Outer Blur", value: $config.waitingBorderOuterBlur, range: 0 ... 12)
            }
        }

        private func resetReady() {
            config.rippleSpeed = 8.61
            config.rippleCount = 3
            config.rippleMaxOpacity = 1.00
            config.rippleLineWidth = 60.00
            config.rippleBlurAmount = 33.23
            config.rippleOriginX = 0.00
            config.rippleOriginY = 1.00
            config.rippleFadeInZone = 0.17
            config.rippleFadeOutPower = 3.10
            config.borderGlowInnerWidth = 2.00
            config.borderGlowOuterWidth = 1.73
            config.borderGlowInnerBlur = 3.01
            config.borderGlowOuterBlur = 0.00
            config.borderGlowBaseOpacity = 0.45
            config.borderGlowPulseIntensity = 1.00
        }

        private func resetWorkingStripes() {
            config.workingStripeWidth = 24.0
            config.workingStripeSpacing = 38.49
            config.workingStripeAngle = 41.30
            config.workingScrollSpeed = 4.81
            config.workingStripeOpacity = 0.50
            config.workingGlowIntensity = 1.50
            config.workingGlowBlurRadius = 11.46
            config.workingCoreBrightness = 0.71
            config.workingGradientFalloff = 0.32
            config.workingVignetteInnerRadius = 0.02
            config.workingVignetteOuterRadius = 0.48
            config.workingVignetteCenterOpacity = 0.03
            config.workingVignetteColorHue = 0.05
            config.workingVignetteColorSaturation = 0.67
            config.workingVignetteColorBrightness = 0.39
            config.workingVignetteColorIntensity = 0.47
        }

        private func resetWorkingBorder() {
            config.workingBorderWidth = 1.0
            config.workingBorderBaseOpacity = 0.35
            config.workingBorderPulseIntensity = 0.50
            config.workingBorderPulseSpeed = 2.21
            config.workingBorderBlurAmount = 8.0
        }

        private func resetWaiting() {
            config.waitingCycleLength = 1.68
            config.waitingFirstPulseDuration = 0.17
            config.waitingFirstPulseFadeOut = 0.17
            config.waitingSecondPulseDelay = 0.00
            config.waitingSecondPulseDuration = 0.17
            config.waitingSecondPulseFadeOut = 0.48
            config.waitingFirstPulseIntensity = 0.34
            config.waitingSecondPulseIntensity = 0.47
            config.waitingMaxOpacity = 0.34
            config.waitingBlurAmount = 0.0
            config.waitingPulseScale = 2.22
            config.waitingScaleAmount = 0.30
            config.waitingOriginX = 1.00
            config.waitingOriginY = 0.00
        }

        private func resetWaitingBorder() {
            config.waitingBorderBaseOpacity = 0.12
            config.waitingBorderPulseOpacity = 0.37
            config.waitingBorderInnerWidth = 0.50
            config.waitingBorderOuterWidth = 1.86
            config.waitingBorderOuterBlur = 0.8
        }
    }

    // MARK: - Panel Background

    struct PanelBackgroundSection: View {
        @ObservedObject var config: GlassConfig

        var body: some View {
            Group(content: {
                StickySection(title: "Panel Glass", onReset: resetPanel) {
                    TuningRow(label: "Tint Opacity", value: $config.panelTintOpacity, range: 0 ... 1)
                    TuningRow(label: "Corner Radius", value: $config.panelCornerRadius, range: 8 ... 32)
                    TuningRow(label: "Border Opacity", value: $config.panelBorderOpacity, range: 0 ... 1)
                    TuningRow(label: "Highlight Opacity", value: $config.panelHighlightOpacity, range: 0 ... 0.3)
                    TuningRow(label: "Top Highlight", value: $config.panelTopHighlightOpacity, range: 0 ... 0.5)

                    SectionDivider()

                    Text("Shadow")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    TuningRow(label: "Shadow Opacity", value: $config.panelShadowOpacity, range: 0 ... 0.5)
                    TuningRow(label: "Shadow Radius", value: $config.panelShadowRadius, range: 0 ... 30)
                    TuningRow(label: "Shadow Y", value: $config.panelShadowY, range: 0 ... 15)
                }
            })
        }

        private func resetPanel() {
            config.panelTintOpacity = 0.18
            config.panelCornerRadius = 18.87
            config.panelBorderOpacity = 0.14
            config.panelHighlightOpacity = 0.12
            config.panelTopHighlightOpacity = 0.19
            config.panelShadowOpacity = 0.00
            config.panelShadowRadius = 0
            config.panelShadowY = 0
        }
    }

    // MARK: - Panel Material

    struct PanelMaterialSection: View {
        @ObservedObject var config: GlassConfig

        var body: some View {
            Group(content: {
                StickySection(title: "Material Settings", onReset: resetMaterial) {
                    TuningToggleRow(label: "Emphasized Material", isOn: $config.useEmphasizedMaterial)

                    TuningPickerRow(
                        label: "Material Type",
                        selection: $config.materialType,
                        options: [
                            ("HUD Window", 0),
                            ("Popover", 1),
                            ("Menu", 2),
                            ("Sidebar", 3),
                            ("Full Screen UI", 4),
                        ]
                    )
                }
            })
        }

        private func resetMaterial() {
            config.useEmphasizedMaterial = true
            config.materialType = 0
        }
    }

    // MARK: - Status Colors

    struct StatusColorsSection: View {
        @ObservedObject var config: GlassConfig

        var body: some View {
            Group(content: {
                StickySection(title: "Ready", onReset: resetReady) {
                    TuningColorRow(
                        label: "Ready Color",
                        hue: $config.statusReadyHue,
                        saturation: $config.statusReadySaturation,
                        brightness: $config.statusReadyBrightness
                    )
                }

                StickySection(title: "Working", onReset: resetWorking) {
                    TuningColorRow(
                        label: "Working Color",
                        hue: $config.statusWorkingHue,
                        saturation: $config.statusWorkingSaturation,
                        brightness: $config.statusWorkingBrightness
                    )
                }

                StickySection(title: "Waiting", onReset: resetWaiting) {
                    TuningColorRow(
                        label: "Waiting Color",
                        hue: $config.statusWaitingHue,
                        saturation: $config.statusWaitingSaturation,
                        brightness: $config.statusWaitingBrightness
                    )
                }

                StickySection(title: "Compacting", onReset: resetCompacting) {
                    TuningColorRow(
                        label: "Compacting Color",
                        hue: $config.statusCompactingHue,
                        saturation: $config.statusCompactingSaturation,
                        brightness: $config.statusCompactingBrightness
                    )
                }

                StickySection(title: "Idle", onReset: resetIdle) {
                    TuningRow(label: "Opacity", value: $config.statusIdleOpacity, range: 0 ... 1)
                }
            })
        }

        private func resetReady() {
            config.statusReadyHue = 0.406
            config.statusReadySaturation = 0.83
            config.statusReadyBrightness = 1.00
        }

        private func resetWorking() {
            config.statusWorkingHue = 0.103
            config.statusWorkingSaturation = 1.00
            config.statusWorkingBrightness = 1.00
        }

        private func resetWaiting() {
            config.statusWaitingHue = 0.026
            config.statusWaitingSaturation = 0.58
            config.statusWaitingBrightness = 1.00
        }

        private func resetCompacting() {
            config.statusCompactingHue = 0.670
            config.statusCompactingSaturation = 0.50
            config.statusCompactingBrightness = 1.00
        }

        private func resetIdle() {
            config.statusIdleOpacity = 0.40
        }
    }

    // MARK: - Logo Appearance

    struct LogoAppearanceSection: View {
        @ObservedObject var config: GlassConfig

        var body: some View {
            Group(content: {
                StickySection(title: "Size & Opacity", onReset: resetSizeOpacity) {
                    TuningRow(label: "Scale", value: $config.logoScale, range: 0.5 ... 3.0)
                    TuningRow(label: "Opacity", value: $config.logoOpacity, range: 0 ... 1)
                }

                StickySection(title: "SwiftUI Blend Mode", onReset: resetBlendMode) {
                    TuningPickerRow(
                        label: "Blend Mode",
                        selection: $config.logoSwiftUIBlendMode,
                        options: [
                            ("Normal", 0),
                            ("Plus Lighter", 1),
                            ("Soft Light", 2),
                            ("Overlay", 3),
                            ("Screen", 4),
                            ("Multiply", 5),
                            ("Difference", 6),
                            ("Color Dodge", 7),
                            ("Hard Light", 8),
                            ("Luminosity", 9),
                        ]
                    )
                }

                StickySection(title: "Vibrancy (NSVisualEffectView)", onReset: resetVibrancy) {
                    TuningToggleRow(label: "Use Vibrancy", isOn: $config.logoUseVibrancy)

                    if config.logoUseVibrancy {
                        TuningPickerRow(
                            label: "Material",
                            selection: $config.logoMaterialType,
                            options: [
                                ("HUD Window", 0),
                                ("Popover", 1),
                                ("Menu", 2),
                                ("Sidebar", 3),
                                ("Full Screen UI", 4),
                            ]
                        )

                        TuningPickerRow(
                            label: "Blending Mode",
                            selection: $config.logoBlendingMode,
                            options: [
                                ("Behind Window", 0),
                                ("Within Window", 1),
                            ]
                        )

                        TuningToggleRow(label: "Emphasized", isOn: $config.logoEmphasized)
                        TuningToggleRow(label: "Force Dark", isOn: $config.logoForceDarkAppearance)
                    }
                }
            })
        }

        private func resetSizeOpacity() {
            config.logoScale = 0.90
            config.logoOpacity = 1.0
        }

        private func resetBlendMode() {
            config.logoSwiftUIBlendMode = 2
        }

        private func resetVibrancy() {
            config.logoUseVibrancy = true
            config.logoMaterialType = 0
            config.logoBlendingMode = 1
            config.logoEmphasized = false
            config.logoForceDarkAppearance = true
        }
    }

#endif
