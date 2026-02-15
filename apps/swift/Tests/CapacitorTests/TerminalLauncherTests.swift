@testable import Capacitor
import XCTest

@MainActor
final class TerminalLauncherTests: XCTestCase {
    private enum SnapshotFetchError: Error {
        case unavailable
    }

    private actor LogCollector {
        private var lines: [String] = []

        func append(_ line: String) {
            lines.append(line)
        }

        func contains(_ predicate: (String) -> Bool) -> Bool {
            lines.contains(where: predicate)
        }
    }

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

    func testEnsureTmuxSessionLaunchesWhenNoClientAttachedAfterEnsuringSession() async {
        var activateCalls = 0
        var launched = 0
        var scripts: [String] = []

        let result = await TerminalLauncher.performEnsureTmuxSession(
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
            runScript: { script in
                scripts.append(script)
                if script.contains("display-message -p '#{client_tty}'") {
                    return (1, nil)
                }
                if script.contains("list-clients -F '#{client_tty}'") {
                    return (0, "")
                }
                if script.contains("tmux switch-client -t 'cap'") {
                    return (1, "no current client")
                }
                if script.contains("tmux has-session -t 'cap'") {
                    return (0, nil)
                }
                if script.contains("tmux new-session -d -s 'cap'") {
                    XCTFail("Did not expect session creation when has-session succeeds")
                    return (1, nil)
                }
                return (1, nil)
            },
            activateTerminal: { _ in
                activateCalls += 1
                return true
            },
            launchWhenNoClient: {
                launched += 1
                return true
            },
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 0, "No tmux client is attached, so terminal activation callback should not run")
        XCTAssertEqual(launched, 1, "Expected a single terminal launch to attach the ensured session")
        XCTAssertTrue(
            scripts.contains { $0.contains("tmux has-session -t 'cap'") },
            "Expected has-session check before deciding whether creation is needed",
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

    func testAERoutingActionMappingAttachedTmuxWithMultipleClientEvidenceUsesMostTrustedFreshestHostTTY() {
        let snapshot = DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: "/Users/pete/Code/capacitor",
            status: "attached",
            target: DaemonRoutingTarget(kind: "tmux_session", value: "caps"),
            confidence: "high",
            reasonCode: "TMUX_CLIENT_ATTACHED",
            reason: "attached with multiple clients",
            evidence: [
                DaemonRoutingEvidence(
                    evidenceType: "tmux_client",
                    value: "/dev/ttys-old",
                    ageMs: 900,
                    trustRank: 2,
                ),
                DaemonRoutingEvidence(
                    evidenceType: "tmux_client",
                    value: "/dev/ttys-best",
                    ageMs: 50,
                    trustRank: 1,
                ),
            ],
            updatedAt: "2026-02-15T03:45:00Z",
        )

        let action = TerminalLauncher.activationActionFromAERSnapshot(
            snapshot,
            projectPath: "/Users/pete/Code/capacitor",
            projectName: "capacitor",
        )
        switch action {
        case let .activateHostThenSwitchTmux(hostTty, sessionName):
            XCTAssertEqual(hostTty, "/dev/ttys-best")
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

    func testAERoutingActionMappingDetachedTmuxWithClientEvidenceUsesHostThenSwitch() {
        let snapshot = DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: "/Users/pete/Code/capacitor",
            status: "detached",
            target: DaemonRoutingTarget(kind: "tmux_session", value: "caps"),
            confidence: "high",
            reasonCode: "TMUX_CLIENT_EVIDENCE_AVAILABLE",
            reason: "detached snapshot with attached client evidence",
            evidence: [
                DaemonRoutingEvidence(
                    evidenceType: "tmux_client",
                    value: "/dev/ttys019",
                    ageMs: 40,
                    trustRank: 1,
                ),
            ],
            updatedAt: "2026-02-15T01:10:00Z",
        )

        let action = TerminalLauncher.activationActionFromAERSnapshot(
            snapshot,
            projectPath: "/Users/pete/Code/capacitor",
            projectName: "capacitor",
        )
        switch action {
        case let .activateHostThenSwitchTmux(hostTty, sessionName):
            XCTAssertEqual(hostTty, "/dev/ttys019")
            XCTAssertEqual(sessionName, "caps")
        default:
            XCTFail("Expected activateHostThenSwitchTmux, got \(String(describing: action))")
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

    func testAERoutingActionMappingDetachedUnknownTerminalAppLaunchesNewTerminal() {
        let snapshot = DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: "/Users/pete/Code/capacitor",
            status: "detached",
            target: DaemonRoutingTarget(kind: "terminal_app", value: "Hyper"),
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
        case let .launchNewTerminal(projectPath, projectName):
            XCTAssertEqual(projectPath, "/Users/pete/Code/capacitor")
            XCTAssertEqual(projectName, "capacitor")
        default:
            XCTFail("Expected launchNewTerminal for unsupported terminal app target, got \(String(describing: action))")
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

    func testLaunchTerminalOverlappingRequestsOnlyExecutesLatestClick() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        var executedPaths: [String] = []
        var resultPaths: [String] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { projectPath, _ in
                if projectPath == projectA.path {
                    try await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                } else {
                    try await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                }
                return Self.makeAttachedTerminalAppSnapshot(
                    projectPath: projectPath,
                    appName: "Ghostty",
                )
            },
            executeActivationActionOverride: { _, projectPath, _ in
                executedPaths.append(projectPath)
                return true
            },
        )

        launcher.onActivationResult = { (result: TerminalActivationResult) in
            resultPaths.append(result.projectPath)
        }

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 40_000_000)
        launcher.launchTerminal(for: projectB)

        try? await _Concurrency.Task.sleep(nanoseconds: 450_000_000)

        XCTAssertEqual(
            executedPaths,
            [projectB.path],
            "Overlapping clicks should coalesce to the latest request.",
        )
        XCTAssertEqual(
            resultPaths,
            [projectB.path],
            "Only the latest click should emit an activation result.",
        )
    }

    func testLaunchTerminalOverlappingRequestsLogsStaleSnapshotMarker() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        let collector = LogCollector()

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { projectPath, _ in
                if projectPath == projectA.path {
                    try await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                } else {
                    try await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                }
                return Self.makeAttachedTerminalAppSnapshot(
                    projectPath: projectPath,
                    appName: "Ghostty",
                )
            },
            executeActivationActionOverride: { _, _, _ in
                true
            },
        )

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 40_000_000)
        launcher.launchTerminal(for: projectB)
        try? await _Concurrency.Task.sleep(nanoseconds: 450_000_000)

