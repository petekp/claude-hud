@testable import Capacitor
import XCTest

final class ProjectOrderStoreTests: XCTestCase {
    func testSaveAndLoadOrder() throws {
        let suiteName = "ProjectOrderStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        ProjectOrderStore.save(["/tmp/a", "/tmp/b"], to: defaults)
        let loaded = ProjectOrderStore.load(from: defaults)

        XCTAssertEqual(loaded, ["/tmp/a", "/tmp/b"])
    }
}
