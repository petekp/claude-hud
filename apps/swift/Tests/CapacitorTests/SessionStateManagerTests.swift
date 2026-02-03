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
        server.start(response: makeProjectStatesResponse(projectPath: "/Users/Pete/Code/Project"))

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

    private func makeProjectStatesResponse(projectPath: String) -> Data {
        let json = """
        {"ok":true,"id":"test","data":[{"project_path":"\(projectPath)","state":"working","updated_at":"2026-02-02T19:00:00Z","state_changed_at":"2026-02-02T19:00:00Z","session_id":"session-1","session_count":1,"active_count":1,"has_session":true}]}
        """
        var data = Data(json.utf8)
        data.append(0x0A)
        return data
    }
}
