@testable import Capacitor
import XCTest

final class TerminalRoutingStatusCopyTests: XCTestCase {
    func testUnavailablePresentationUsesUnavailableDefaults() {
        let presentation = TerminalRoutingStatusCopy.unavailablePresentation()
        XCTAssertEqual(presentation.tmuxSummary, "routing unavailable")
        XCTAssertEqual(presentation.targetSummary, "target unknown")
        XCTAssertEqual(presentation.tooltip, "Routing snapshot unavailable.")
        XCTAssertFalse(presentation.isAttached)
    }

    func testAERRoutingPresentationUsesTerminalTargetSummary() {
        let snapshot = DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: "/Users/petepetrash/Code/capacitor",
            status: "detached",
            target: DaemonRoutingTarget(kind: "terminal_app", value: "ghostty"),
            confidence: "high",
            reasonCode: "SHELL_FALLBACK_ACTIVE",
            reason: "fallback",
            evidence: [],
            updatedAt: "2026-02-14T15:00:00Z",
        )

        let presentation = TerminalRoutingStatusCopy.arePresentation(snapshot)
        XCTAssertEqual(presentation.tmuxSummary, "tmux detached")
        XCTAssertEqual(presentation.targetSummary, "target ghostty")
        XCTAssertEqual(presentation.tooltip, "Using fresh shell telemetry fallback for routing.")
        XCTAssertFalse(presentation.isAttached)
    }
}
