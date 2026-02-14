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
        XCTAssertFalse(status.hasAnyShells)
        XCTAssertNil(status.tmuxClientTty)
        XCTAssertNil(status.targetParentApp)
        XCTAssertNil(status.targetTmuxSession)
        XCTAssertNil(status.lastSeenAt)
        XCTAssertFalse(status.isUsingLastKnownTarget)
        XCTAssertFalse(status.hasStaleTelemetry)
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
        XCTAssertTrue(status.hasAnyShells)
        XCTAssertEqual(status.tmuxClientTty, "/dev/ttys015")
        XCTAssertEqual(status.targetParentApp, "tmux")
        XCTAssertEqual(status.targetTmuxSession, "tool-ui")
        XCTAssertNotNil(status.lastSeenAt)
        XCTAssertFalse(status.isUsingLastKnownTarget)
        XCTAssertFalse(status.hasStaleTelemetry)
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
        XCTAssertTrue(status.hasAnyShells)
        XCTAssertNil(status.tmuxClientTty)
        XCTAssertEqual(status.targetParentApp, "tmux")
        XCTAssertEqual(status.targetTmuxSession, "capacitor")
        XCTAssertNotNil(status.lastSeenAt)
        XCTAssertTrue(status.isUsingLastKnownTarget)
        XCTAssertTrue(status.hasStaleTelemetry)
        XCTAssertNotNil(status.staleAgeMinutes(reference: Date()))
    }

    func testRoutingStatusUsesLastKnownTmuxTargetWhenActiveShellIsUnknown() {
        let store = ShellStateStore()
        let now = Date()
        let staleTmux = now.addingTimeInterval(-(14 * 60 * 60))
        let state = ShellCwdState(
            version: 1,
            shells: [
                "2001": makeEntry(
                    cwd: "/Users/pete/Code/capacitor",
                    tty: "/dev/ttys022",
                    parentApp: nil,
                    tmuxSession: nil,
                    tmuxClientTty: nil,
                    updatedAt: now,
                ),
                "2002": makeEntry(
                    cwd: "/Users/pete/Code/capacitor",
                    tty: "/dev/ttys099",
                    parentApp: "tmux",
                    tmuxSession: "capacitor",
                    tmuxClientTty: "/dev/ttys022",
                    updatedAt: staleTmux,
                ),
            ],
        )
        store.setStateForTesting(state)

        let status = store.routingStatus
        XCTAssertTrue(status.hasActiveShells)
        XCTAssertTrue(status.hasAttachedTmuxClient)
        XCTAssertEqual(status.tmuxClientTty, "/dev/ttys022")
        XCTAssertEqual(status.targetParentApp, "tmux")
        XCTAssertEqual(status.targetTmuxSession, "capacitor")
        XCTAssertTrue(status.isUsingLastKnownTarget)
    }

    func testRoutingStatusPrefersUsableActiveTargetOverLastKnownTarget() {
        let store = ShellStateStore()
        let now = Date()
        let olderTmux = now.addingTimeInterval(-(60 * 60))
        let state = ShellCwdState(
            version: 1,
            shells: [
                "3001": makeEntry(
                    cwd: "/Users/pete/Code/capacitor",
                    tty: "/dev/ttys011",
                    parentApp: "ghostty",
                    tmuxSession: nil,
                    tmuxClientTty: nil,
                    updatedAt: now,
                ),
                "3002": makeEntry(
                    cwd: "/Users/pete/Code/capacitor",
                    tty: "/dev/ttys099",
                    parentApp: "tmux",
                    tmuxSession: "capacitor",
                    tmuxClientTty: "/dev/ttys099",
                    updatedAt: olderTmux,
                ),
            ],
        )
        store.setStateForTesting(state)

        let status = store.routingStatus
        XCTAssertEqual(status.targetParentApp, "ghostty")
        XCTAssertNil(status.targetTmuxSession)
        XCTAssertFalse(status.isUsingLastKnownTarget)
    }

    func testShadowComparableDecisionMapsAttachedTmuxStatus() {
        let status = ShellRoutingStatus(
            hasActiveShells: true,
            hasAttachedTmuxClient: true,
            hasAnyShells: true,
            tmuxClientTty: "/dev/ttys015",
            targetParentApp: "tmux",
            targetTmuxSession: "caps",
            lastSeenAt: Date(),
            isUsingLastKnownTarget: false,
        )

        let decision = ShellStateStore.shadowComparableDecision(from: status)
        XCTAssertEqual(decision.status, "attached")
        XCTAssertEqual(decision.targetKind, "tmux_session")
        XCTAssertEqual(decision.targetValue, "caps")
    }

    func testShadowComparableDecisionMapsUnavailableWithoutShells() {
        let status = ShellRoutingStatus(
            hasActiveShells: false,
            hasAttachedTmuxClient: false,
            hasAnyShells: false,
            tmuxClientTty: nil,
            targetParentApp: nil,
            targetTmuxSession: nil,
            lastSeenAt: nil,
            isUsingLastKnownTarget: false,
        )

        let decision = ShellStateStore.shadowComparableDecision(from: status)
        XCTAssertEqual(decision.status, "unavailable")
        XCTAssertEqual(decision.targetKind, "none")
        XCTAssertNil(decision.targetValue)
    }
}
