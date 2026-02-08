import Foundation
import os.log

/// Lightweight telemetry emitter for the local transparent UI hub.
enum Telemetry {
    private static let logger = Logger(subsystem: "com.capacitor.app", category: "Telemetry")
    private static let formatter = ISO8601DateFormatter()

    private static let endpoint: URL? = {
        let env = ProcessInfo.processInfo.environment
        if env["CAPACITOR_TELEMETRY_DISABLED"] == "1" {
            return nil
        }
        let raw = env["CAPACITOR_TELEMETRY_URL"] ?? "http://localhost:9133/telemetry"
        return URL(string: raw)
    }()

    static func emit(_ type: String, _ message: String, payload: [String: Any] = [:]) {
        guard let url = endpoint else { return }
        var body: [String: Any] = [
            "type": type,
            "message": message,
            "timestamp": formatter.string(from: Date()),
        ]
        if !payload.isEmpty {
            body["payload"] = payload
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
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
