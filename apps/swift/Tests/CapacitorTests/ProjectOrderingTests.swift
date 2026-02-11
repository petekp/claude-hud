@testable import Capacitor
import XCTest

final class ProjectOrderingTests: XCTestCase {
    // MARK: - Test Helpers

    private func makeProject(_ name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    private func makeSessionState(_ state: SessionState) -> ProjectSessionState {
        ProjectSessionState(
            state: state,
            stateChangedAt: nil,
            updatedAt: nil,
            sessionId: nil,
            workingOn: nil,
            context: nil,
            thinking: nil,
            hasSession: state != .idle,
        )
    }

    // MARK: - orderedProjects (basic, pre-existing)

    func testOrderedProjectsRespectsCustomOrderAndKeepsRemaining() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")

        let ordered = ProjectOrdering.orderedProjects(
            [projectA, projectB, projectC],
            customOrder: ["/tmp/c", "/tmp/a"],
        )

        XCTAssertEqual(ordered.map(\.path), ["/tmp/c", "/tmp/a", "/tmp/b"])
    }

    func testMovedOrderOnlyUsesProvidedList() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")

        let moved = ProjectOrdering.movedOrder(
            from: IndexSet(integer: 2),
            to: 0,
            in: [projectA, projectB, projectC],
        )

        XCTAssertEqual(moved, ["/tmp/c", "/tmp/a", "/tmp/b"])
    }

    // MARK: - isActive classification

    func testIsActiveReturnsTrueForWorkingSession() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.working),
        ]
        XCTAssertTrue(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveReturnsTrueForWaitingSession() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.waiting),
        ]
        XCTAssertTrue(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveReturnsTrueForCompactingSession() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.compacting),
        ]
        XCTAssertTrue(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveReturnsTrueForReadySession() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.ready),
        ]
        XCTAssertTrue(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveReturnsFalseForIdleSession() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.idle),
        ]
        XCTAssertFalse(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveReturnsFalseForNoSession() {
        let states: [String: ProjectSessionState] = [:]
        XCTAssertFalse(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    // MARK: - orderedGroupedProjects

    func testGroupedProjectsSplitsActiveAndIdle() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")

        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.working),
            "/tmp/c": makeSessionState(.ready),
        ]

        let result = ProjectOrdering.orderedGroupedProjects(
            [projectA, projectB, projectC],
            activeOrder: ["/tmp/c", "/tmp/a"],
            idleOrder: ["/tmp/b"],
            sessionStates: states,
        )

        XCTAssertEqual(result.active.map(\.path), ["/tmp/c", "/tmp/a"])
        XCTAssertEqual(result.idle.map(\.path), ["/tmp/b"])
    }

    func testGroupedProjectsRespectsOrderWithinGroups() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")
        let projectD = makeProject("D", path: "/tmp/d")

        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.working),
            "/tmp/d": makeSessionState(.waiting),
        ]

        let result = ProjectOrdering.orderedGroupedProjects(
            [projectA, projectB, projectC, projectD],
            activeOrder: ["/tmp/d", "/tmp/a"],
            idleOrder: ["/tmp/c", "/tmp/b"],
            sessionStates: states,
        )

        // Active: D before A (per activeOrder)
        XCTAssertEqual(result.active.map(\.path), ["/tmp/d", "/tmp/a"])
        // Idle: C before B (per idleOrder)
        XCTAssertEqual(result.idle.map(\.path), ["/tmp/c", "/tmp/b"])
    }

    func testGroupedProjectsAllIdle() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")

        let result = ProjectOrdering.orderedGroupedProjects(
            [projectA, projectB],
            activeOrder: [],
            idleOrder: ["/tmp/b", "/tmp/a"],
            sessionStates: [:],
        )

        XCTAssertTrue(result.active.isEmpty)
        XCTAssertEqual(result.idle.map(\.path), ["/tmp/b", "/tmp/a"])
    }

    func testGroupedProjectsAllActive() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")

        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.working),
            "/tmp/b": makeSessionState(.ready),
        ]

        let result = ProjectOrdering.orderedGroupedProjects(
            [projectA, projectB],
            activeOrder: ["/tmp/a", "/tmp/b"],
            idleOrder: [],
            sessionStates: states,
        )

        XCTAssertEqual(result.active.map(\.path), ["/tmp/a", "/tmp/b"])
        XCTAssertTrue(result.idle.isEmpty)
    }

    // MARK: - Migration

    func testMigrateIfNeededCopiesLegacyOrderToActive() throws {
        let suiteName = "test-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(["/tmp/a", "/tmp/b", "/tmp/c"], forKey: "customProjectOrder")

        ProjectOrderStore.migrateIfNeeded(from: defaults)

        let activeOrder = defaults.array(forKey: "projectOrder.active") as? [String] ?? []
        let idleOrder = defaults.array(forKey: "projectOrder.idle") as? [String] ?? []
        let migrated = defaults.bool(forKey: "projectOrder.migrated.v2")

        XCTAssertEqual(activeOrder, ["/tmp/a", "/tmp/b", "/tmp/c"])
        XCTAssertEqual(idleOrder, [])
        XCTAssertTrue(migrated)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMigrateIfNeededDoesNotRunTwice() throws {
        let suiteName = "test-migration-idempotent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(["/tmp/a"], forKey: "customProjectOrder")

        ProjectOrderStore.migrateIfNeeded(from: defaults)

        // Change active order after migration
        defaults.set(["/tmp/z"], forKey: "projectOrder.active")

        // Run migration again — should be no-op
        ProjectOrderStore.migrateIfNeeded(from: defaults)

        let activeOrder = defaults.array(forKey: "projectOrder.active") as? [String] ?? []
        XCTAssertEqual(activeOrder, ["/tmp/z"], "Migration should not overwrite after first run")

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMigrateIfNeededHandlesEmptyLegacy() throws {
        let suiteName = "test-migration-empty-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        // No legacy key set

        ProjectOrderStore.migrateIfNeeded(from: defaults)

        let activeOrder = defaults.array(forKey: "projectOrder.active") as? [String]
        let migrated = defaults.bool(forKey: "projectOrder.migrated.v2")

        // No active order set (legacy was empty), but migration flag should be set
        XCTAssertNil(activeOrder)
        XCTAssertTrue(migrated)

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Store load/save

    func testStoreLoadAndSaveDualLists() throws {
        let suiteName = "test-store-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        ProjectOrderStore.saveActive(["/tmp/a", "/tmp/b"], to: defaults)
        ProjectOrderStore.saveIdle(["/tmp/c"], to: defaults)

        XCTAssertEqual(ProjectOrderStore.loadActive(from: defaults), ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(ProjectOrderStore.loadIdle(from: defaults), ["/tmp/c"])

        defaults.removePersistentDomain(forName: suiteName)
    }
}
