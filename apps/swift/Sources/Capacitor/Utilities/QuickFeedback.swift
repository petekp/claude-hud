import CryptoKit
import Foundation

enum QuickFeedbackPreferenceKeys {
    static let includeTelemetry = "quickFeedback.includeTelemetry"
    static let includeProjectPaths = "quickFeedback.includeProjectPaths"
}

struct QuickFeedbackPreferences: Equatable {
    var includeTelemetry: Bool
    var includeProjectPaths: Bool

    static let defaults = QuickFeedbackPreferences(
        includeTelemetry: true,
        includeProjectPaths: false,
    )

    static func load(from defaultsStore: UserDefaults = .standard) -> QuickFeedbackPreferences {
        let includeTelemetry = value(
            forKey: QuickFeedbackPreferenceKeys.includeTelemetry,
            defaultValue: defaults.includeTelemetry,
            store: defaultsStore,
        )
        let includeProjectPaths = value(
            forKey: QuickFeedbackPreferenceKeys.includeProjectPaths,
            defaultValue: defaults.includeProjectPaths,
            store: defaultsStore,
        )

        if !includeTelemetry {
            return QuickFeedbackPreferences(includeTelemetry: false, includeProjectPaths: false)
        }

        return QuickFeedbackPreferences(
            includeTelemetry: includeTelemetry,
            includeProjectPaths: includeProjectPaths,
        )
    }

    private static func value(forKey key: String, defaultValue: Bool, store: UserDefaults) -> Bool {
        guard store.object(forKey: key) != nil else {
            return defaultValue
        }
        return store.bool(forKey: key)
    }
}

struct QuickFeedbackContext: Equatable {
    let appVersion: String
    let buildNumber: String
    let channel: AppChannel
    let osVersion: String
    let daemonStatus: DaemonStatus?
    let activeProjectPath: String?
    let activeSource: String
    let projectCount: Int
    let sessionStates: [String: ProjectSessionState]
    let activationTrace: String?
}

struct QuickFeedbackPayload: Codable, Equatable {
    struct AppSnapshot: Codable, Equatable {
        let version: String
        let buildNumber: String
        let channel: String
        let osVersion: String
    }

    struct PrivacySnapshot: Codable, Equatable {
        let includeTelemetry: Bool
        let includeProjectPaths: Bool
    }

    struct DaemonSnapshot: Codable, Equatable {
        let enabled: Bool
        let healthy: Bool
        let message: String
        let pid: Int?
        let version: String?
    }

    struct SessionSummary: Codable, Equatable {
        let total: Int
        let working: Int
        let ready: Int
        let waiting: Int
        let compacting: Int
        let idle: Int
        let withAttachedSession: Int
        let thinking: Int
    }

    struct ProjectSessionSnapshot: Codable, Equatable {
        let path: String
        let state: String
        let hasSession: Bool
        let thinking: Bool
        let sessionIdPresent: Bool
        let updatedAt: String?
    }

    struct ProjectContext: Codable, Equatable {
        let activeProjectPath: String?
        let activeSource: String
        let projectCount: Int
        let sessionSummary: SessionSummary
        let projects: [ProjectSessionSnapshot]
        let omittedProjectCount: Int
    }

    struct ActivationSignal: Codable, Equatable {
        let hasTrace: Bool
        let traceDigest: String?
    }

    let feedback: String
    let submittedAt: String
    let app: AppSnapshot
    let privacy: PrivacySnapshot
    let daemon: DaemonSnapshot?
    let projectContext: ProjectContext
    let activationSignal: ActivationSignal
}

enum QuickFeedbackPayloadBuilder {
    private enum Constants {
        static let maxProjectSnapshots = 12
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func build(
        message: String,
        context: QuickFeedbackContext,
        preferences: QuickFeedbackPreferences,
        now: Date = Date(),
    ) -> QuickFeedbackPayload {
        let sortedStates = context.sessionStates.sorted { $0.key < $1.key }

        var working = 0
        var ready = 0
        var waiting = 0
        var compacting = 0
        var idle = 0
        var withAttachedSession = 0
        var thinking = 0

        for (_, sessionState) in sortedStates {
            switch sessionState.state {
            case .working:
                working += 1
            case .ready:
                ready += 1
            case .waiting:
                waiting += 1
            case .compacting:
                compacting += 1
            case .idle:
                idle += 1
            }

            if sessionState.hasSession {
                withAttachedSession += 1
            }
            if sessionState.thinking == true {
                thinking += 1
            }
        }

        let projectSnapshots = sortedStates.prefix(Constants.maxProjectSnapshots).map { path, sessionState in
            QuickFeedbackPayload.ProjectSessionSnapshot(
                path: sanitizedPath(path, preferences: preferences),
                state: stateLabel(sessionState.state),
                hasSession: sessionState.hasSession,
                thinking: sessionState.thinking == true,
                sessionIdPresent: sessionState.sessionId != nil,
                updatedAt: sessionState.updatedAt,
            )
        }

        let daemon = context.daemonStatus.map {
            QuickFeedbackPayload.DaemonSnapshot(
                enabled: $0.isEnabled,
                healthy: $0.isHealthy,
                message: $0.message,
                pid: $0.pid,
                version: $0.version,
            )
        }

        let trace = context.activationTrace?.trimmingCharacters(in: .whitespacesAndNewlines)

        return QuickFeedbackPayload(
            feedback: message,
            submittedAt: timestampFormatter.string(from: now),
            app: QuickFeedbackPayload.AppSnapshot(
                version: context.appVersion,
                buildNumber: context.buildNumber,
                channel: context.channel.rawValue,
                osVersion: context.osVersion,
            ),
            privacy: QuickFeedbackPayload.PrivacySnapshot(
                includeTelemetry: preferences.includeTelemetry,
                includeProjectPaths: preferences.includeProjectPaths,
            ),
            daemon: daemon,
            projectContext: QuickFeedbackPayload.ProjectContext(
                activeProjectPath: context.activeProjectPath.map { sanitizedPath($0, preferences: preferences) },
                activeSource: context.activeSource,
                projectCount: context.projectCount,
                sessionSummary: QuickFeedbackPayload.SessionSummary(
                    total: sortedStates.count,
                    working: working,
                    ready: ready,
                    waiting: waiting,
                    compacting: compacting,
                    idle: idle,
                    withAttachedSession: withAttachedSession,
                    thinking: thinking,
                ),
                projects: Array(projectSnapshots),
                omittedProjectCount: max(0, sortedStates.count - projectSnapshots.count),
            ),
            activationSignal: QuickFeedbackPayload.ActivationSignal(
                hasTrace: !(trace?.isEmpty ?? true),
                traceDigest: trace.flatMap(digestHex),
            ),
        )
    }

