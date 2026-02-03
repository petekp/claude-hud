import Foundation

@MainActor
struct TmuxClientAdapter: TmuxClient {
    let hasAnyClientAttachedHandler: () async -> Bool
    let getCurrentClientTtyHandler: () async -> String?
    let switchClientHandler: (String) async -> Bool

    init(
        hasAnyClientAttached: @escaping () async -> Bool,
        getCurrentClientTty: @escaping () async -> String?,
        switchClient: @escaping (String) async -> Bool
    ) {
        self.hasAnyClientAttachedHandler = hasAnyClientAttached
        self.getCurrentClientTtyHandler = getCurrentClientTty
        self.switchClientHandler = switchClient
    }

    func hasAnyClientAttached() async -> Bool {
        await hasAnyClientAttachedHandler()
    }

    func getCurrentClientTty() async -> String? {
        await getCurrentClientTtyHandler()
    }

    func switchClient(to sessionName: String) async -> Bool {
        await switchClientHandler(sessionName)
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
        countGhosttyWindows: @escaping () -> Int
    ) {
        self.activateTerminalByTTYHandler = activateTerminalByTTY
        self.activateAppByNameHandler = activateAppByName
        self.isGhosttyRunningHandler = isGhosttyRunning
        self.countGhosttyWindowsHandler = countGhosttyWindows
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
        self.launchTerminalWithTmuxHandler = launchTerminalWithTmux
    }

    func launchTerminalWithTmux(sessionName: String) {
        launchTerminalWithTmuxHandler(sessionName)
    }
}
