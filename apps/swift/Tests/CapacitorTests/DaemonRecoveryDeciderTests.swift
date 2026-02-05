@testable import Capacitor
import XCTest

final class DaemonRecoveryDeciderTests: XCTestCase {
    func testAttemptsRecoveryOnConnectionRefusedWithCooldown() {
        var decider = DaemonRecoveryDecider(cooldownInterval: 10.0, lastAttemptAt: nil)
        let now = Date()

        XCTAssertTrue(decider.shouldAttemptRecovery(after: POSIXError(.ECONNREFUSED), now: now))
        XCTAssertFalse(
            decider.shouldAttemptRecovery(after: POSIXError(.ECONNREFUSED), now: now.addingTimeInterval(1.0))
        )
        XCTAssertTrue(
            decider.shouldAttemptRecovery(after: POSIXError(.ECONNREFUSED), now: now.addingTimeInterval(10.1))
        )
    }

    func testAttemptsRecoveryOnTimeout() {
        var decider = DaemonRecoveryDecider(cooldownInterval: 10.0, lastAttemptAt: nil)
        XCTAssertTrue(decider.shouldAttemptRecovery(after: DaemonClientError.timeout, now: Date()))
    }

    func testAttemptsRecoveryOnInvalidResponse() {
        var decider = DaemonRecoveryDecider(cooldownInterval: 10.0, lastAttemptAt: nil)
        XCTAssertTrue(decider.shouldAttemptRecovery(after: DaemonClientError.invalidResponse, now: Date()))
    }

    func testDoesNotAttemptRecoveryOnDaemonUnavailableErrors() {
        var decider = DaemonRecoveryDecider(cooldownInterval: 10.0, lastAttemptAt: nil)
        XCTAssertFalse(
            decider.shouldAttemptRecovery(after: DaemonClientError.daemonUnavailable("nope"), now: Date())
        )
    }

    func testTreatsNSErrorPosixDomainAsRecoverable() {
        var decider = DaemonRecoveryDecider(cooldownInterval: 10.0, lastAttemptAt: nil)
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ECONNREFUSED.rawValue))
        XCTAssertTrue(decider.shouldAttemptRecovery(after: err, now: Date()))
    }
}
