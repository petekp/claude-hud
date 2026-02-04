import AppKit
import SwiftUI

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

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
                    // Use NSViewRepresentable for drag + double-click handling.
                    // Keep background clear so it matches the panel and avoids seams.
                    HeaderDragArea {
                        WindowFrameStore.shared.cycleCompactState()
                    }
                } else {
                    Color.hudBackground
                }
            }
        }
    }
}

// MARK: - Header Drag Area

/// NSViewRepresentable that handles both window dragging and double-click actions.
/// Unlike SwiftUI's onTapGesture(count: 2), this doesn't block mouseDown events
/// needed for window dragging via isMovableByWindowBackground.
struct HeaderDragArea: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context _: Context) -> HeaderDragNSView {
        let view = HeaderDragNSView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: HeaderDragNSView, context _: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

class HeaderDragNSView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Double-click: cycle compact state
            onDoubleClick?()
        } else {
            // Single click: initiate window drag
            window?.performDrag(with: event)
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        // Allow the system to also participate in window dragging
        true
    }
}
