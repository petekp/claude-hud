import XCTest

final class AppStateDaemonStartupRegressionTests: XCTestCase {
    func testEnsureDaemonRunningGuardsAgainstDuplicateInFlightStartupAttempts() throws {
        let source = try loadAppStateSource()

        XCTAssertTrue(
            source.contains("private var daemonStartupTask: _Concurrency.Task<Void, Never>?"),
            "AppState should track a daemon startup task so repeated health failures do not overlap startup attempts.",
        )
        XCTAssertTrue(
            source.contains("guard daemonStartupTask == nil else {"),
            "ensureDaemonRunning should no-op while a startup attempt is already in flight.",
        )
        XCTAssertTrue(
            source.contains("daemonStartupTask = _Concurrency.Task { @MainActor [weak self] in"),
            "ensureDaemonRunning should register and own the startup task lifecycle on the main actor.",
        )
    }

    func testRuntimeBootstrapAvoidsImmediateRedundantHealthCheckAfterStartupKickoff() throws {
        let source = try loadAppStateSource()

        XCTAssertFalse(
            source.contains(
                """
                loadDashboard()
                                checkHookDiagnostic()
                                checkDaemonHealth()
                                setupStalenessTimer()
                """,
            ),
            "scheduleRuntimeBootstrap should not fire an immediate extra health check while ensureDaemonRunning already performs a post-start check.",
        )
    }

    private func loadAppStateSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/Models/AppState.swift")

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
