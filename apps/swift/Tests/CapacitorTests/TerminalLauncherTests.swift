@testable import Capacitor
import XCTest

@MainActor
final class TerminalLauncherTests: XCTestCase {
    private struct StubAppleScriptClient: AppleScriptClient {
        let shouldSucceed: Bool

        func run(_: String) {}
        func runChecked(_: String) -> Bool { shouldSucceed }
    }

    func testGhosttyWindowCountZeroDoesNotLaunchWhenClientAttached() {
        let decision = TerminalLauncher.ghosttyWindowDecision(windowCount: 0, anyClientAttached: true)
        XCTAssertEqual(decision, .activateAndSwitch)
    }

    func testGhosttyWindowCountPositiveActivatesWhenClientAttached() {
        let decision = TerminalLauncher.ghosttyWindowDecision(windowCount: 2, anyClientAttached: true)
        XCTAssertEqual(decision, .activateAndSwitch)
    }

    func testGhosttyLaunchesWhenNoClientAttached() {
        let decision = TerminalLauncher.ghosttyWindowDecision(windowCount: 0, anyClientAttached: false)
        XCTAssertEqual(decision, .launchNew)
    }

    func testSwitchTmuxSessionActivatesTerminalOnSuccess() async {
        var activateCalls = 0
        var scripts: [String] = []

        let result = await TerminalLauncher.performSwitchTmuxSession(
            sessionName: "writing",
            projectPath: "/Users/pete/Code/writing",
            runScript: { script in
                scripts.append(script)
                return (0, nil)
            },
            activateTerminal: { activateCalls += 1 }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
        XCTAssertTrue(scripts.first?.contains("tmux switch-client") == true)
    }

    func testEnsureTmuxSessionCreatesThenActivates() async {
        var activateCalls = 0
        var callCount = 0

        let result = await TerminalLauncher.performEnsureTmuxSession(
            sessionName: "newproj",
            projectPath: "/Users/pete/Code/newproj",
            runScript: { _ in
                defer { callCount += 1 }
                switch callCount {
                case 0: return (1, "switch failed")
                case 1: return (0, "created")
                default: return (0, "switched")
                }
            },
            activateTerminal: { activateCalls += 1 }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
    }

    func testSwitchTmuxSessionDoesNotActivateOnFailure() async {
        var activateCalls = 0

        let result = await TerminalLauncher.performSwitchTmuxSession(
            sessionName: "broken",
            projectPath: "/Users/pete/Code/broken",
            runScript: { _ in
                (1, "switch failed")
            },
            activateTerminal: { activateCalls += 1 }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(activateCalls, 0)
    }

    func testActivateByTtyReturnsFalseWhenAppleScriptFails() async {
        let launcher = TerminalLauncher(appleScript: StubAppleScriptClient(shouldSucceed: false))
        let result = await launcher.activateByTtyAction(tty: "/dev/ttys001", terminalType: .iTerm)
        XCTAssertFalse(result)
    }

    func testActivateByTtyReturnsFalseWhenTerminalAppAppleScriptFails() async {
        let launcher = TerminalLauncher(appleScript: StubAppleScriptClient(shouldSucceed: false))
        let result = await launcher.activateByTtyAction(tty: "/dev/ttys002", terminalType: .terminalApp)
        XCTAssertFalse(result)
    }

    func testLaunchNoTmuxScriptDoesNotReferenceTmux() {
        let script = TerminalScripts.launchNoTmux(
            projectPath: "/Users/pete/Code/myproject",
            projectName: "myproject",
            claudePath: "/opt/homebrew/bin/claude"
        )
        XCTAssertFalse(script.lowercased().contains("tmux"))
    }

    func testLaunchNewTerminalScriptDoesNotReferenceTmux() {
        let script = TerminalLauncher.launchNewTerminalScript(
            projectPath: "/Users/pete/Code/myproject",
            projectName: "myproject",
            claudePath: "/opt/homebrew/bin/claude"
        )
        XCTAssertFalse(script.lowercased().contains("tmux"))
    }

    func testTerminalAppMatchingNames() {
        XCTAssertTrue(ParentApp.terminal.matchesRunningAppName("Terminal"))
        XCTAssertTrue(ParentApp.terminal.matchesRunningAppName("Terminal.app"))
    }
}
