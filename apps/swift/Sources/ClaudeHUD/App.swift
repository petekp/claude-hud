import SwiftUI
import AppKit

@main
struct ClaudeHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @AppStorage("floatingMode") private var floatingMode = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environment(\.floatingMode, floatingMode)
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 500,
                       minHeight: 400, idealHeight: 700, maxHeight: .infinity)
                .background(FloatingWindowConfigurator(enabled: floatingMode))
        }
        .defaultSize(width: 360, height: 700)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appSettings) {
                Toggle("Floating Mode", isOn: $floatingMode)
                    .keyboardShortcut("T", modifiers: [.command, .shift])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app can be activated and receive focus
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Ensure window becomes key when app activates
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct FloatingWindowConfigurator: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.configureWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.configureWindow(nsView.window)
        }
    }

    private func configureWindow(_ window: NSWindow?) {
        guard let window = window else { return }

        if enabled {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.titled)
            window.isMovableByWindowBackground = true
            window.titlebarSeparatorStyle = .none

            // Hide traffic light buttons
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            // Clear the content view's background layer as well
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = .clear

                // Also clear any SwiftUI hosting view backgrounds
                clearBackgrounds(of: contentView)
            }
        } else {
            window.styleMask.insert(.titled)
            window.isOpaque = true
            window.backgroundColor = NSColor(Color.hudBackground)
            window.hasShadow = true
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.styleMask.remove(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.titlebarSeparatorStyle = .automatic

            // Show traffic light buttons
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
        }
    }

    private func clearBackgrounds(of view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear

        for subview in view.subviews {
            clearBackgrounds(of: subview)
        }
    }
}

private struct FloatingModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var floatingMode: Bool {
        get { self[FloatingModeKey.self] }
        set { self[FloatingModeKey.self] = newValue }
    }
}
