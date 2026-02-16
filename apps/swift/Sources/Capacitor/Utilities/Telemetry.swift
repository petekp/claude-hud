import Foundation
import os.log

/// Lightweight telemetry emitter for local debug or remote ingest endpoints.
enum Telemetry {
    private static let logger = Logger(subsystem: "com.capacitor.app", category: "Telemetry")
    private static let formatter = ISO8601DateFormatter()
    private struct Config {
        let endpoint: URL?
        let redactPaths: Bool
        let ingestKey: String?
    }

    private static let config: Config = {
        let env = ProcessInfo.processInfo.environment
        if env["CAPACITOR_TELEMETRY_DISABLED"] == "1" {
            return Config(endpoint: nil, redactPaths: false, ingestKey: nil)
        }
        let rawURL = env["CAPACITOR_TELEMETRY_URL"] ?? "http://localhost:9133/telemetry"
        let endpoint = URL(string: rawURL)
        let ingestKey = env["CAPACITOR_INGEST_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIngestKey = ingestKey?.isEmpty == true ? nil : ingestKey
        let redactPaths = endpoint.map { TelemetryRedaction.shouldRedactPaths(environment: env, endpoint: $0) } ?? false
        return Config(endpoint: endpoint, redactPaths: redactPaths, ingestKey: normalizedIngestKey)
    }()

    static func emit(_ type: String, _ message: String, payload: [String: Any] = [:]) {
        guard let url = config.endpoint else { return }
        let sanitizedMessage = config.redactPaths ? TelemetryRedaction.redactMessage(message) : message
        let sanitizedPayload = config.redactPaths ? TelemetryRedaction.redactPayload(payload) : payload

        var body: [String: Any] = [
            "type": type,
            "message": sanitizedMessage,
            "timestamp": formatter.string(from: Date()),
        ]
        if !sanitizedPayload.isEmpty {
            body["payload"] = sanitizedPayload
        }
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [])
        else {
            logger.debug("Telemetry payload not JSON encodable for type=\(type, privacy: .public)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ingestKey = config.ingestKey {
            request.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
