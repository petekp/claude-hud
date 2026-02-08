import Foundation

@MainActor
struct TmuxClientAdapter: TmuxClient {
    let hasAnyClientAttachedHandler: () async -> Bool
    let getCurrentClientTtyHandler: () async -> String?
    let switchClientHandler: (String, String?) async -> Bool

    init(
        hasAnyClientAttached: @escaping () async -> Bool,
        getCurrentClientTty: @escaping () async -> String?,
        switchClient: @escaping (String, String?) async -> Bool,
    ) {
        hasAnyClientAttachedHandler = hasAnyClientAttached
        getCurrentClientTtyHandler = getCurrentClientTty
        switchClientHandler = switchClient
    }

    func hasAnyClientAttached() async -> Bool {
        await hasAnyClientAttachedHandler()
    }

    func getCurrentClientTty() async -> String? {
        await getCurrentClientTtyHandler()
    }

    func switchClient(to sessionName: String, clientTty: String?) async -> Bool {
        await switchClientHandler(sessionName, clientTty)
    }
}

@MainActor
struct TerminalDiscoveryAdapter: TerminalDiscovery {
    let activateTerminalByTTYHandler: (String) async -> Bool
    let activateAppByNameHandler: (String) -> Bool
    let isGhosttyRunningHandler: () -> Bool
    let countGhosttyWindowsHandler: () -> Int

    init(
        activateTerminalByTTY: @escaping (String) async -> Bool,
        activateAppByName: @escaping (String) -> Bool,
        isGhosttyRunning: @escaping () -> Bool,
        countGhosttyWindows: @escaping () -> Int,
    ) {
        activateTerminalByTTYHandler = activateTerminalByTTY
        activateAppByNameHandler = activateAppByName
        isGhosttyRunningHandler = isGhosttyRunning
        countGhosttyWindowsHandler = countGhosttyWindows
    }

    func activateTerminalByTTY(tty: String) async -> Bool {
        await activateTerminalByTTYHandler(tty)
    }

    func activateAppByName(_ appName: String) -> Bool {
        activateAppByNameHandler(appName)
    }

    func isGhosttyRunning() -> Bool {
        isGhosttyRunningHandler()
    }

    func countGhosttyWindows() -> Int {
        countGhosttyWindowsHandler()
    }
}

@MainActor
struct TerminalLauncherAdapter: TerminalLauncherClient {
    let launchTerminalWithTmuxHandler: (String) -> Void

    init(launchTerminalWithTmux: @escaping (String) -> Void) {
        launchTerminalWithTmuxHandler = launchTerminalWithTmux
    }

    func launchTerminalWithTmux(sessionName: String) {
        launchTerminalWithTmuxHandler(sessionName)
    }
}