    private static func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .working:
            "working"
        case .ready:
            "ready"
        case .idle:
            "idle"
        case .compacting:
            "compacting"
        case .waiting:
            "waiting"
        }
    }

    private static func sanitizedPath(_ path: String, preferences: QuickFeedbackPreferences) -> String {
        guard !preferences.includeProjectPaths else {
            return path
        }
        return "project#\(digestHex(path).prefix(12))"
    }

    private static func digestHex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct QuickFeedbackSubmissionOutcome: Equatable {
    let issueURL: URL
    let issueOpened: Bool
    let endpointAttempted: Bool
    let endpointSucceeded: Bool
    let endpointError: String?
}

struct QuickFeedbackSubmitter {
    typealias OpenURLAction = (URL) -> Bool
    typealias RequestSender = (URLRequest) async throws -> Void

    private let environment: [String: String]
    private let openURL: OpenURLAction
    private let sendRequest: RequestSender
    private let now: () -> Date
    private let repository: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        openURL: @escaping OpenURLAction,
        sendRequest: @escaping RequestSender,
        now: @escaping () -> Date = Date.init,
        repository: String = QuickFeedbackIssueComposer.defaultRepository,
    ) {
        self.environment = environment
        self.openURL = openURL
        self.sendRequest = sendRequest
        self.now = now
        self.repository = repository
    }

    func submit(
        message: String,
        context: QuickFeedbackContext,
        preferences: QuickFeedbackPreferences,
    ) async -> QuickFeedbackSubmissionOutcome {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = QuickFeedbackPayloadBuilder.build(
            message: trimmed,
            context: context,
            preferences: preferences,
            now: now(),
        )

        var endpointAttempted = false
        var endpointSucceeded = false
        var endpointError: String?

        if preferences.includeTelemetry,
           let endpointURL = endpointURL()
        {
            endpointAttempted = true
            do {
                let request = try endpointRequest(endpointURL: endpointURL, payload: payload)
                try await sendRequest(request)
                endpointSucceeded = true
            } catch {
                endpointError = String(describing: error)
            }
        }

        let issueURL = QuickFeedbackIssueComposer.issueURL(payload: payload, repository: repository)
        let issueOpened = openURL(issueURL)

        return QuickFeedbackSubmissionOutcome(
            issueURL: issueURL,
            issueOpened: issueOpened,
            endpointAttempted: endpointAttempted,
            endpointSucceeded: endpointSucceeded,
            endpointError: endpointError,
        )
    }

    private func endpointURL() -> URL? {
        guard let raw = environment["CAPACITOR_FEEDBACK_API_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        return URL(string: raw)
    }

    private func endpointRequest(endpointURL: URL, payload: QuickFeedbackPayload) throws -> URLRequest {
        let data = try JSONEncoder().encode(payload)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}

enum QuickFeedbackIssueComposer {
    static let defaultRepository = "petekp/capacitor"

    static func issueURL(payload: QuickFeedbackPayload, repository: String = defaultRepository) -> URL {
        let repositoryPath = normalizedRepositoryPath(repository)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repositoryPath)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: issueTitle(for: payload.feedback)),
            URLQueryItem(name: "labels", value: "alpha-feedback"),
            URLQueryItem(name: "body", value: issueBody(for: payload)),
        ]

        return components.url
            ?? URL(string: "https://github.com/\(defaultRepository)/issues/new")
            ?? URL(fileURLWithPath: "/")
    }

    private static func issueTitle(for feedback: String) -> String {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Alpha feedback"
        }
        let snippet = String(trimmed.prefix(70))
        return "Alpha feedback: \(snippet)"
    }

    private static func issueBody(for payload: QuickFeedbackPayload) -> String {
        var sections: [String] = [
            "## Feedback",
            payload.feedback,
            "",
            "## Privacy",
            "- Include technical telemetry: \(payload.privacy.includeTelemetry ? "yes" : "no")",
            "- Include project paths: \(payload.privacy.includeProjectPaths ? "yes" : "no")",
            "",
        ]

        if payload.privacy.includeTelemetry {
            sections.append(contentsOf: [
                "## Telemetry Context",
                "```json",
                payloadJSONString(payload),
                "```",
            ])
        } else {
            sections.append("Telemetry sharing is disabled for this report.")
        }

        return sections.joined(separator: "\n")
    }

    private static func payloadJSONString(_ payload: QuickFeedbackPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func normalizedRepositoryPath(_ repository: String) -> String {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return defaultRepository
        }
        return "\(parts[0])/\(parts[1])"
    }
}
