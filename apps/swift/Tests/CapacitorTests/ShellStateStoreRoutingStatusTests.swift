@testable import Capacitor
import XCTest

@MainActor
final class ShellStateStoreRoutingStatusTests: XCTestCase {
    private func makeEntry(
        cwd: String,
        tty: String = "/dev/ttys010",
        parentApp: String? = "ghostty",
        tmuxSession: String? = nil,
        tmuxClientTty: String? = nil,
        updatedAt: Date = Date(),
    ) -> ShellEntry {
        ShellEntry(
            cwd: cwd,
            tty: tty,
            parentApp: parentApp,
            tmuxSession: tmuxSession,
            tmuxClientTty: tmuxClientTty,
            updatedAt: updatedAt,
        )
    }

    func testRoutingStatusWithoutShellsShowsUnavailable() {
        let store = ShellStateStore()
        store.setStateForTesting(nil)

        let status = store.routingStatus
        XCTAssertFalse(status.hasActiveShells)
        XCTAssertFalse(status.hasAttachedTmuxClient)
        XCTAssertNil(status.tmuxClientTty)
        XCTAssertNil(status.targetParentApp)
        XCTAssertNil(status.targetTmuxSession)
    }

    func testRoutingStatusDetectsAttachedTmuxClientAndTargetSession() {
        let store = ShellStateStore()
        let state = ShellCwdState(
            version: 1,
            shells: [
                "1001": makeEntry(
                    cwd: "/Users/pete/Code/tool-ui",
                    parentApp: "tmux",
                    tmuxSession: "tool-ui",
                    tmuxClientTty: "/dev/ttys015",
                    updatedAt: Date(),
                ),
            ],
        )
        store.setStateForTesting(state)

        let status = store.routingStatus
        XCTAssertTrue(status.hasActiveShells)
        XCTAssertTrue(status.hasAttachedTmuxClient)
        XCTAssertEqual(status.tmuxClientTty, "/dev/ttys015")
        XCTAssertEqual(status.targetParentApp, "tmux")
        XCTAssertEqual(status.targetTmuxSession, "tool-ui")
    }

    func testRoutingStatusIgnoresStaleShells() {
        let store = ShellStateStore()
        let staleDate = Date().addingTimeInterval(-(11 * 60))
        let state = ShellCwdState(
            version: 1,
            shells: [
                "1002": makeEntry(
                    cwd: "/Users/pete/Code/capacitor",
                    parentApp: "tmux",
                    tmuxSession: "capacitor",
                    tmuxClientTty: "/dev/ttys021",
                    updatedAt: staleDate,
                ),
            ],
        )
        store.setStateForTesting(state)

        let status = store.routingStatus
        XCTAssertFalse(status.hasActiveShells)
        XCTAssertFalse(status.hasAttachedTmuxClient)
        XCTAssertNil(status.tmuxClientTty)
    }
}
