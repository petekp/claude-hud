@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class SessionStateManagerTests: XCTestCase {
    func testSessionStateMatchingIgnoresCaseDifferences() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let socketPath = tempDir.appendingPathComponent("daemon.sock").path

        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }
        server.start(response: makeProjectStatesResponse([
            .init(
                projectPath: "/Users/Pete/Code/Project",
                state: "working",
                updatedAt: "2026-02-02T19:00:00Z",
                stateChangedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-1",
            ),
        ]))

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let project = Project(
            name: "Project",
            path: "/Users/pete/code/project",
            displayPath: "/Users/pete/code/project",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )

        manager.refreshSessionStates(for: [project])
        let state = await waitForSessionState(manager, project: project)
        XCTAssertNotNil(state)
    }

    func testSessionStatePrefersMostSpecificProject() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let socketPath = tempDir.appendingPathComponent("daemon.sock").path

        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }

        let response = makeProjectStatesResponse([
            .init(
                projectPath: "/Users/pete/Code/assistant-ui/packages/web",
                state: "working",
                updatedAt: "2026-02-02T19:00:00Z",
                stateChangedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-1",
            ),
        ])
        server.start(response: response)

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let rootProject = makeProject(
            "assistant-ui",
            path: "/Users/pete/Code/assistant-ui",
        )
        let packageProject = makeProject(
            "assistant-ui-web",
            path: "/Users/pete/Code/assistant-ui/packages/web",
        )

        manager.refreshSessionStates(for: [rootProject, packageProject])
        let packageState = await waitForSessionState(manager, project: packageProject)

        XCTAssertNotNil(packageState)
        XCTAssertNil(manager.getSessionState(for: rootProject))
    }

    func testSessionStateUsesChildWhenOnlyRootPinned() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let socketPath = tempDir.appendingPathComponent("daemon.sock").path

        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }

        let response = makeProjectStatesResponse([
            .init(
                projectPath: "/Users/pete/Code/assistant-ui/packages/web",
                state: "working",
                updatedAt: "2026-02-02T19:00:00Z",
                stateChangedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-1",
            ),
        ])
        server.start(response: response)

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let rootProject = makeProject(
            "assistant-ui",
            path: "/Users/pete/Code/assistant-ui",
        )

        manager.refreshSessionStates(for: [rootProject])
        let rootState = await waitForSessionState(manager, project: rootProject)

        XCTAssertNotNil(rootState)
    }

    func testSessionStateDoesNotMatchParentToChild() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let socketPath = tempDir.appendingPathComponent("daemon.sock").path

        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }

        let response = makeProjectStatesResponse([
            .init(
                projectPath: "/Users/pete/Code/assistant-ui",
                state: "working",
                updatedAt: "2026-02-02T19:00:00Z",
                stateChangedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-1",
            ),
        ])
        server.start(response: response)

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let packageProject = makeProject(
            "assistant-ui-web",
            path: "/Users/pete/Code/assistant-ui/packages/web",
        )

        manager.refreshSessionStates(for: [packageProject])
        let packageState = await waitForSessionState(manager, project: packageProject)

        XCTAssertNil(packageState)
    }

    func testSessionStateMatchesWorktreeToPinnedPath() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let repoRoot = tempDir.appendingPathComponent("assistant-ui")
        let repoGit = repoRoot.appendingPathComponent(".git")
        let pinnedPath = repoRoot.appendingPathComponent("apps/docs")

        try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinnedPath, withIntermediateDirectories: true)

        let worktreeRoot = tempDir.appendingPathComponent("assistant-ui-wt")
        let worktreePath = worktreeRoot.appendingPathComponent("apps/docs")
        try FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)

        let worktreeGitDir = repoGit.appendingPathComponent("worktrees/feat-docs")
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        let commondirPath = worktreeGitDir.appendingPathComponent("commondir")
        try "../..".write(to: commondirPath, atomically: true, encoding: .utf8)

        let gitFile = worktreeRoot.appendingPathComponent(".git")
        let gitFileContents = "gitdir: \(worktreeGitDir.path)\n"
        try gitFileContents.write(to: gitFile, atomically: true, encoding: .utf8)

        let socketPath = tempDir.appendingPathComponent("daemon.sock").path
        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }
        server.start(response: makeProjectStatesResponse([
            .init(
                projectPath: worktreePath.path,
                state: "working",
                updatedAt: "2026-02-02T19:00:00Z",
                stateChangedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-1",
            ),
        ]))

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let project = makeProject(
            "assistant-ui-docs",
            path: pinnedPath.path,
        )

        manager.refreshSessionStates(for: [project])
        let state = await waitForSessionState(manager, project: project)

        XCTAssertNotNil(state)
    }

    func testSessionStateMatchesWorktreeRootToPinnedWorkspace() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let repoRoot = tempDir.appendingPathComponent("assistant-ui")
        let repoGit = repoRoot.appendingPathComponent(".git")
        let pinnedPath = repoRoot.appendingPathComponent("apps/docs")

        try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinnedPath, withIntermediateDirectories: true)

        let worktreeRoot = tempDir.appendingPathComponent("assistant-ui-wt")
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)

        let worktreeGitDir = repoGit.appendingPathComponent("worktrees/feat-docs")
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        let commondirPath = worktreeGitDir.appendingPathComponent("commondir")
        try "../..".write(to: commondirPath, atomically: true, encoding: .utf8)

        let gitFile = worktreeRoot.appendingPathComponent(".git")
        let gitFileContents = "gitdir: \(worktreeGitDir.path)\n"
        try gitFileContents.write(to: gitFile, atomically: true, encoding: .utf8)

        let socketPath = tempDir.appendingPathComponent("daemon.sock").path
        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }
        server.start(response: makeProjectStatesResponse([
            .init(
                projectPath: worktreeRoot.path,
                state: "ready",
                updatedAt: "2026-02-02T19:00:00Z",
                stateChangedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-1",
            ),
        ]))

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let project = makeProject(
            "assistant-ui-docs",
            path: pinnedPath.path,
        )

        manager.refreshSessionStates(for: [project])
        let state = await waitForSessionState(manager, project: project)

        XCTAssertNotNil(state)
        XCTAssertEqual(state?.state, .ready)
    }

    func testSessionStateMatchesRepoRootToOnlyPinnedWorkspace() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let repoRoot = tempDir.appendingPathComponent("assistant-ui")
        let repoGit = repoRoot.appendingPathComponent(".git")
        let pinnedPath = repoRoot.appendingPathComponent("apps/docs")

        try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinnedPath, withIntermediateDirectories: true)

        let socketPath = tempDir.appendingPathComponent("daemon.sock").path
        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }
        server.start(response: makeProjectStatesResponse([
            .init(
                projectPath: repoRoot.path,
                state: "ready",
                updatedAt: "2026-02-02T19:00:00Z",
                stateChangedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-1",
            ),
        ]))

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let project = makeProject(
            "assistant-ui-docs",
            path: pinnedPath.path,
        )

        manager.refreshSessionStates(for: [project])
        let state = await waitForSessionState(manager, project: project)

        XCTAssertNotNil(state)
        XCTAssertEqual(state?.state, .ready)
    }

    func testSessionStateMatchesOtherPathInSameRepoToPinnedWorkspace() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let repoRoot = tempDir.appendingPathComponent("assistant-ui")
        let repoGit = repoRoot.appendingPathComponent(".git")
        let pinnedPath = repoRoot.appendingPathComponent("apps/docs")
        let otherPath = repoRoot.appendingPathComponent("packages/mcp-app-studio")

        try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinnedPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherPath, withIntermediateDirectories: true)

        let socketPath = tempDir.appendingPathComponent("daemon.sock").path
        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }
        server.start(response: makeProjectStatesResponse([
            .init(
                projectPath: otherPath.path,
                state: "working",
                updatedAt: "2026-02-02T19:00:00Z",
                stateChangedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-1",
            ),
        ]))

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let project = makeProject(
            "assistant-ui-docs",
            path: pinnedPath.path,
        )

        manager.refreshSessionStates(for: [project])
        let state = await waitForSessionState(manager, project: project)

        XCTAssertNotNil(state)
        XCTAssertEqual(state?.state, .working)
    }

    func testSessionStateMapsDaemonStates() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let socketPath = tempDir.appendingPathComponent("daemon.sock").path

        let fixtures: [(String, String, SessionState)] = [
            ("/Users/pete/Code/state-working", "working", .working),
            ("/Users/pete/Code/state-ready", "ready", .ready),
            ("/Users/pete/Code/state-waiting", "waiting", .waiting),
            ("/Users/pete/Code/state-compacting", "compacting", .compacting),
            ("/Users/pete/Code/state-idle", "idle", .idle),
            ("/Users/pete/Code/state-unknown", "mystery", .idle),
        ]

        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }
        server.start(response: makeProjectStatesResponse(
            fixtures.map {
                .init(
                    projectPath: $0.0,
                    state: $0.1,
                    updatedAt: "2026-02-02T19:00:00Z",
                    stateChangedAt: "2026-02-02T19:00:00Z",
                    sessionId: "session-\($0.1)",
                )
            },
        ))

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let projects = fixtures.map { makeProject($0.1, path: $0.0) }

        manager.refreshSessionStates(for: projects)

        for (index, fixture) in fixtures.enumerated() {
            let project = projects[index]
            let state = await waitForSessionState(manager, project: project)
            XCTAssertNotNil(state)
            XCTAssertEqual(state?.state, fixture.2)
        }
    }

    func testSessionStatePrefersNewestStateWhenTimestampsUseMicroseconds() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let socketPath = tempDir.appendingPathComponent("daemon.sock").path

        let projectPath = "/Users/pete/Code/writing"
        // Send an older state first, then a newer state for the same project.
        // SessionStateManager must pick the newest based on updated_at/state_changed_at.
        let fixtures: [ProjectStateFixture] = [
            .init(
                projectPath: projectPath,
                state: "idle",
                updatedAt: "2026-02-11T20:19:03.104550+00:00",
                stateChangedAt: "2026-02-11T20:19:03.104550+00:00",
                sessionId: "session-old",
            ),
            .init(
                projectPath: projectPath,
                state: "working",
                updatedAt: "2026-02-11T20:19:03.204550+00:00",
                stateChangedAt: "2026-02-11T20:19:03.204550+00:00",
                sessionId: "session-new",
            ),
        ]

        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }
        server.start(response: makeProjectStatesResponse(fixtures))

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let project = makeProject("writing", path: projectPath)

        manager.refreshSessionStates(for: [project])
        let state = await waitForSessionState(manager, project: project)

        XCTAssertNotNil(state)
        XCTAssertEqual(state?.state, .working)
        XCTAssertEqual(state?.sessionId, "session-new")
    }

    func testRepoFallbackDoesNotOverrideDirectWorkspaceMatch() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let repoRoot = tempDir.appendingPathComponent("monorepo")
        let repoGit = repoRoot.appendingPathComponent(".git")
        let pinnedA = repoRoot.appendingPathComponent("apps/a")
        let pinnedB = repoRoot.appendingPathComponent("apps/b")
        let unmatchedSameRepo = repoRoot.appendingPathComponent("packages/unpinned")

        try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinnedA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinnedB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unmatchedSameRepo, withIntermediateDirectories: true)

        let socketPath = tempDir.appendingPathComponent("daemon.sock").path
        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }
        server.start(response: makeProjectStatesResponse([
            // Unmatched path in same repo (fallback candidate): newer + working
            .init(
                projectPath: unmatchedSameRepo.path,
                state: "working",
                updatedAt: "2026-02-11T20:30:00Z",
                stateChangedAt: "2026-02-11T20:30:00Z",
                sessionId: "session-fallback",
            ),
            // Direct workspace match for pinnedB: older + ready
            .init(
                projectPath: pinnedB.path,
                state: "ready",
                updatedAt: "2026-02-11T20:29:00Z",
                stateChangedAt: "2026-02-11T20:29:00Z",
                sessionId: "session-direct",
            ),
        ]), maxConnections: 4)

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let projectA = makeProject("app-a", path: pinnedA.path)
        let projectB = makeProject("app-b", path: pinnedB.path)

        manager.refreshSessionStates(for: [projectA, projectB])
        let stateA = await waitForSessionState(manager, project: projectA)
        let stateB = await waitForSessionState(manager, project: projectB)

        XCTAssertEqual(stateA?.state, .working, "Fallback activity should still light up pinned workspaces without direct states.")
        XCTAssertEqual(stateB?.state, .ready, "Direct workspace state must not be overwritten by fallback state from another path in the same repo.")
        XCTAssertEqual(stateB?.sessionId, "session-direct")
    }

    func testGetSessionStateFallsBackToNormalizedPathLookup() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let realProjectPath = tempDir.appendingPathComponent("workspace")
        let symlinkPath = tempDir.appendingPathComponent("workspace-link")
        try FileManager.default.createDirectory(at: realProjectPath, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath.path, withDestinationPath: realProjectPath.path)

        let manager = SessionStateManager()
        manager.setSessionStatesForTesting([
            symlinkPath.path + "/": makeSessionState(state: .ready, sessionId: "session-symlink"),
        ])

        let project = makeProject("workspace", path: realProjectPath.path.uppercased())
        let state = manager.getSessionState(for: project)

        XCTAssertNotNil(state, "Equivalent normalized paths should resolve to existing session state.")
        XCTAssertEqual(state?.sessionId, "session-symlink")
    }

    func testGetSessionStateDirectLookupHasPriorityOverNormalizedFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let realProjectPath = tempDir.appendingPathComponent("workspace")
        let symlinkPath = tempDir.appendingPathComponent("workspace-link")
        try FileManager.default.createDirectory(at: realProjectPath, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath.path, withDestinationPath: realProjectPath.path)

        let manager = SessionStateManager()
        manager.setSessionStatesForTesting([
            symlinkPath.path + "/": makeSessionState(state: .ready, sessionId: "session-fallback"),
            realProjectPath.path: makeSessionState(state: .working, sessionId: "session-direct"),
        ])

        let project = makeProject("workspace", path: realProjectPath.path)
        let state = manager.getSessionState(for: project)

        XCTAssertEqual(state?.sessionId, "session-direct")
        XCTAssertEqual(state?.state, .working)
    }

    private func waitForSessionState(
        _ manager: SessionStateManager,
        project: Project,
        timeout: TimeInterval = 1.0,
    ) async -> ProjectSessionState? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = manager.getSessionState(for: project) {
                return state
            }
            try? await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
        }
        return manager.getSessionState(for: project)
    }

    private struct ProjectStateFixture {
        let projectPath: String
        let state: String
        let updatedAt: String
        let stateChangedAt: String
        let sessionId: String?
    }

    private func makeSessionState(state: SessionState, sessionId: String?) -> ProjectSessionState {
        ProjectSessionState(
            state: state,
            stateChangedAt: nil,
            updatedAt: nil,
            sessionId: sessionId,
            workingOn: nil,
            context: nil,
            thinking: nil,
            hasSession: true,
        )
    }

    private func makeProject(_ name: String, path: String) -> Project {
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

    private func makeProjectStatesResponse(_ states: [ProjectStateFixture]) -> Data {
        let items = states.map { state in
            let sessionValue = state.sessionId.map { "\"\($0)\"" } ?? "null"
            return """
            {"project_path":"\(state.projectPath)","state":"\(state.state)","updated_at":"\(state.updatedAt)","state_changed_at":"\(state.stateChangedAt)","session_id":\(sessionValue),"session_count":1,"active_count":1,"has_session":true}
            """
        }
        let json = """
        {"ok":true,"id":"test","data":[\(items.joined(separator: ","))]}
        """
        var data = Data(json.utf8)
        data.append(0x0A)
        return data
    }
}
