@testable import Capacitor
import XCTest

final class DaemonStatusEvaluatorTests: XCTestCase {
    func testSuppressesOfflineDuringStartupGrace() {
        var evaluator = DaemonStatusEvaluator()
        let now = Date()
        evaluator.noteDaemonStartup(now: now)

        let status = evaluator.statusForHealthResult(
            isEnabled: true,
            result: .failure(TestError()),
            now: now.addingTimeInterval(DaemonStatusEvaluator.startupGraceInterval / 2)
        )

        XCTAssertNil(status)
    }

    func testReportsOfflineAfterStartupGraceExpires() {
        var evaluator = DaemonStatusEvaluator()
        let now = Date()
        evaluator.noteDaemonStartup(now: now)

        let status = evaluator.statusForHealthResult(
            isEnabled: true,
            result: .failure(TestError()),
            now: now.addingTimeInterval(DaemonStatusEvaluator.startupGraceInterval + 0.1)
        )

        XCTAssertEqual(status?.isHealthy, false)
        XCTAssertEqual(status?.message, "Daemon unavailable")
    }

    func testReportsHealthyWhenDaemonResponds() {
        let evaluator = DaemonStatusEvaluator()
        let health = DaemonHealth(status: "ok", pid: 42, version: "1.0.0", protocolVersion: 1)

        let status = evaluator.statusForHealthResult(
            isEnabled: true,
            result: .success(health),
            now: Date()
        )

        XCTAssertEqual(status?.isHealthy, true)
        XCTAssertEqual(status?.message, "ok")
        XCTAssertEqual(status?.pid, 42)
    }

    func testReportsDisabledWhenDaemonIsNotEnabled() {
        let evaluator = DaemonStatusEvaluator()

        let status = evaluator.statusForHealthResult(
            isEnabled: false,
            result: .failure(TestError()),
            now: Date()
        )

        XCTAssertEqual(status?.isEnabled, false)
        XCTAssertEqual(status?.message, "Daemon disabled")
    }

    func testBeginStartupClearsOfflineStatus() {
        var evaluator = DaemonStatusEvaluator()
        let offlineStatus = DaemonStatus(
            isEnabled: true,
            isHealthy: false,
            message: "Daemon unavailable",
            pid: nil,
            version: nil
        )

        let updatedStatus = evaluator.beginStartup(currentStatus: offlineStatus, now: Date())

        XCTAssertNil(updatedStatus)
    }
}

private struct TestError: Error {}
