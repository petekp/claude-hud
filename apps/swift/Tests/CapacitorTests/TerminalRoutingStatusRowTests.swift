@testable import Capacitor
import XCTest

final class TerminalRoutingStatusRowTests: XCTestCase {
    func testAERRoutingPresentationUsesStatusAndReasonCodeForAttachedTmux() {
        let snapshot = makeSnapshot(
            status: "attached",
            targetKind: "tmux_session",
            targetValue: "caps",
            reasonCode: "TMUX_CLIENT_ATTACHED",
            reason: "this text should not drive copy",
        )

        let presentation = TerminalRoutingStatusCopy.arePresentation(snapshot)
        XCTAssertEqual(presentation.tmuxSummary, "tmux attached")
        XCTAssertEqual(presentation.targetSummary, "target tmux:caps")
        XCTAssertEqual(presentation.tooltip, "Attached tmux client detected for this workspace.")
        XCTAssertTrue(presentation.isAttached)
    }

    func testAERRoutingPresentationUsesDetachedSummaryForDetachedStatus() {
        let snapshot = makeSnapshot(
            status: "detached",
            targetKind: "tmux_session",
            targetValue: "caps",
            reasonCode: "TMUX_SESSION_DETACHED",
            reason: "ignored",
        )

        let presentation = TerminalRoutingStatusCopy.arePresentation(snapshot)
        XCTAssertEqual(presentation.tmuxSummary, "tmux detached")
        XCTAssertEqual(presentation.tooltip, "Tmux session exists but no attached tmux client is active.")
        XCTAssertFalse(presentation.isAttached)
    }

    func testAERRoutingPresentationUsesUnavailableFallbackWhenNoTrustedEvidence() {
        let snapshot = makeSnapshot(
            status: "unavailable",
            targetKind: "none",
            targetValue: nil,
            reasonCode: "NO_TRUSTED_EVIDENCE",
            reason: "ignored",
        )

        let presentation = TerminalRoutingStatusCopy.arePresentation(snapshot)
        XCTAssertEqual(presentation.tmuxSummary, "routing unavailable")
        XCTAssertEqual(presentation.targetSummary, "target unknown")
        XCTAssertEqual(presentation.tooltip, "No trusted routing evidence is currently available.")
        XCTAssertFalse(presentation.isAttached)
    }

    private func makeSnapshot(
        status: String,
        targetKind: String,
        targetValue: String?,
        reasonCode: String,
        reason: String,
    ) -> DaemonRoutingSnapshot {
        DaemonRoutingSnapshot(
            version: 1,
            workspaceId: "workspace-1",
            projectPath: "/Users/petepetrash/Code/capacitor",
            status: status,
            target: DaemonRoutingTarget(kind: targetKind, value: targetValue),
            confidence: "high",
            reasonCode: reasonCode,
            reason: reason,
            evidence: [],
            updatedAt: "2026-02-14T15:00:00Z",
        )
    }
}
