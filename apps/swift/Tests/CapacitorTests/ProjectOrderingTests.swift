@testable import Capacitor
import XCTest

final class ProjectOrderingTests: XCTestCase {
    func testOrderedProjectsRespectsCustomOrderAndKeepsRemaining() {
        let projectA = Project(
            name: "A",
            path: "/tmp/a",
            displayPath: "/tmp/a",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false
        )
        let projectB = Project(
            name: "B",
            path: "/tmp/b",
            displayPath: "/tmp/b",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false
        )
        let projectC = Project(
            name: "C",
            path: "/tmp/c",
            displayPath: "/tmp/c",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false
        )

        let ordered = ProjectOrdering.orderedProjects(
            [projectA, projectB, projectC],
            customOrder: ["/tmp/c", "/tmp/a"]
        )

        XCTAssertEqual(ordered.map(\.path), ["/tmp/c", "/tmp/a", "/tmp/b"])
    }

    func testMovedOrderOnlyUsesProvidedList() {
        let projectA = Project(
            name: "A",
            path: "/tmp/a",
            displayPath: "/tmp/a",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false
        )
        let projectB = Project(
            name: "B",
            path: "/tmp/b",
            displayPath: "/tmp/b",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false
        )
        let projectC = Project(
            name: "C",
            path: "/tmp/c",
            displayPath: "/tmp/c",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false
        )

        let moved = ProjectOrdering.movedOrder(
            from: IndexSet(integer: 2),
            to: 0,
            in: [projectA, projectB, projectC]
        )

        XCTAssertEqual(moved, ["/tmp/c", "/tmp/a", "/tmp/b"])
    }
}
