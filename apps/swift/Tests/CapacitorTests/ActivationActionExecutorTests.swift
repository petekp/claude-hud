@testable import Capacitor
import XCTest

@MainActor
final class ActivationActionExecutorTests: XCTestCase {
    private final class StubDependencies: ActivationActionDependencies {
        var lastAction: String?
        var lastTty: String?
        var lastTerminalType: TerminalType?
        var lastAppName: String?
        var lastSessionName: String?
        var lastProjectPath: String?
        var lastProjectName: String?
        var lastIdeType: IdeType?

        var activateByTtyResult = true
        var activateAppResult = true
        var activateKittyResult = true
        var activateIdeResult = true
        var switchTmuxResult = true
        var ensureTmuxResult = true
        var activateHostThenSwitchResult = true
        var launchWithTmuxResult = true
        var launchNewResult = true
        var activateFallbackResult = true

        func activateByTty(tty: String, terminalType: TerminalType) async -> Bool {
            lastAction = "activateByTty"
            lastTty = tty
            lastTerminalType = terminalType
            return activateByTtyResult
        }

        func activateApp(appName: String) -> Bool {
            lastAction = "activateApp"
            lastAppName = appName
            return activateAppResult
        }

        func activateKittyWindow(shellPid _: UInt32) -> Bool {
            lastAction = "activateKittyWindow"
            return activateKittyResult
        }

        func activateIdeWindow(ideType: IdeType, projectPath: String) async -> Bool {
            lastAction = "activateIdeWindow"
            lastIdeType = ideType
            lastProjectPath = projectPath
            return activateIdeResult
        }

        func switchTmuxSession(sessionName: String, projectPath: String) async -> Bool {
            lastAction = "switchTmuxSession"
            lastSessionName = sessionName
            lastProjectPath = projectPath
            return switchTmuxResult
        }

        func ensureTmuxSession(sessionName: String, projectPath: String) async -> Bool {
            lastAction = "ensureTmuxSession"
            lastSessionName = sessionName
            lastProjectPath = projectPath
            return ensureTmuxResult
        }

        func activateHostThenSwitchTmux(hostTty _: String, sessionName: String, projectPath: String) async -> Bool {
            lastAction = "activateHostThenSwitchTmux"
            lastSessionName = sessionName
            lastProjectPath = projectPath
            return activateHostThenSwitchResult
        }

        func launchTerminalWithTmux(sessionName: String, projectPath: String) -> Bool {
            lastAction = "launchTerminalWithTmux"
            lastSessionName = sessionName
            lastProjectPath = projectPath
            return launchWithTmuxResult
        }

        func launchNewTerminal(projectPath: String, projectName: String) -> Bool {
            lastAction = "launchNewTerminal"
            lastProjectPath = projectPath
            lastProjectName = projectName
            return launchNewResult
        }

        func activatePriorityFallback() -> Bool {
            lastAction = "activatePriorityFallback"
            return activateFallbackResult
        }
    }

    private final class StubTmuxClient: TmuxClient {
        var hasClientAttached = true
        var currentClientTty: String? = "/dev/ttys001"
        var switchResult = true
        var lastSwitchedClientTty: String?

        func hasAnyClientAttached() async -> Bool {
            hasClientAttached
        }

        func getCurrentClientTty() async -> String? {
            currentClientTty
        }

        func switchClient(to _: String, clientTty: String?) async -> Bool {
            lastSwitchedClientTty = clientTty
            return switchResult
        }
    }

    @MainActor
    private final class StubTerminalDiscovery: TerminalDiscovery {
        var activateByTtyResult = true
        var activateAppResult = true
        var lastActivatedApp: String?
        var ghosttyRunning = false
        var ghosttyWindows = 1

        func activateTerminalByTTY(tty _: String) async -> Bool {
            activateByTtyResult
        }

        func activateAppByName(_ appName: String) -> Bool {
            lastActivatedApp = appName
            return activateAppResult
        }

        func isGhosttyRunning() -> Bool {
            ghosttyRunning
        }

        func countGhosttyWindows() -> Int {
            ghosttyWindows
        }
    }

    @MainActor
    private final class StubTerminalLauncherClient: TerminalLauncherClient {
        var launchedSession: String?
        var launchCount = 0
        func launchTerminalWithTmux(sessionName: String) {
            launchedSession = sessionName
            launchCount += 1
        }
    }

    func testExecuteRoutesActivateByTty() async {
        let deps = StubDependencies()
        deps.activateByTtyResult = false
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: StubTmuxClient(),
            terminalDiscovery: StubTerminalDiscovery(),
            terminalLauncher: StubTerminalLauncherClient(),
        )

        let result = await executor.execute(
            .activateByTty(tty: "/dev/ttys001", terminalType: .iTerm),
            projectPath: "/Users/pete/Code/project",
            projectName: "project",
        )

