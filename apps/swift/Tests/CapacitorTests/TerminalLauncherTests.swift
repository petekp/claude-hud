import XCTest
@testable import Capacitor

@MainActor
final class TerminalLauncherTests: XCTestCase {
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

    func testSwitchTmuxSessionCreatesThenActivates() async {
        var activateCalls = 0
        var callCount = 0

        let result = await TerminalLauncher.performSwitchTmuxSession(
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
        var callCount = 0

        let result = await TerminalLauncher.performSwitchTmuxSession(
            sessionName: "broken",
            projectPath: "/Users/pete/Code/broken",
            runScript: { _ in
                defer { callCount += 1 }
                switch callCount {
                case 0: return (1, "switch failed")
                default: return (1, "create failed")
                }
            },
            activateTerminal: { activateCalls += 1 }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(activateCalls, 0)
    }
}
