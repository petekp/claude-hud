@testable import Capacitor
import XCTest

@MainActor
final class ShellStateStoreRoutingStatusTests: XCTestCase {
    func testSettingRoutingProjectPathToNilClearsSnapshot() {
        let store = ShellStateStore()
        store.setRoutingSnapshotForTesting(
            DaemonRoutingSnapshot(
                version: 1,
                workspaceId: "workspace-1",
                projectPath: "/tmp/project",
                status: "attached",
                target: DaemonRoutingTarget(kind: "tmux_session", value: "caps"),
                confidence: "high",
                reasonCode: "TMUX_CLIENT_ATTACHED",
                reason: "attached",
                evidence: [],
                updatedAt: "2026-02-14T15:00:00Z",
            ),
        )

        store.setRoutingProjectPath(nil)
        XCTAssertNil(store.areRoutingSnapshot)
    }

    func testSettingBlankRoutingProjectPathClearsSnapshot() {
        let store = ShellStateStore()
        store.setRoutingSnapshotForTesting(
            DaemonRoutingSnapshot(
                version: 1,
                workspaceId: "workspace-1",
                projectPath: "/tmp/project",
                status: "attached",
                target: DaemonRoutingTarget(kind: "tmux_session", value: "caps"),
                confidence: "high",
                reasonCode: "TMUX_CLIENT_ATTACHED",
                reason: "attached",
                evidence: [],
                updatedAt: "2026-02-14T15:00:00Z",
            ),
        )

        store.setRoutingProjectPath("   ")
        XCTAssertNil(store.areRoutingSnapshot)
    }

    func testSettingNonEmptyRoutingProjectPathKeepsCurrentSnapshot() {
        let store = ShellStateStore()
        let snapshot = DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: "/tmp/project",
            status: "attached",
            target: DaemonRoutingTarget(kind: "tmux_session", value: "caps"),
            confidence: "high",
            reasonCode: "TMUX_CLIENT_ATTACHED",
            reason: "attached",
            evidence: [],
            updatedAt: "2026-02-14T15:00:00Z",
        )
        store.setRoutingSnapshotForTesting(snapshot)

        store.setRoutingProjectPath("/tmp/project")
        XCTAssertEqual(store.areRoutingSnapshot, snapshot)
    }
}
