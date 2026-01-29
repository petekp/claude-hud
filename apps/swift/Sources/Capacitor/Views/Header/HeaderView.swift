import SwiftUI
import AppKit

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    private let progressiveBlurHeight: CGFloat = 30

    private var isOnListView: Bool {
        if case .list = appState.projectView { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header content
            HStack {
                // Show BackButton only when not on list view
                // Use conditional to avoid dead zones from invisible views blocking window drag
                if !isOnListView {
                    BackButton(title: "Projects") {
                        appState.showProjectList()
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }

                Spacer()

                AddProjectButton()
            }
            .padding(.horizontal, 12)
            .padding(.top, floatingMode ? 9 : 6)
            .padding(.bottom, 6)
            .background {
                if floatingMode {
                    VibrancyView(
                        material: .hudWindow,
                        blendingMode: .behindWindow,
                        isEmphasized: false,
                        forceDarkAppearance: true
                    )
                } else {
                    Color.hudBackground
                }
            }

            // Progressive blur zone - fades content below into the header
            ProgressiveBlurView(
                direction: .down,
                height: progressiveBlurHeight,
                material: floatingMode ? .hudWindow : .windowBackground
            )
            .allowsHitTesting(false)
        }
    }
}
