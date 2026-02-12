import XCTest

final class ProjectCardIdentityRegressionTests: XCTestCase {
    func testProjectsViewActiveCardIdentityDoesNotUseGlobalSessionRevision() throws {
        let source = try loadSourceFile(named: "ProjectsView.swift")

        XCTAssertFalse(
            source.contains(".id(\"\\(project.path)-\\(appState.sessionStateRevision)\")"),
            "Active card identity in ProjectsView should be stable per project path and must not depend on global sessionStateRevision.",
        )
    }

    func testDockLayoutActiveCardIdentityDoesNotUseGlobalSessionRevision() throws {
        let source = try loadSourceFile(named: "DockLayoutView.swift")

        XCTAssertFalse(
            source.contains(".id(\"\\(project.path)-\\(appState.sessionStateRevision)\")"),
            "Active card identity in DockLayoutView should be stable per project path and must not depend on global sessionStateRevision.",
        )
    }

    func testProjectsViewCardIdentityUsesPerCardSessionFingerprint() throws {
        let source = try loadSourceFile(named: "ProjectsView.swift")

        XCTAssertTrue(
            source.contains(".id(ProjectOrdering.cardIdentityKey("),
            "ProjectsView card identity should include a per-card session fingerprint so rows refresh when that project's session state changes.",
        )
    }

    func testDockLayoutCardIdentityUsesPerCardSessionFingerprint() throws {
        let source = try loadSourceFile(named: "DockLayoutView.swift")

        XCTAssertTrue(
            source.contains(".id(ProjectOrdering.cardIdentityKey("),
            "DockLayoutView card identity should include a per-card session fingerprint so rows refresh when that project's session state changes.",
        )
    }

    private func loadSourceFile(named fileName: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/Views/Projects")
            .appendingPathComponent(fileName)

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
