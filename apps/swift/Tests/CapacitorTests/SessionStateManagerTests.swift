import Foundation
import XCTest

@testable import Capacitor

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
                sessionId: "session-1"
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
            isMissing: false
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
                sessionId: "session-1"
            ),
        ])
        server.start(response: response)

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let rootProject = makeProject(
            "assistant-ui",
            path: "/Users/pete/Code/assistant-ui"
        )
        let packageProject = makeProject(
            "assistant-ui-web",
            path: "/Users/pete/Code/assistant-ui/packages/web"
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
                sessionId: "session-1"
            ),
        ])
        server.start(response: response)

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let rootProject = makeProject(
            "assistant-ui",
            path: "/Users/pete/Code/assistant-ui"
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
                sessionId: "session-1"
            ),
        ])
        server.start(response: response)

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let manager = SessionStateManager()
        let packageProject = makeProject(
            "assistant-ui-web",
            path: "/Users/pete/Code/assistant-ui/packages/web"
        )

        manager.refreshSessionStates(for: [packageProject])
        let packageState = await waitForSessionState(manager, project: packageProject)

        XCTAssertNil(packageState)
    }

    private func waitForSessionState(
        _ manager: SessionStateManager,
        project: Project,
        timeout: TimeInterval = 1.0
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
            isMissing: false
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