        let foundMarker = await collector.contains {
            $0.contains("[TerminalLauncher] ARE snapshot request canceled/stale") &&
                $0.contains(projectA.path)
        }

        XCTAssertTrue(foundMarker, "Expected stale overlap marker for superseded request.")
    }

    func testLaunchTerminalOverlappingRequestsStaleAfterPrimaryEmitsCanonicalStaleMarker() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        let collector = LogCollector()
        var resultPaths: [String] = []

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { projectPath, _ in
                Self.makeAttachedTerminalAppSnapshot(
                    projectPath: projectPath,
                    appName: "Ghostty",
                )
            },
            executeActivationActionOverride: { _, projectPath, _ in
                if projectPath == projectA.path {
                    try? await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                }
                return true
            },
        )

        launcher.onActivationResult = { result in
            resultPaths.append(result.projectPath)
        }

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 30_000_000)
        launcher.launchTerminal(for: projectB)
        try? await _Concurrency.Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(
            resultPaths,
            [projectB.path],
            "Only the latest request should emit a final outcome after overlap.",
        )
        let foundCanonicalMarker = await collector.contains {
            ($0.contains("[TerminalLauncher] ARE snapshot request canceled/stale") ||
                $0.contains("[TerminalLauncher] ARE snapshot ignored for stale request") ||
                $0.contains("[TerminalLauncher] launchTerminalAsync ignored stale request")) &&
                $0.contains(projectA.path)
        }

        XCTAssertTrue(
            foundCanonicalMarker,
            "Expected canonical stale suppression marker when a request becomes stale during primary action.",
        )
    }

    func testLaunchTerminalSequentialRequestsExecuteInOrder() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        var executedPaths: [String] = []
        var resultPaths: [String] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { projectPath, _ in
                try? await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
                return Self.makeAttachedTerminalAppSnapshot(
                    projectPath: projectPath,
                    appName: "Ghostty",
                )
            },
            executeActivationActionOverride: { _, projectPath, _ in
                executedPaths.append(projectPath)
                return true
            },
        )

        launcher.onActivationResult = { (result: TerminalActivationResult) in
            resultPaths.append(result.projectPath)
        }

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 120_000_000)
        launcher.launchTerminal(for: projectB)
        try? await _Concurrency.Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(executedPaths, [projectA.path, projectB.path])
        XCTAssertEqual(resultPaths, [projectA.path, projectB.path])
    }

    func testLaunchTerminalPrimaryFailureExecutesSingleFallbackLaunch() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var actions: [ActivationAction] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { _, _ in
                DaemonRoutingSnapshot(
                    version: 1,
                    workspaceId: "workspace-1",
                    projectPath: project.path,
                    status: "detached",
                    target: DaemonRoutingTarget(kind: "tmux_session", value: "project-a"),
                    confidence: "medium",
                    reasonCode: "TMUX_SESSION_DETACHED",
                    reason: "detached session",
                    evidence: [],
                    updatedAt: "2026-02-15T02:15:00Z",
                )
            },
            executeActivationActionOverride: { action, _, _ in
                actions.append(action)
                switch action {
                case .ensureTmuxSession:
                    return false
                case .launchNewTerminal:
                    return true
                default:
                    return true
                }
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(actions.count, 2, "Expected one primary action and one fallback launch action.")
        if actions.count == 2 {
            if case let .ensureTmuxSession(session, path) = actions[0] {
                XCTAssertEqual(session, "project-a")
                XCTAssertEqual(path, project.path)
            } else {
                XCTFail("Expected ensureTmuxSession primary action, got \(String(describing: actions[0]))")
            }
            if case let .launchNewTerminal(path, name) = actions[1] {
                XCTAssertEqual(path, project.path)
                XCTAssertEqual(name, project.name)
            } else {
                XCTFail("Expected launchNewTerminal fallback action, got \(String(describing: actions[1]))")
            }
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.usedFallback, true)
    }

    func testLaunchTerminalPrimaryLaunchFailureDoesNotChainSecondFallback() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var actions: [ActivationAction] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { _, _ in
                DaemonRoutingSnapshot(
                    version: 1,
                    workspaceId: "workspace-1",
                    projectPath: project.path,
                    status: "unavailable",
                    target: DaemonRoutingTarget(kind: "none", value: nil),
                    confidence: "low",
                    reasonCode: "NO_TRUSTED_EVIDENCE",
                    reason: "none",
                    evidence: [],
                    updatedAt: "2026-02-15T02:16:00Z",
                )
            },
            executeActivationActionOverride: { action, _, _ in
                actions.append(action)
                if case .launchNewTerminal = action {
                    return false
                }
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(actions.count, 1, "Primary launch failure should not trigger a second launch fallback.")
        if let first = actions.first {
            if case let .launchNewTerminal(path, name) = first {
                XCTAssertEqual(path, project.path)
                XCTAssertEqual(name, project.name)
            } else {
                XCTFail("Expected launchNewTerminal primary action, got \(String(describing: first))")
            }
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.success, false)
        XCTAssertEqual(results.first?.usedFallback, false)
    }

    func testLaunchTerminalSnapshotFetchFailureLaunchesFallbackWithSuccessOutcome() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var launchedFallbacks: [(path: String, name: String)] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { _, _ in
                throw SnapshotFetchError.unavailable
            },
            launchNewTerminalOverride: { path, name in
                launchedFallbacks.append((path, name))
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(launchedFallbacks.count, 1)
        XCTAssertEqual(launchedFallbacks.first?.path, project.path)
        XCTAssertEqual(launchedFallbacks.first?.name, project.name)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.usedFallback, true)
    }

    func testLaunchTerminalColdStartNoTrustedEvidenceLogsFallbackMarkerAndLaunchesWithoutStall() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var actions: [ActivationAction] = []
        var results: [TerminalActivationResult] = []
        var elapsed: TimeInterval?
        let collector = LogCollector()
        let startedAt = Date()

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { _, _ in
                DaemonRoutingSnapshot(
                    version: 1,
                    workspaceId: "workspace-1",
                    projectPath: project.path,
                    status: "unavailable",
                    target: DaemonRoutingTarget(kind: "none", value: nil),
                    confidence: "low",
                    reasonCode: "NO_TRUSTED_EVIDENCE",
                    reason: "cold-start empty registries",
                    evidence: [],
                    updatedAt: "2026-02-15T03:50:00Z",
                )
            },
            executeActivationActionOverride: { action, _, _ in
                actions.append(action)
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
            elapsed = Date().timeIntervalSince(startedAt)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(actions.count, 1)
        if let firstAction = actions.first {
            if case let .launchNewTerminal(path, name) = firstAction {
                XCTAssertEqual(path, project.path)
                XCTAssertEqual(name, project.name)
            } else {
                XCTFail("Expected launchNewTerminal for cold-start empty evidence, got \(String(describing: firstAction))")
            }
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertLessThan(
            elapsed ?? .infinity,
            0.5,
            "Cold-start empty-evidence fallback should resolve quickly without apparent stall.",
        )

        let foundMarker = await collector.contains {
            $0.contains("[TerminalLauncher] ARE no-trusted-evidence fallback launch path=\(project.path)")
        }
        XCTAssertTrue(foundMarker, "Expected explicit no-trusted-evidence fallback marker for cold-start clarity.")
    }

    func testLaunchTerminalSnapshotFailureFallbackIsDebouncedAcrossRapidRepeatedClicks() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var launchedFallbacks: [(path: String, name: String)] = []
        var results: [TerminalActivationResult] = []
        let collector = LogCollector()

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { _, _ in
                throw SnapshotFetchError.unavailable
            },
            launchNewTerminalOverride: { path, name in
                launchedFallbacks.append((path, name))
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 200_000_000)
        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(
            launchedFallbacks.count,
            1,
            "Rapid repeated snapshot failures should not spawn repeated fallback launches.",
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].projectPath, project.path)
        XCTAssertEqual(results[1].projectPath, project.path)
        XCTAssertTrue(results[0].usedFallback)
        XCTAssertTrue(results[1].usedFallback)

        let foundDebounceMarker = await collector.contains {
            $0.contains("[TerminalLauncher] snapshot_unavailable_fallback debounced path=\(project.path)")
        }
        XCTAssertTrue(foundDebounceMarker, "Expected debounce marker for repeated snapshot failure fallback.")
    }

    func testLaunchTerminalSnapshotFailureFallbackLaunchFailureReturnsUnsuccessfulResult() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var launchedFallbacks: [(path: String, name: String)] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { _, _ in
                throw SnapshotFetchError.unavailable
            },
            launchNewTerminalOverride: { path, name in
                launchedFallbacks.append((path, name))
                return false
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(launchedFallbacks.count, 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.usedFallback, true)
        XCTAssertEqual(results.first?.success, false)
    }

    func testLaunchTerminalRepeatedSameCardRapidClicksCoalesceToSingleOutcome() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var executionCount = 0
        var resultPaths: [String] = []
        let collector = LogCollector()

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        var callCount = 0
        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { _, _ in
                callCount += 1
                if callCount < 3 {
                    try await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                } else {
                    try await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                }
                return Self.makeAttachedTerminalAppSnapshot(
                    projectPath: project.path,
                    appName: "Ghostty",
                )
            },
            executeActivationActionOverride: { _, _, _ in
                executionCount += 1
                return true
            },
        )

        launcher.onActivationResult = { result in
            resultPaths.append(result.projectPath)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 30_000_000)
        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 30_000_000)
        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(executionCount, 1, "Repeated in-flight clicks on same card should coalesce to one execution.")
        XCTAssertEqual(resultPaths, [project.path], "Expected one final outcome for repeated same-card overlap.")
        let hasStaleMarker = await collector.contains {
            $0.contains("[TerminalLauncher] ARE snapshot request canceled/stale") &&
                $0.contains(project.path)
        }
        XCTAssertTrue(hasStaleMarker, "Expected stale suppression marker for superseded same-card requests.")
    }

    func testLaunchTerminalLatestClickEmitsSingleFinalOutcomeSequence() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        var executedPaths: [String] = []
        var results: [TerminalActivationResult] = []
        let collector = LogCollector()

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { projectPath, _ in
                if projectPath == projectA.path {
                    try await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                } else {
                    try await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                }
                return Self.makeAttachedTerminalAppSnapshot(
                    projectPath: projectPath,
                    appName: "Ghostty",
                )
            },
            executeActivationActionOverride: { _, projectPath, _ in
                executedPaths.append(projectPath)
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 40_000_000)
        launcher.launchTerminal(for: projectB)
        try? await _Concurrency.Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(executedPaths, [projectB.path])
        XCTAssertEqual(results.count, 1, "Latest-click overlap should emit exactly one final outcome.")
        XCTAssertEqual(results.first?.projectPath, projectB.path)
        let sawStaleSuppression = await collector.contains {
            $0.contains("[TerminalLauncher] ARE snapshot request canceled/stale") &&
                $0.contains(projectA.path)
        }
        XCTAssertTrue(sawStaleSuppression, "Expected stale suppression marker for superseded request.")
    }

    func testLaunchTerminalStalePrimaryFailureDoesNotLaunchFallbackAfterNewerClick() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        var executedActions: [(path: String, action: ActivationAction)] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fetchRoutingSnapshot: { projectPath, _ in
                if projectPath == projectA.path {
                    return DaemonRoutingSnapshot(
                        version: 1,
                        workspaceId: "workspace-1",
                        projectPath: projectA.path,
                        status: "detached",
                        target: DaemonRoutingTarget(kind: "tmux_session", value: "project-a"),
                        confidence: "medium",
                        reasonCode: "TMUX_SESSION_DETACHED",
                        reason: "detached session",
                        evidence: [],
                        updatedAt: "2026-02-15T03:00:00Z",
                    )
                }
                return Self.makeAttachedTerminalAppSnapshot(
                    projectPath: projectPath,
                    appName: "Ghostty",
                )
            },
            executeActivationActionOverride: { action, projectPath, _ in
                executedActions.append((projectPath, action))
                if projectPath == projectA.path {
                    if case .ensureTmuxSession = action {
                        try? await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                        return false
                    }
                    if case .launchNewTerminal = action {
                        return true
                    }
                }
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 30_000_000)
        launcher.launchTerminal(for: projectB)
        try? await _Concurrency.Task.sleep(nanoseconds: 500_000_000)

        let staleFallbackLaunches = executedActions.filter { entry in
            guard entry.path == projectA.path else { return false }
            if case .launchNewTerminal = entry.action {
                return true
            }
            return false
        }

        XCTAssertTrue(
            staleFallbackLaunches.isEmpty,
            "Stale request must not launch fallback after a newer click wins.",
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, projectB.path)
    }

    private static func makeAttachedTerminalAppSnapshot(projectPath: String, appName: String) -> DaemonRoutingSnapshot {
        DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: projectPath,
            status: "attached",
            target: DaemonRoutingTarget(kind: "terminal_app", value: appName),
            confidence: "high",
            reasonCode: "SHELL_ACTIVE",
            reason: "terminal active",
            evidence: [],
            updatedAt: "2026-02-15T02:00:00Z",
        )
    }

    private func makeProject(name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }
}
