import XCTest

final class DemoAccessibilityMarkersRegressionTests: XCTestCase {
    func testProjectCardViewIncludesStableDemoCardIdentifier() throws {
        let source = try loadSourceFile(
            directory: "Views/Projects",
            fileName: "ProjectCardView.swift",
        )

        XCTAssertTrue(
            source.contains("DemoAccessibility.projectCardIdentifier(for: project)"),
            "ProjectCardView should expose stable demo card accessibility identifiers.",
        )
    }

    func testDockProjectCardIncludesStableDemoCardIdentifier() throws {
        let source = try loadSourceFile(
            directory: "Views/Projects",
            fileName: "DockProjectCard.swift",
        )

        XCTAssertTrue(
            source.contains("DemoAccessibility.projectCardIdentifier(for: project)"),
            "DockProjectCard should expose stable demo card accessibility identifiers.",
        )
    }

    func testProjectCardComponentsIncludesStableDemoDetailsIdentifierHook() throws {
        let source = try loadSourceFile(
            directory: "Views/Projects",
            fileName: "ProjectCardComponents.swift",
        )

        XCTAssertTrue(
            source.contains("accessibilityIdentifier"),
            "ProjectCardComponents should expose a deterministic accessibility identifier seam for details navigation.",
        )
    }

    func testProjectDetailViewIncludesStableDemoNavigationIdentifiers() throws {
        let source = try loadSourceFile(
            directory: "Views/Projects",
            fileName: "ProjectDetailView.swift",
        )

        XCTAssertTrue(
            source.contains("DemoAccessibility.projectDetailsIdentifier(for: project)"),
            "ProjectDetailView should expose stable details container identifiers.",
        )
        XCTAssertTrue(
            source.contains("DemoAccessibility.backProjectsIdentifier"),
            "ProjectDetailView should expose a stable back-navigation identifier.",
        )
    }

    private func loadSourceFile(directory: String, fileName: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor")
            .appendingPathComponent(directory)
            .appendingPathComponent(fileName)

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
