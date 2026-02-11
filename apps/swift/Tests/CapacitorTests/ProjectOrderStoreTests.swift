@testable import Capacitor
import XCTest

final class ProjectOrderStoreTests: XCTestCase {
    func testSaveAndLoadActiveOrder() throws {
        let suiteName = "ProjectOrderStoreTests-active-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        ProjectOrderStore.saveActive(["/tmp/a", "/tmp/b"], to: defaults)
        let loaded = ProjectOrderStore.loadActive(from: defaults)

        XCTAssertEqual(loaded, ["/tmp/a", "/tmp/b"])
    }

    func testSaveAndLoadIdleOrder() throws {
        let suiteName = "ProjectOrderStoreTests-idle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        ProjectOrderStore.saveIdle(["/tmp/c", "/tmp/d"], to: defaults)
        let loaded = ProjectOrderStore.loadIdle(from: defaults)

        XCTAssertEqual(loaded, ["/tmp/c", "/tmp/d"])
    }

    func testLoadReturnsEmptyArrayByDefault() throws {
        let suiteName = "ProjectOrderStoreTests-empty-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(ProjectOrderStore.loadActive(from: defaults), [])
        XCTAssertEqual(ProjectOrderStore.loadIdle(from: defaults), [])
    }
}
