import SwiftUI
import AppKit

struct IdeaCaptureOverlay: View {
    @Binding var isPresented: Bool
    let projectName: String
    let onCapture: (String) -> Result<Void, Error>

    @State private var ideaText: String = ""
    @State private var captureError: String?
    @State private var isCapturing = false
    @State private var appeared = false
    @State private var returnMonitor: Any?
    @State private var showingSuccess = false
    @FocusState private var isTextFieldFocused: Bool

    private enum Layout {
        static let maxTextWidth: CGFloat = 500
        static let horizontalPadding: CGFloat = 48
        static let cornerPadding: CGFloat = 24
    }

    private var hasText: Bool {
        !ideaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            // Main content - centered text area
            VStack(spacing: 16) {
                textArea

                if let error = captureError {
                    errorBanner(error)
                }
            }
            .frame(maxWidth: Layout.maxTextWidth)
            .padding(.horizontal, Layout.horizontalPadding)

            // Corner elements
            VStack {
                HStack {
                    // Top-left: Project name
                    Text(projectName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(Layout.cornerPadding)

                    Spacer()

                    // Top-right: Cancel button
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(Layout.cornerPadding)
                }

                Spacer()

                HStack {
                    // Bottom-left: Keyboard hints
                    Text("⏎ Save  ⇧⏎ Save & add another  ⎋ Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(Layout.cornerPadding)

                    Spacer()

                    // Bottom-right: Save button
                    Button(action: captureAndClose) {
                        HStack(spacing: showingSuccess ? 0 : 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                            if !showingSuccess {
                                Text("Save")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                        .foregroundColor(showingSuccess ? .white : (hasText ? .white : .white.opacity(0.4)))
                        .padding(.horizontal, showingSuccess ? 14 : 18)
                        .padding(.vertical, 10)
                        .background(showingSuccess ? Color.green : (hasText ? Color.blue : Color.white.opacity(0.1)))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: showingSuccess)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasText || isCapturing || showingSuccess)
                    .padding(Layout.cornerPadding)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                appeared = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isTextFieldFocused = true
            }
            installReturnMonitor()
        }
        .onDisappear {
            removeReturnMonitor()
        }
    }

    private func installReturnMonitor() {
        returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Return key (keyCode 36)
            if event.keyCode == 36 {
                let hasShift = event.modifierFlags.contains(.shift)

                if hasShift {
                    captureAndClear()
                } else {
                    captureAndClose()
                }
                return nil // Consume the event
            }
            return event
        }
    }

    private func removeReturnMonitor() {
        if let monitor = returnMonitor {
            NSEvent.removeMonitor(monitor)
            returnMonitor = nil
        }
    }

    private var textArea: some View {
        ZStack(alignment: .top) {
            TextEditor(text: $ideaText)
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .multilineTextAlignment(.center)
                .frame(minHeight: 80, maxHeight: 200)
                .focused($isTextFieldFocused)
                .disabled(isCapturing)

            if ideaText.isEmpty {
                Text("What's on your mind?")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .offset(y: -2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.red)
            Text(error)
                .font(.system(size: 14))
                .foregroundColor(.red.opacity(0.9))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func captureAndClose() {
        guard capture() else { return }
        showSuccess {
            isPresented = false
        }
    }

    private func captureAndClear() {
        guard capture() else { return }
        showSuccess {
            ideaText = ""
            showingSuccess = false
            isTextFieldFocused = true
        }
    }

    private func showSuccess(then action: @escaping () -> Void) {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
            showingSuccess = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            action()
        }
    }

    private func capture() -> Bool {
        let trimmed = ideaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        isCapturing = true
        captureError = nil

        let result = onCapture(trimmed)

        isCapturing = false

        switch result {
        case .success:
            return true
        case .failure(let error):
            captureError = error.localizedDescription
            return false
        }
    }

    private func cancel() {
        isPresented = false
    }
}

struct IdeaCaptureModalOverlay: View {
    @Binding var isPresented: Bool
    let projectName: String
    let onCapture: (String) -> Result<Void, Error>

    @State private var escapeMonitor: Any?

    var body: some View {
        ZStack {
            if isPresented {
                scrimBackground
                    .onTapGesture {
                        isPresented = false
                    }

                IdeaCaptureOverlay(
                    isPresented: $isPresented,
                    projectName: projectName,
                    onCapture: onCapture
                )
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.92), value: isPresented)
        .onChange(of: isPresented) { _, newValue in
            if newValue {
                installKeyboardMonitors()
            } else {
                removeKeyboardMonitors()
            }
        }
        .onDisappear {
            removeKeyboardMonitors()
        }
    }

    private var scrimBackground: some View {
        ZStack {
            Color.black.opacity(0.5)

            VibrancyView(
                material: .fullScreenUI,
                blendingMode: .behindWindow,
                isEmphasized: false,
                forceDarkAppearance: true
            )
            .opacity(0.4)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func installKeyboardMonitors() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                isPresented = false
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitors() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}

// Keep the old name as an alias for compatibility
typealias IdeaCapturePopover = IdeaCaptureOverlay
