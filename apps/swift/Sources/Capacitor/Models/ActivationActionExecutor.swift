import Foundation

@MainActor
protocol ActivationActionDependencies: AnyObject {
    func activateByTty(tty: String, terminalType: TerminalType) async -> Bool
    func activateApp(appName: String) -> Bool
    func activateKittyWindow(shellPid: UInt32) -> Bool
    func activateIdeWindow(ideType: IdeType, projectPath: String) async -> Bool
    func switchTmuxSession(sessionName: String, projectPath: String) async -> Bool
    func ensureTmuxSession(sessionName: String, projectPath: String) async -> Bool
    func activateHostThenSwitchTmux(hostTty: String, sessionName: String, projectPath: String) async -> Bool
    func launchTerminalWithTmux(sessionName: String, projectPath: String) -> Bool
    func launchNewTerminal(projectPath: String, projectName: String) -> Bool
    func activatePriorityFallback() -> Bool
}

protocol TmuxClient {
    func hasAnyClientAttached() async -> Bool
    func getCurrentClientTty() async -> String?
    func switchClient(to sessionName: String) async -> Bool
}

@MainActor
protocol TerminalDiscovery {
    func activateTerminalByTTY(tty: String) async -> Bool
    func activateAppByName(_ appName: String) -> Bool
    func isGhosttyRunning() -> Bool
    func countGhosttyWindows() -> Int
}

@MainActor
protocol TerminalLauncherClient {
    func launchTerminalWithTmux(sessionName: String)
}

@MainActor
final class ActivationActionExecutor {
    private weak var dependencies: ActivationActionDependencies?
    private let tmuxClient: TmuxClient
    private let terminalDiscovery: TerminalDiscovery
    private let terminalLauncher: TerminalLauncherClient

    init(
        dependencies: ActivationActionDependencies,
        tmuxClient: TmuxClient,
        terminalDiscovery: TerminalDiscovery,
        terminalLauncher: TerminalLauncherClient
    ) {
        self.dependencies = dependencies
        self.tmuxClient = tmuxClient
        self.terminalDiscovery = terminalDiscovery
        self.terminalLauncher = terminalLauncher
    }

    func execute(_ action: ActivationAction, projectPath: String, projectName: String) async -> Bool {
        guard let deps = dependencies else {
            return false
        }

        switch action {
        case let .activateByTty(tty, terminalType):
            return await deps.activateByTty(tty: tty, terminalType: terminalType)
        case let .activateApp(appName):
            return deps.activateApp(appName: appName)
        case let .activateKittyWindow(shellPid):
            return deps.activateKittyWindow(shellPid: shellPid)
        case let .activateIdeWindow(ideType, path):
            return await deps.activateIdeWindow(ideType: ideType, projectPath: path)
        case let .switchTmuxSession(sessionName):
            return await deps.switchTmuxSession(sessionName: sessionName, projectPath: projectPath)
        case let .ensureTmuxSession(sessionName, path):
            return await deps.ensureTmuxSession(sessionName: sessionName, projectPath: path)
        case let .activateHostThenSwitchTmux(hostTty, sessionName):
            return await activateHostThenSwitchTmux(
                hostTty: hostTty,
                sessionName: sessionName,
                projectPath: projectPath
            )
        case let .launchTerminalWithTmux(sessionName, path):
            return deps.launchTerminalWithTmux(sessionName: sessionName, projectPath: path)
        case let .launchNewTerminal(path, name):
            return deps.launchNewTerminal(projectPath: path, projectName: name)
        case .activatePriorityFallback:
            return deps.activatePriorityFallback()
        case .skip:
            return true
        }
    }

    // MARK: - Host + Tmux Switching

    func activateHostThenSwitchTmux(
        hostTty: String,
        sessionName: String,
        projectPath: String
    ) async -> Bool {
        guard dependencies != nil else {
            return false
        }

        let anyClientAttached = await tmuxClient.hasAnyClientAttached()
        if !anyClientAttached {
            terminalLauncher.launchTerminalWithTmux(sessionName: sessionName)
            return true
        }

        let freshTty = await tmuxClient.getCurrentClientTty() ?? hostTty
        let ttyActivated = await terminalDiscovery.activateTerminalByTTY(tty: freshTty)
        if ttyActivated {
            return await tmuxClient.switchClient(to: sessionName)
        }

        if terminalDiscovery.isGhosttyRunning() {
            let windowCount = terminalDiscovery.countGhosttyWindows()
            let decision = TerminalLauncher.ghosttyWindowDecision(
                windowCount: windowCount,
                anyClientAttached: anyClientAttached
            )

            switch decision {
            case .activateAndSwitch:
                _ = terminalDiscovery.activateAppByName("Ghostty")
                return await tmuxClient.switchClient(to: sessionName)
            case .launchNew:
                terminalLauncher.launchTerminalWithTmux(sessionName: sessionName)
                return true
            }
        }

        return false
    }
}
