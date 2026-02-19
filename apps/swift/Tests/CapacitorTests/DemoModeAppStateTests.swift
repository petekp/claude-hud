@testable import Capacitor
import XCTest

@MainActor
final class DemoModeAppStateTests: XCTestCase {
    override func tearDown() {
        unsetenv("CAPACITOR_DEMO_MODE")
        unsetenv("CAPACITOR_DEMO_SCENARIO")
        unsetenv("CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS")
        unsetenv("CAPACITOR_DEMO_PROJECTS_FILE")
        super.tearDown()
    }

    func testDemoModeBypassesRuntimeSideEffectsAndLoadsFixtureState() throws {
        setenv("CAPACITOR_DEMO_MODE", "1", 1)
        setenv("CAPACITOR_DEMO_SCENARIO", "project_flow_v1", 1)
        setenv("CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS", "1", 1)

        let fixture = try XCTUnwrap(try DemoFixtures.fixture(for: "project_flow_v1"))
        let appState = AppState()

        XCTAssertTrue(appState.demoConfigForTesting.isEnabled)
        XCTAssertTrue(appState.isDemoModeEnabled)
        XCTAssertEqual(appState.channel, .alpha)
        XCTAssertEqual(appState.layoutMode, .vertical)
        XCTAssertEqual(appState.projects, fixture.projects)
        XCTAssertEqual(appState.manuallyDormant, fixture.hiddenProjectPaths)
        XCTAssertEqual(appState.projectStatuses, fixture.projectStatuses)
        XCTAssertFalse(appState.isLoading)
        XCTAssertFalse(appState.isQuickFeedbackEnabled)

        XCTAssertFalse(appState.didAttemptDaemonStartupForTesting)
        XCTAssertFalse(appState.didStartStalenessTimerForTesting)
        XCTAssertFalse(appState.didStartShellTrackingForTesting)
        XCTAssertFalse(appState.didScheduleRuntimeBootstrapForTesting)
        XCTAssertTrue(appState.didStartDemoStateTimelineForTesting)
        XCTAssertEqual(appState.appliedDemoStateTimelineFramesForTesting, 0)
    }

    func testLaunchTerminalInDemoModeSkipsTerminalAutomationAndEmitsDeterministicToast() throws {
        setenv("CAPACITOR_DEMO_MODE", "1", 1)
        setenv("CAPACITOR_DEMO_SCENARIO", "project_flow_v1", 1)

        let fixture = try XCTUnwrap(try DemoFixtures.fixture(for: "project_flow_v1"))
        let project = try XCTUnwrap(fixture.projects.first)
        let appState = AppState()

        appState.launchTerminal(for: project)

        XCTAssertEqual(appState.activeProjectPath, project.path)
        XCTAssertEqual(appState.toast?.message, "Demo mode: Simulated activation for \(project.name)")
        XCTAssertEqual(appState.toast?.isError, false)
    }

    func testQuickFeedbackRemainsEnabledWhenDemoModeIsOff() {
        let appState = AppState()

        XCTAssertFalse(appState.isDemoModeEnabled)
        XCTAssertTrue(appState.isQuickFeedbackEnabled)
    }

    func testDemoModeLoadsProjectsFromOverrideFile() throws {
        setenv("CAPACITOR_DEMO_MODE", "1", 1)
        setenv("CAPACITOR_DEMO_SCENARIO", "project_flow_v1", 1)
        setenv("CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS", "1", 1)

        let projectsFileURL = try writeProjectsOverride(
            #"""
            {
              "projects": [
                { "name": "Capacitor", "path": "/tmp/demo/capacitor", "initialState": "working" },
                { "name": "Docs", "path": "/tmp/demo/docs", "initialState": "ready", "hidden": true },
                { "name": "Telemetry", "path": "/tmp/demo/telemetry", "initialState": "waiting" }
              ]
            }
            """#,
        )
        setenv("CAPACITOR_DEMO_PROJECTS_FILE", projectsFileURL.path, 1)

        let appState = AppState()

        XCTAssertEqual(appState.projects.map(\.path), ["/tmp/demo/capacitor", "/tmp/demo/docs", "/tmp/demo/telemetry"])
        XCTAssertEqual(appState.manuallyDormant, Set(["/tmp/demo/docs"]))
        XCTAssertEqual(appState.projectStatuses["/tmp/demo/capacitor"]?.status, "working")
        XCTAssertEqual(appState.projectStatuses["/tmp/demo/docs"]?.status, "ready")
        XCTAssertEqual(appState.projectStatuses["/tmp/demo/telemetry"]?.status, "waiting")
    }

    private func writeProjectsOverride(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let data = try XCTUnwrap(json.data(using: .utf8))
        try data.write(to: url)
        return url
    }
}
