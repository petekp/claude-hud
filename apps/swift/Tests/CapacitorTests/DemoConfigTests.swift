@testable import Capacitor
import XCTest

final class DemoConfigTests: XCTestCase {
    func testDemoModeDefaultsToDisabled() {
        let config = DemoConfig.resolve(environment: [:])

        XCTAssertFalse(config.isEnabled)
        XCTAssertNil(config.scenario)
        XCTAssertFalse(config.disableSideEffects)
        XCTAssertNil(config.projectsFilePath)
    }

    func testDemoModeDefaultsDisableSideEffectsWhenEnabled() {
        let config = DemoConfig.resolve(environment: [
            "CAPACITOR_DEMO_MODE": "1",
        ])

        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.scenario, "project_flow_v1")
        XCTAssertTrue(config.disableSideEffects)
        XCTAssertNil(config.projectsFilePath)
    }

    func testDisableSideEffectsRespectsExplicitFalseValue() {
        let config = DemoConfig.resolve(environment: [
            "CAPACITOR_DEMO_MODE": "1",
            "CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS": "0",
        ])

        XCTAssertTrue(config.isEnabled)
        XCTAssertFalse(config.disableSideEffects)
        XCTAssertNil(config.projectsFilePath)
    }

    func testScenarioSelectionUsesEnvironmentValue() {
        let config = DemoConfig.resolve(environment: [
            "CAPACITOR_DEMO_MODE": "true",
            "CAPACITOR_DEMO_SCENARIO": "project_flow_v1",
        ])

        XCTAssertEqual(config.scenario, "project_flow_v1")
    }

    func testProjectsFilePathUsesEnvironmentValue() {
        let config = DemoConfig.resolve(environment: [
            "CAPACITOR_DEMO_PROJECTS_FILE": " /tmp/demo-projects.json ",
        ])

        XCTAssertEqual(config.projectsFilePath, "/tmp/demo-projects.json")
    }
}
