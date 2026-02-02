import SwiftUI

#if DEBUG
struct DebugActiveStateCard: View {
    @EnvironmentObject var appState: AppState

    private var mostRecentShellSummary: String {
        guard let shell = appState.shellStateStore.mostRecentShell else {
            return "none"
        }
        return "pid=\(shell.pid) cwd=\(shell.entry.cwd) tty=\(shell.entry.tty)"
    }

    private var shellCount: Int {
        appState.shellStateStore.state?.shells.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Debug: Active Resolver")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))

            Text("activeProject=\(appState.activeProjectPath ?? "nil")")
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))

            Text("activeSource=\(String(describing: appState.activeSource))")
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))

            Text("shells=\(shellCount) mostRecent=\(mostRecentShellSummary)")
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(10)
        .background(Color.black.opacity(0.35))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}
#endif
