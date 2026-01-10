import SwiftUI

@main
struct ClaudeHUDApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(width: 360, height: 700)
        }
        .defaultSize(width: 360, height: 700)
    }
}
