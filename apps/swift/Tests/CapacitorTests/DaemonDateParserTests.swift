import XCTest

@testable import Capacitor

final class DaemonDateParserTests: XCTestCase {
    func testParsesDateWithoutFractionalSeconds() {
        let date = DaemonDateParser.parse("2026-02-02T19:00:00Z")
        XCTAssertNotNil(date)
    }

    func testParsesDateWithFractionalSeconds() {
        let date = DaemonDateParser.parse("2026-02-02T19:00:00.123Z")
        XCTAssertNotNil(date)
    }

    func testParsesDateWithMicroseconds() {
        let date = DaemonDateParser.parse("2026-02-02T19:00:00.123456Z")
        XCTAssertNotNil(date)
    }

    func testRejectsInvalidDate() {
        let date = DaemonDateParser.parse("not-a-date")
        XCTAssertNil(date)
    }
}