        XCTAssertFalse(result)
        XCTAssertEqual(deps.lastAction, "activateByTty")
        XCTAssertEqual(deps.lastTty, "/dev/ttys001")
        XCTAssertEqual(deps.lastTerminalType, .iTerm)
    }

    func testExecuteRoutesSwitchTmuxSession() async {
        let deps = StubDependencies()
        deps.switchTmuxResult = false
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: StubTmuxClient(),
            terminalDiscovery: StubTerminalDiscovery(),
            terminalLauncher: StubTerminalLauncherClient(),
        )

        let result = await executor.execute(
            .switchTmuxSession(sessionName: "cap"),
            projectPath: "/Users/pete/Code/cap",
            projectName: "cap",
        )

        XCTAssertFalse(result)
        XCTAssertEqual(deps.lastAction, "switchTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "cap")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/cap")
    }

    func testExecuteRoutesEnsureTmuxSession() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = false
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: StubTmuxClient(),
            terminalDiscovery: StubTerminalDiscovery(),
            terminalLauncher: StubTerminalLauncherClient(),
        )

        let result = await executor.execute(
            .ensureTmuxSession(sessionName: "cap", projectPath: "/Users/pete/Code/cap"),
            projectPath: "/Users/pete/Code/other",
            projectName: "cap",
        )

        XCTAssertFalse(result)
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "cap")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/cap")
    }

    func testExecuteRoutesLaunchNewTerminal() async {
        let deps = StubDependencies()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: StubTmuxClient(),
            terminalDiscovery: StubTerminalDiscovery(),
            terminalLauncher: StubTerminalLauncherClient(),
        )

        let result = await executor.execute(
            .launchNewTerminal(projectPath: "/Users/pete/Code/app", projectName: "app"),
            projectPath: "/Users/pete/Code/app",
            projectName: "app",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(deps.lastAction, "launchNewTerminal")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/app")
        XCTAssertEqual(deps.lastProjectName, "app")
    }

    func testActivateHostThenSwitchTmuxLaunchesWhenNoClientAttached() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        let terminalDiscovery = StubTerminalDiscovery()
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(launcher.launchedSession, "cap")
    }

    func testActivateHostThenSwitchTmuxUsesTtyDiscoveryThenSwitches() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.switchResult = true
        tmux.currentClientTty = "/dev/ttys009"
        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = true
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(tmux.lastSwitchedClientTty, "/dev/ttys009")
        XCTAssertNil(launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxGhosttyFallbackActivatesAppWhenSingleWindow() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.switchResult = true
        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyRunning = true
        terminalDiscovery.ghosttyWindows = 1
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertNil(launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxGhosttyFallbackActivatesAppWhenMultipleWindows() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.switchResult = true
        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyRunning = true
        terminalDiscovery.ghosttyWindows = 2
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertNil(launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxReturnsFalseWhenNoTtyAndNoGhostty() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.switchResult = true
        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyRunning = false
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertFalse(result)
        XCTAssertNil(launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxReturnsFalseWhenSwitchFails() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.switchResult = false
        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = true
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertFalse(result)
        XCTAssertNil(launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxNoClientAttachedButGhosttyRunningDoesNotSpawnNewWindow() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = true

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyRunning = true
        terminalDiscovery.ghosttyWindows = 1

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys021",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertEqual(launcher.launchCount, 0, "Expected reuse of existing Ghostty context with no new window")
    }

    func testActivateHostThenSwitchTmuxNoClientAttachedUsesHostTtyHeuristicWhenAvailable() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = true

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.ghosttyRunning = true

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys021",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertEqual(tmux.lastSwitchedClientTty, "/dev/ttys021")
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testActivateHostThenSwitchTmuxNoClientAttachedSwitchFailureFallsBackToEnsureSession() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = true

        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = false

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.ghosttyRunning = true

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys-stale",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result, "Switch failure with no attached clients should recover via ensure path.")
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertEqual(tmux.lastSwitchedClientTty, "/dev/ttys-stale")
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "cap")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/cap")
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testActivateHostThenSwitchTmuxNoClientAttachedGhosttyZeroWindowsFallsBackToEnsureSession() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = true

        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = true

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.ghosttyRunning = true
        terminalDiscovery.ghosttyWindows = 0

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys-stale",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result, "Zero-window Ghostty state should recover via ensure path, not dead-click on stale host evidence.")
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "cap")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/cap")
        XCTAssertNil(tmux.lastSwitchedClientTty, "Zero-window host should skip no-client switch heuristics.")
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testActivateHostThenSwitchTmuxSequentialRequestsReuseExistingGhosttyContext() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = true

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyRunning = true
        terminalDiscovery.ghosttyWindows = 1

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let first = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys021",
            sessionName: "project-a",
            projectPath: "/Users/pete/Code/project-a",
        )
        let second = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys021",
            sessionName: "project-b",
            projectPath: "/Users/pete/Code/project-b",
        )

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(launcher.launchCount, 0, "Sequential project clicks should switch context without spawning windows")
    }
}
