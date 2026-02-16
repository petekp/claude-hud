import XCTest

final class FooterControlsRegressionTests: XCTestCase {
    func testAddProjectButtonUsesFolderBrowsingIconAndTooltip() throws {
        let source = try loadFooterViewSource()

        XCTAssertTrue(
            source.contains("Image(systemName: \"folder.badge.plus\")"),
            "Footer add-project button should use a folder browsing icon.",
        )
        XCTAssertTrue(
            source.contains(".help(\"Connect a project\")"),
            "Footer add-project button should clearly explain that it opens folder browsing.",
        )
    }

    func testPinButtonTooltipExplainsAlwaysOnTopToggle() throws {
        let source = try loadFooterViewSource()

        XCTAssertTrue(
            source.contains("Unpin from top (⌘⇧P)"),
            "Pin tooltip should clearly communicate the unpin action.",
        )
        XCTAssertTrue(
            source.contains("Pin to top (⌘⇧P)"),
            "Pin tooltip should clearly communicate the pin action.",
        )
    }

    private func loadFooterViewSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/Views/Footer/FooterView.swift")

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
