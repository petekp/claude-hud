@testable import Capacitor
import XCTest

@MainActor
final class HookDiagnosticPresentationTests: XCTestCase {
    func testSetupCardHiddenWhenHooksIdleAfterFirstRun() {
        let diagnostic = HookDiagnosticReport(
            isHealthy: false,
            primaryIssue: .notFiring(lastSeenSecs: 120),
            canAutoFix: true,
            isFirstRun: false,
            binaryOk: true,
            configOk: true,
            firingOk: false,
            symlinkPath: "/tmp/hud-hook",
            symlinkTarget: nil,
            lastHeartbeatAgeSecs: 120,
        )

        XCTAssertFalse(diagnostic.shouldShowSetupCard)
    }

    func testSetupCardHiddenOnFirstRunWhenNotFiring() {
        let diagnostic = HookDiagnosticReport(
            isHealthy: false,
            primaryIssue: .notFiring(lastSeenSecs: nil),
            canAutoFix: true,
            isFirstRun: true,
            binaryOk: true,
            configOk: true,
            firingOk: false,
            symlinkPath: "/tmp/hud-hook",
            symlinkTarget: nil,
            lastHeartbeatAgeSecs: nil,
        )

        XCTAssertFalse(diagnostic.shouldShowSetupCard)
    }

    func testSetupCardShownOnConfigMissing() {
        let diagnostic = HookDiagnosticReport(
            isHealthy: false,
            primaryIssue: .configMissing,
            canAutoFix: true,
            isFirstRun: false,
            binaryOk: true,
            configOk: false,
            firingOk: false,
            symlinkPath: "/tmp/hud-hook",
            symlinkTarget: nil,
            lastHeartbeatAgeSecs: nil,
        )

        XCTAssertTrue(diagnostic.shouldShowSetupCard)
    }

    func testSetupCardShownOnFirstRunWhenConfigMissing() {
        let diagnostic = HookDiagnosticReport(
            isHealthy: false,
            primaryIssue: .configMissing,
            canAutoFix: true,
            isFirstRun: true,
            binaryOk: true,
            configOk: false,
            firingOk: false,
            symlinkPath: "/tmp/hud-hook",
            symlinkTarget: nil,
            lastHeartbeatAgeSecs: nil,
        )

        XCTAssertTrue(diagnostic.shouldShowSetupCard)
    }
}
