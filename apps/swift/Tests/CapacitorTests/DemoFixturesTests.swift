@testable import Capacitor
import XCTest

final class DemoFixturesTests: XCTestCase {
    func testProjectFlowFixtureIsCompleteAndDeterministic() throws {
        let fixture = try XCTUnwrap(try DemoFixtures.fixture(for: "project_flow_v1"))

        XCTAssertGreaterThanOrEqual(fixture.projects.count, 6)

        let projectPaths = fixture.projects.map(\.path)
        XCTAssertEqual(Set(projectPaths).count, fixture.projects.count)
        XCTAssertEqual(Set(fixture.sessionStates.keys), Set(projectPaths))
        XCTAssertEqual(Set(fixture.projectStatuses.keys), Set(projectPaths))
        XCTAssertFalse(fixture.hiddenProjectPaths.isEmpty)
        XCTAssertTrue(fixture.hiddenProjectPaths.isSubset(of: Set(projectPaths)))

        XCTAssertEqual(fixture.featureFlags, FeatureFlags.defaults(for: .alpha))
    }

    func testProjectFlowFixtureProvidesStableDemoIdentifiers() throws {
        let fixture = try XCTUnwrap(try DemoFixtures.fixture(for: "project_flow_v1"))
        let cardIdentifiers = fixture.projects.map(DemoAccessibility.projectCardIdentifier(for:))
        let detailsIdentifiers = fixture.projects.map(DemoAccessibility.projectDetailsIdentifier(for:))

        XCTAssertEqual(Set(cardIdentifiers).count, fixture.projects.count)
        XCTAssertEqual(Set(detailsIdentifiers).count, fixture.projects.count)
        XCTAssertTrue(cardIdentifiers.allSatisfy { $0.hasPrefix("demo.project-card.") })
        XCTAssertTrue(detailsIdentifiers.allSatisfy { $0.hasPrefix("demo.project-details.") })
        XCTAssertEqual(DemoAccessibility.backProjectsIdentifier, "demo.nav.back-projects")
    }

    func testProjectFlowStatesFixtureCoversAllHighSignalSessionStates() throws {
        let fixture = try XCTUnwrap(try DemoFixtures.fixture(for: "project_flow_states_v1"))

        XCTAssertFalse(fixture.stateTimeline.isEmpty)

        let initialStates = fixture.sessionStates.values.map(\.state)
        let timelineStates = fixture.stateTimeline.flatMap { $0.sessionStates.values.map(\.state) }
        let allStates = Set(initialStates + timelineStates)

        XCTAssertTrue(allStates.contains(.ready))
        XCTAssertTrue(allStates.contains(.working))
        XCTAssertTrue(allStates.contains(.waiting))
        XCTAssertTrue(allStates.contains(.compacting))

        let changedPaths = fixture.projects.map(\.path).filter { path in
            let statesForPath = fixture.stateTimeline.compactMap { $0.sessionStates[path]?.state }
            return Set(statesForPath).count > 1
        }

        XCTAssertFalse(changedPaths.isEmpty, "Expected at least one project state transition in timeline")
    }

    func testFixtureCanBeOverriddenFromProjectsFile() throws {
        let fileURL = try writeProjectsOverride(
            #"""
            {
              "projects": [
                {
                  "name": "Main App",
                  "path": "/tmp/demo/main-app",
                  "taskCount": 5,
                  "initialState": "ready"
                },
                {
                  "name": "Agent Runtime",
                  "path": "/tmp/demo/agent-runtime",
                  "taskCount": 7,
                  "hidden": true,
                  "initialState": "working"
                },
                {
                  "name": "Telemetry",
                  "path": "/tmp/demo/telemetry",
                  "taskCount": 2,
                  "initialState": "waiting"
                }
              ],
              "hiddenProjectPaths": ["/tmp/demo/telemetry"]
            }
            """#,
        )

        let fixture = try XCTUnwrap(
            try DemoFixtures.fixture(
                for: "project_flow_v1",
                projectOverrideFilePath: fileURL.path,
            ),
        )

        XCTAssertEqual(fixture.projects.map(\.name), ["Main App", "Agent Runtime", "Telemetry"])
        XCTAssertEqual(fixture.hiddenProjectPaths, ["/tmp/demo/agent-runtime", "/tmp/demo/telemetry"])
        XCTAssertEqual(fixture.sessionStates["/tmp/demo/main-app"]?.state, .ready)
        XCTAssertEqual(fixture.sessionStates["/tmp/demo/agent-runtime"]?.state, .working)
        XCTAssertEqual(fixture.sessionStates["/tmp/demo/telemetry"]?.state, .waiting)
        XCTAssertFalse(fixture.stateTimeline.isEmpty)
    }

    func testFixtureOverrideFailsForUnknownHiddenPath() throws {
        let fileURL = try writeProjectsOverride(
            #"""
            {
              "projects": [
                { "name": "Main App", "path": "/tmp/demo/main-app" }
              ],
              "hiddenProjectPaths": ["/tmp/demo/not-listed"]
            }
            """#,
        )

        XCTAssertThrowsError(
            try DemoFixtures.fixture(
                for: "project_flow_v1",
                projectOverrideFilePath: fileURL.path,
            ),
        )
    }

    func testFixtureOverrideFailsForInvalidInitialState() throws {
        let fileURL = try writeProjectsOverride(
            #"""
            {
              "projects": [
                { "name": "Main App", "path": "/tmp/demo/main-app", "initialState": "broken" }
              ]
            }
            """#,
        )

        XCTAssertThrowsError(
            try DemoFixtures.fixture(
                for: "project_flow_v1",
                projectOverrideFilePath: fileURL.path,
            ),
        )
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
