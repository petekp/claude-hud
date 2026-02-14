@testable import Capacitor
import XCTest

final class TerminalRoutingStatusCopyTests: XCTestCase {
    func testTmuxSummaryUsesTmuxSpecificStaleCopy() {
        let now = Date(timeIntervalSince1970: 10000)
        let stale = now.addingTimeInterval(-(23 * 60))
        let status = ShellRoutingStatus(
            hasActiveShells: false,
            hasAttachedTmuxClient: false,
            hasAnyShells: true,
            tmuxClientTty: nil,
            targetParentApp: "tmux",
            targetTmuxSession: "capacitor",
            lastSeenAt: stale,
            isUsingLastKnownTarget: true,
        )

        let summary = TerminalRoutingStatusCopy.tmuxSummary(status, referenceDate: now)
        XCTAssertEqual(summary, "tmux telemetry stale (23m ago)")
    }

    func testTargetSummaryUsesLastTargetPrefixWhenStale() {
        let status = ShellRoutingStatus(
            hasActiveShells: false,
            hasAttachedTmuxClient: false,
            hasAnyShells: true,
            tmuxClientTty: nil,
            targetParentApp: "tmux",
            targetTmuxSession: "tool-ui",
            lastSeenAt: Date(timeIntervalSince1970: 10000),
            isUsingLastKnownTarget: true,
        )

        let summary = TerminalRoutingStatusCopy.targetSummary(status)
        XCTAssertEqual(summary, "last target tmux:tool-ui")
    }

    func testTooltipIncludesAgeAndLastSeenWhenStale() {
        let now = Date(timeIntervalSince1970: 20000)
        let stale = now.addingTimeInterval(-(11 * 60))
        let status = ShellRoutingStatus(
            hasActiveShells: false,
            hasAttachedTmuxClient: false,
            hasAnyShells: true,
            tmuxClientTty: nil,
            targetParentApp: "ghostty",
            targetTmuxSession: nil,
            lastSeenAt: stale,
            isUsingLastKnownTarget: true,
        )

        let tooltip = TerminalRoutingStatusCopy.tooltip(status, referenceDate: now)
        XCTAssertTrue(tooltip.contains("Telemetry is stale"))
        XCTAssertTrue(tooltip.contains("11m ago"))
        XCTAssertTrue(tooltip.contains("Showing the last known target."))
    }
}
