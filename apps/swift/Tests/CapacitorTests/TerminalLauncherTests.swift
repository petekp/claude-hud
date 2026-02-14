@testable import Capacitor
import XCTest

@MainActor
final class TerminalLauncherTests: XCTestCase {
    private struct StubAppleScriptClient: AppleScriptClient {
        let shouldSucceed: Bool

        func run(_: String) {}
        func runChecked(_: String) -> Bool {
            shouldSucceed
        }
    }

    func testGhosttyWindowCountZeroDoesNotLaunchWhenClientAttached() {
        let decision = TerminalLauncher.ghosttyWindowDecision(windowCount: 0, anyClientAttached: true)
        XCTAssertEqual(decision, .activateAndSwitch)
    }

    func testGhosttyWindowCountMultipleDoesNotLaunchWhenClientAttached() {
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
                if script.contains("display-message") {
                    return (0, "/dev/ttys010\n")
                }
                return (0, nil)
            },
            activateTerminal: { _ in
                activateCalls += 1
                return true
            },
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
        XCTAssertTrue(scripts.contains { $0.contains("display-message -p '#{client_tty}'") })
        XCTAssertTrue(scripts.contains { $0.contains("tmux switch-client -c '/dev/ttys010' -t 'writing'") })
    }

    func testEnsureTmuxSessionCreatesThenActivates() async {
        var activateCalls = 0
        var callCount = 0

        let result = await TerminalLauncher.performEnsureTmuxSession(
            sessionName: "newproj",
            projectPath: "/Users/pete/Code/newproj",
            runScript: { script in
                defer { callCount += 1 }
                if script.contains("display-message") {
                    return (0, "/dev/ttys022\n")
                }
                switch callCount {
                case 0: return (1, "switch failed")
                case 1: return (0, "created")
                default: return (0, "switched")
                }
            },
            activateTerminal: { _ in
                activateCalls += 1
                return true
            },
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
    }

    func testEnsureTmuxSessionFallsBackToListClientsWhenDisplayMessageUnavailable() async {
        var activateCalls = 0
        var scripts: [String] = []

        let result = await TerminalLauncher.performEnsureTmuxSession(
            sessionName: "agent-skills",
            projectPath: "/Users/pete/Code/agent-skills",
            runScript: { script in
                scripts.append(script)
                if script.contains("display-message -p '#{client_tty}'") {
                    // App process is not running inside tmux; this fails in real usage.
                    return (1, nil)
                }
                if script.contains("list-clients -F '#{client_tty}'") {
                    return (0, "/dev/ttys015\n")
                }
                if script.contains("tmux switch-client -c '/dev/ttys015' -t 'agent-skills'") {
                    return (0, nil)
                }
                if script.contains("tmux switch-client -t 'agent-skills'") {
                    return (1, "no current client")
                }
                if script.contains("tmux new-session -d -s 'agent-skills'") {
                    return (1, "duplicate session")
                }
                return (1, nil)
            },
            activateTerminal: { _ in
                activateCalls += 1
                return true
            },
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
        XCTAssertTrue(
            scripts.contains { $0.contains("list-clients -F '#{client_tty}'") },
            "Expected list-clients fallback lookup, got scripts: \(scripts)",
        )
        XCTAssertFalse(
            scripts.contains { $0.contains("tmux new-session -d -s 'agent-skills'") },
            "Expected no session creation when existing session can be switched",
        )
    }

    func testSwitchTmuxSessionDoesNotActivateOnFailure() async {
        var activateCalls = 0

        let result = await TerminalLauncher.performSwitchTmuxSession(
            sessionName: "broken",
            projectPath: "/Users/pete/Code/broken",
            runScript: { script in
                if script.contains("display-message") {
                    return (0, "/dev/ttys044\n")
                }
                return (1, "switch failed")
            },
            activateTerminal: { _ in
                activateCalls += 1
                return true
            },
        )

        XCTAssertFalse(result)
        XCTAssertEqual(activateCalls, 0)
    }

    func testSwitchTmuxSessionUsesExplicitClientTTYWhenAvailable() async {
        var scripts: [String] = []
        var activateCalls = 0

        let result = await TerminalLauncher.performSwitchTmuxSession(
            sessionName: "capacitor",
            projectPath: "/Users/pete/Code/capacitor",
            runScript: { script in
                scripts.append(script)
                if script.contains("display-message") {
                    return (0, "/dev/ttys072\n")
                }
                return (0, nil)
            },
            activateTerminal: { _ in
                activateCalls += 1
                return true
            },
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
        XCTAssertTrue(
            scripts.contains { $0.contains("display-message -p '#{client_tty}'") },
            "Expected tmux client tty lookup before switch, got scripts: \(scripts)",
        )
        XCTAssertTrue(
            scripts.contains { $0.contains("tmux switch-client -c '/dev/ttys072' -t 'capacitor'") },
            "Expected explicit client tty switch target, got scripts: \(scripts)",
        )
    }

    func testGhosttyOwnerPidForTTYFromProcessSnapshot() {
        let snapshot = """
         75868 75866 ttys072 tmux new-session -A -s writing -c /Users/pete/Code/writing
         75866 75864 ttys072 /usr/bin/login -flp pete sh -c tmux new-session -A -s writing
         75864 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty -e sh -c tmux new-session -A -s writing
         62940 62939 ttys031 /usr/bin/login -flp pete /bin/bash --noprofile --norc -c exec -l /bin/zsh
         62939 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
        """

        let owner = TerminalLauncher.ghosttyOwnerPid(forTTY: "/dev/ttys072", processSnapshot: snapshot)
        XCTAssertEqual(owner, 75864)
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
            claudePath: "/opt/homebrew/bin/claude",
        )
        XCTAssertFalse(script.lowercased().contains("tmux"))
    }

    func testLaunchNoTmuxScriptSkipsUnsupportedTerminalsForAlpha() {
        let script = TerminalScripts.launchNoTmux(
            projectPath: "/Users/pete/Code/myproject",
            projectName: "myproject",
            claudePath: "/opt/homebrew/bin/claude",
        )
        let lowercased = script.lowercased()
        XCTAssertFalse(lowercased.contains("alacritty"))
        XCTAssertFalse(lowercased.contains("warp"))
        XCTAssertFalse(lowercased.contains("kitty"))
    }

    func testLaunchNewTerminalScriptDoesNotReferenceTmux() {
        let script = TerminalLauncher.launchNewTerminalScript(
            projectPath: "/Users/pete/Code/myproject",
            projectName: "myproject",
            claudePath: "/opt/homebrew/bin/claude",
        )
        XCTAssertFalse(script.lowercased().contains("tmux"))
    }

    func testTerminalAppMatchingNames() {
        XCTAssertTrue(ParentApp.terminal.matchesRunningAppName("Terminal"))
        XCTAssertTrue(ParentApp.terminal.matchesRunningAppName("Terminal.app"))
    }

    func testAlphaSupportedTerminalPriorityOrder() {
        XCTAssertEqual(ParentApp.terminalPriorityOrder, [.ghostty, .iTerm, .terminal])
    }

    func testUnsupportedTerminalsAreNotInstalledForAlpha() {
        XCTAssertFalse(ParentApp.alacritty.isInstalled)
        XCTAssertFalse(ParentApp.kitty.isInstalled)
        XCTAssertFalse(ParentApp.warp.isInstalled)
    }

    func testBestTmuxSessionForPathDoesNotMatchParentRepoForWorktreePath() {
        let output = "agentic-canvas\t/Users/pete/Code/agentic-canvas\n"
        let projectPath = "/Users/pete/Code/agentic-canvas/.capacitor/worktrees/workstream-1"

        let session = TerminalLauncher.bestTmuxSessionForPath(
            output: output,
            projectPath: projectPath,
            homeDirectory: "/Users/pete",
        )

        XCTAssertNil(session)
    }

    func testBestTmuxSessionForPathDoesNotMatchManagedWorktreeForRepoRootPath() {
        let output = """
        mcp-app-studio-tool-metadata-workstream-1\t/Users/pete/Code/codex/.capacitor/worktrees/mcp-app-studio-tool-metadata-workstream-1
        """
        let projectPath = "/Users/pete/Code/codex"

        let session = TerminalLauncher.bestTmuxSessionForPath(
            output: output,
            projectPath: projectPath,
            homeDirectory: "/Users/pete",
        )

        XCTAssertNil(session)
    }

    func testRunBashScriptWithResultHandlesLargeOutputWithoutDeadlock() {
        let exp = expectation(description: "runBashScriptWithResult completes")
        _Concurrency.Task {
            let result = await TerminalLauncher.runBashScriptWithResult("yes x | head -n 200000")
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertNotNil(result.output)
            XCTAssertGreaterThan(result.output?.count ?? 0, 100_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    func testAERoutingActionMappingAttachedTmuxUsesHostThenSwitchWhenClientEvidencePresent() {
        let snapshot = DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: "/Users/pete/Code/capacitor",
            status: "attached",
            target: DaemonRoutingTarget(kind: "tmux_session", value: "caps"),
            confidence: "high",
            reasonCode: "TMUX_CLIENT_ATTACHED",
            reason: "attached",
            evidence: [
                DaemonRoutingEvidence(
                    evidenceType: "tmux_client",
                    value: "/dev/ttys015",
                    ageMs: 120,
                    trustRank: 1,
                ),
            ],
            updatedAt: "2026-02-14T15:00:00Z",
        )

        let action = TerminalLauncher.activationActionFromAERSnapshot(
            snapshot,
            projectPath: "/Users/pete/Code/capacitor",
            projectName: "capacitor",
        )
        switch action {
        case let .activateHostThenSwitchTmux(hostTty, sessionName):
            XCTAssertEqual(hostTty, "/dev/ttys015")
            XCTAssertEqual(sessionName, "caps")
        default:
            XCTFail("Expected activateHostThenSwitchTmux, got \(String(describing: action))")
        }
    }

    func testAERoutingActionMappingDetachedTmuxEnsuresSession() {
        let snapshot = DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: "/Users/pete/Code/capacitor",
            status: "detached",
            target: DaemonRoutingTarget(kind: "tmux_session", value: "caps"),
            confidence: "medium",
            reasonCode: "TMUX_SESSION_DETACHED",
            reason: "detached",
            evidence: [],
            updatedAt: "2026-02-14T15:00:00Z",
        )

        let action = TerminalLauncher.activationActionFromAERSnapshot(
            snapshot,
            projectPath: "/Users/pete/Code/capacitor",
            projectName: "capacitor",
        )
        switch action {
        case let .ensureTmuxSession(sessionName, projectPath):
            XCTAssertEqual(sessionName, "caps")
            XCTAssertEqual(projectPath, "/Users/pete/Code/capacitor")
        default:
            XCTFail("Expected ensureTmuxSession, got \(String(describing: action))")
        }
    }

    func testAERoutingActionMappingDetachedTerminalAppActivatesApp() {
        let snapshot = DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: "/Users/pete/Code/capacitor",
            status: "detached",
            target: DaemonRoutingTarget(kind: "terminal_app", value: "Ghostty"),
            confidence: "low",
            reasonCode: "SHELL_FALLBACK_ACTIVE",
            reason: "fallback",
            evidence: [],
            updatedAt: "2026-02-14T15:00:00Z",
        )

        let action = TerminalLauncher.activationActionFromAERSnapshot(
            snapshot,
            projectPath: "/Users/pete/Code/capacitor",
            projectName: "capacitor",
        )
        switch action {
        case let .activateApp(appName):
            XCTAssertEqual(appName, "Ghostty")
        default:
            XCTFail("Expected activateApp, got \(String(describing: action))")
        }
    }

    func testAERoutingActionMappingUnavailableLaunchesNewTerminal() {
        let snapshot = DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: "/Users/pete/Code/capacitor",
            status: "unavailable",
            target: DaemonRoutingTarget(kind: "none", value: nil),
            confidence: "low",
            reasonCode: "NO_TRUSTED_EVIDENCE",
            reason: "none",
            evidence: [],
            updatedAt: "2026-02-14T15:00:00Z",
        )

        let action = TerminalLauncher.activationActionFromAERSnapshot(
            snapshot,
            projectPath: "/Users/pete/Code/capacitor",
            projectName: "capacitor",
        )
        switch action {
        case let .launchNewTerminal(projectPath, projectName):
            XCTAssertEqual(projectPath, "/Users/pete/Code/capacitor")
            XCTAssertEqual(projectName, "capacitor")
        default:
            XCTFail("Expected launchNewTerminal, got \(String(describing: action))")
        }
    }
}
