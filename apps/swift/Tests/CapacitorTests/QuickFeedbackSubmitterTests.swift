@testable import Capacitor
import Foundation
import XCTest

final class QuickFeedbackSubmitterTests: XCTestCase {
    func testBuildPayloadRedactsPathsByDefault() {
        let projectPath = "/Users/pete/Code/capacitor"
        let context = makeContext(projectPath: projectPath)

        let payload = QuickFeedbackPayloadBuilder.build(
            message: "App gets stuck after switching projects",
            context: context,
            preferences: QuickFeedbackPreferences(includeTelemetry: true, includeProjectPaths: false),
            now: fixedDate,
        )

        XCTAssertEqual(payload.feedback, "App gets stuck after switching projects")
        XCTAssertEqual(payload.app.channel, "alpha")
        XCTAssertEqual(payload.projectContext.sessionSummary.working, 1)
        XCTAssertEqual(payload.projectContext.sessionSummary.ready, 1)
        XCTAssertEqual(payload.projectContext.sessionSummary.withAttachedSession, 2)

        let activeProject = try? XCTUnwrap(payload.projectContext.activeProjectPath)
        XCTAssertNotNil(activeProject)
        XCTAssertFalse(activeProject?.contains("/Users/") == true)

        XCTAssertTrue(
            payload.projectContext.projects.contains(where: { snapshot in
                snapshot.path.contains("#") && !snapshot.path.contains("/Users/")
            }),
        )
        XCTAssertTrue(payload.activationSignal.hasTrace)
        XCTAssertNotNil(payload.activationSignal.traceDigest)
    }

    func testBuildPayloadIncludesProjectPathsWhenOptedIn() throws {
        let projectPath = "/Users/pete/Code/capacitor"
        let context = makeContext(projectPath: projectPath)

        let payload = QuickFeedbackPayloadBuilder.build(
            message: "Need richer daemon diagnostics",
            context: context,
            preferences: QuickFeedbackPreferences(includeTelemetry: true, includeProjectPaths: true),
            now: fixedDate,
        )

        XCTAssertEqual(payload.projectContext.activeProjectPath, projectPath)
        let tracked = try XCTUnwrap(payload.projectContext.projects.first(where: { $0.path == projectPath }))
        XCTAssertEqual(tracked.path, projectPath)
        XCTAssertEqual(payload.privacy.includeProjectPaths, true)
    }

    func testSubmitSendsEndpointPayloadAndOpensGitHubIssue() async throws {
        var capturedRequest: URLRequest?
        var openedURL: URL?

        let submitter = QuickFeedbackSubmitter(
            environment: [
                "CAPACITOR_FEEDBACK_API_URL": "https://feedback.example.com/intake",
            ],
            openURL: { url in
                openedURL = url
                return true
            },
            sendRequest: { request in
                capturedRequest = request
            },
            now: { self.fixedDate },
        )

        let outcome = await submitter.submit(
            message: "Daemon stuck in ready",
            context: makeContext(projectPath: "/Users/pete/Code/capacitor"),
            preferences: QuickFeedbackPreferences(includeTelemetry: true, includeProjectPaths: false),
        )

        XCTAssertTrue(outcome.endpointAttempted)
        XCTAssertTrue(outcome.endpointSucceeded)
        XCTAssertTrue(outcome.issueOpened)
        XCTAssertNil(outcome.endpointError)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://feedback.example.com/intake")
        XCTAssertEqual(request.httpMethod, "POST")

        let bodyData = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(json["feedback"] as? String, "Daemon stuck in ready")

        let issueURL = try XCTUnwrap(openedURL)
        XCTAssertEqual(issueURL.host, "github.com")
        let queryItems = URLComponents(url: issueURL, resolvingAgainstBaseURL: false)?.queryItems
        let body = queryItems?.first(where: { $0.name == "body" })?.value
        XCTAssertNotNil(body)
        XCTAssertTrue(body?.contains("Telemetry Context") == true)
    }

    func testSubmitSkipsEndpointWhenTelemetryDisabled() async throws {
        var sentRequest = false
        var openedURL: URL?

        let submitter = QuickFeedbackSubmitter(
            environment: [
                "CAPACITOR_FEEDBACK_API_URL": "https://feedback.example.com/intake",
            ],
            openURL: { url in
                openedURL = url
                return true
            },
            sendRequest: { _ in
                sentRequest = true
            },
            now: { self.fixedDate },
        )

        let outcome = await submitter.submit(
            message: "UI spacing is off",
            context: makeContext(projectPath: "/Users/pete/Code/capacitor"),
            preferences: QuickFeedbackPreferences(includeTelemetry: false, includeProjectPaths: false),
        )

        XCTAssertFalse(sentRequest)
        XCTAssertFalse(outcome.endpointAttempted)
        XCTAssertTrue(outcome.issueOpened)

        let issueURL = try XCTUnwrap(openedURL)
        let queryItems = URLComponents(url: issueURL, resolvingAgainstBaseURL: false)?.queryItems
        let body = queryItems?.first(where: { $0.name == "body" })?.value
        XCTAssertNotNil(body)
        XCTAssertTrue(body?.contains("Telemetry sharing is disabled") == true)
    }

    private func makeContext(projectPath: String) -> QuickFeedbackContext {
        let otherPath = "/Users/pete/Code/website"
        return QuickFeedbackContext(
            appVersion: "0.2.0-alpha.1",
            buildNumber: "42",
            channel: .alpha,
            osVersion: "macOS 14.6",
            daemonStatus: DaemonStatus(
                isEnabled: true,
                isHealthy: true,
                message: "ok",
                pid: 4172,
                version: "0.2.0",
            ),
            activeProjectPath: projectPath,
            activeSource: "claude(session-123)",
            projectCount: 2,
            sessionStates: [
                projectPath: ProjectSessionState(
                    state: .working,
                    stateChangedAt: "2026-02-13T12:00:00Z",
                    updatedAt: "2026-02-13T12:00:00Z",
                    sessionId: "session-123",
                    workingOn: nil,
                    context: nil,
                    thinking: true,
                    hasSession: true,
                ),
                otherPath: ProjectSessionState(
                    state: .ready,
                    stateChangedAt: "2026-02-13T11:58:00Z",
                    updatedAt: "2026-02-13T11:58:00Z",
                    sessionId: "session-456",
                    workingOn: nil,
                    context: nil,
                    thinking: nil,
                    hasSession: true,
                ),
            ],
            activationTrace: "Ghostty activation succeeded for /Users/pete/Code/capacitor",
        )
    }

    private var fixedDate: Date {
        Date(timeIntervalSince1970: 1_708_000_000)
    }
}
