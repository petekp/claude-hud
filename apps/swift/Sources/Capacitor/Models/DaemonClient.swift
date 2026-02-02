import Darwin
import Foundation
import Network

struct DaemonHealth: Decodable {
    let status: String
    let pid: Int
    let version: String
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case status, pid, version
        case protocolVersion = "protocol_version"
    }
}

struct DaemonSession: Decodable {
    let sessionId: String
    let pid: UInt32
    let state: String
    let cwd: String
    let projectPath: String
    let updatedAt: String
    let stateChangedAt: String
    let lastEvent: String?
    /// Whether the session's process is still alive.
    /// nil if pid is 0 (unknown), true if alive, false if dead.
    let isAlive: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case pid
        case state
        case cwd
        case projectPath = "project_path"
        case updatedAt = "updated_at"
        case stateChangedAt = "state_changed_at"
        case lastEvent = "last_event"
        case isAlive = "is_alive"
    }
}

struct DaemonProjectState: Decodable {
    let projectPath: String
    let state: String
    let updatedAt: String
    let stateChangedAt: String
    let sessionId: String?
    let sessionCount: Int
    let activeCount: Int
    let isLocked: Bool

    enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case state
        case updatedAt = "updated_at"
        case stateChangedAt = "state_changed_at"
        case sessionId = "session_id"
        case sessionCount = "session_count"
        case activeCount = "active_count"
        case isLocked = "is_locked"
    }
}

struct DaemonErrorInfo: Decodable {
    let code: String
    let message: String
}

struct DaemonResponse<Payload: Decodable>: Decodable {
    let ok: Bool
    let id: String?
    let data: Payload?
    let error: DaemonErrorInfo?
}

struct DaemonRequest<Params: Encodable>: Encodable {
    let protocolVersion: Int
    let method: String
    let id: String?
    let params: Params?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case method, id, params
    }
}

enum DaemonClientError: Error {
    case disabled
    case invalidResponse
    case timeout
    case daemonUnavailable(String)
}

final class DaemonClient {
    static let shared = DaemonClient()

    private enum Constants {
        static let socketName = "daemon.sock"
        static let enabledEnv = "CAPACITOR_DAEMON_ENABLED"
        static let socketEnv = "CAPACITOR_DAEMON_SOCKET"
        static let protocolVersion = 1
        static let maxResponseBytes = 1_048_576
        static let timeoutSeconds: TimeInterval = 0.6
    }

    private let queue = DispatchQueue(label: "com.capacitor.daemon.client")

    private init() {}

    var isEnabled: Bool {
        guard let raw = getenv(Constants.enabledEnv) else {
            return false
        }
        let value = String(cString: raw)
        return ["1", "true", "TRUE", "yes", "YES"].contains(value)
    }

    func fetchHealth() async throws -> DaemonHealth {
        try await performRequest(method: "get_health", params: Optional<String>.none)
    }

    func fetchShellState() async throws -> ShellCwdState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            if let date = Self.parseDaemonDate(dateStr) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateStr)")
        }

        return try await performRequest(
            method: "get_shell_state",
            params: Optional<String>.none,
            decoder: decoder
        )
    }

    func fetchSessions() async throws -> [DaemonSession] {
        DebugLog.write("DaemonClient.fetchSessions start enabled=\(isEnabled)")
        return try await performRequest(method: "get_sessions", params: Optional<String>.none)
    }

    func fetchProjectStates() async throws -> [DaemonProjectState] {
        DebugLog.write("DaemonClient.fetchProjectStates start enabled=\(isEnabled)")
        return try await performRequest(method: "get_project_states", params: Optional<String>.none)
    }

    private func performRequest<Params: Encodable, Payload: Decodable>(
        method: String,
        params: Params?,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Payload {
        guard isEnabled else {
            DebugLog.write("DaemonClient.performRequest disabled method=\(method)")
            throw DaemonClientError.disabled
        }

        let request = DaemonRequest(
            protocolVersion: Constants.protocolVersion,
            method: method,
            id: UUID().uuidString,
            params: params
        )

        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request) + Data([0x0A])
        DebugLog.write("DaemonClient.performRequest send method=\(method) bytes=\(requestData.count)")
        let responseData = try await sendAndReceive(requestData)

        let response = try decoder.decode(DaemonResponse<Payload>.self, from: responseData)
        DebugLog.write("DaemonClient.performRequest recv method=\(method) ok=\(response.ok) hasData=\(response.data != nil)")

        if response.ok, let data = response.data {
            return data
        }

        let message = response.error?.message ?? "Unknown daemon error"
        DebugLog.write("DaemonClient.performRequest error method=\(method) message=\(message)")
        throw DaemonClientError.daemonUnavailable(message)
    }

    private func socketPath() throws -> String {
        if let override = getenv(Constants.socketEnv) {
            return String(cString: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".capacitor/\(Constants.socketName)")
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let microFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return formatter
    }()

    private static func parseDaemonDate(_ dateStr: String) -> Date? {
        if let date = isoWithFractional.date(from: dateStr) {
            return date
        }
        if let date = isoNoFractional.date(from: dateStr) {
            return date
        }
        if let normalized = normalizeFractional(dateStr),
           let date = microFormatter.date(from: normalized) {
            return date
        }
        return nil
    }

    private static func normalizeFractional(_ dateStr: String) -> String? {
        guard let dotIndex = dateStr.firstIndex(of: ".") else { return nil }
        var idx = dateStr.index(after: dotIndex)
        var fraction = ""
        while idx < dateStr.endIndex {
            let ch = dateStr[idx]
            if ch >= "0" && ch <= "9" {
                fraction.append(ch)
                idx = dateStr.index(after: idx)
            } else {
                break
            }
        }
        guard !fraction.isEmpty else { return nil }
        let tz = String(dateStr[idx...])
        let prefix = String(dateStr[..<dotIndex])
        let padded = fraction.count >= 6
            ? String(fraction.prefix(6))
            : fraction.padding(toLength: 6, withPad: "0", startingAt: 0)
        return "\(prefix).\(padded)\(tz)"
    }

    private func sendAndReceive(_ requestData: Data) async throws -> Data {
        let path = try socketPath()
        let endpoint = NWEndpoint.unix(path: path)
        let connection = NWConnection(to: endpoint, using: .tcp)
        DebugLog.write("DaemonClient.sendAndReceive connect path=\(path) bytes=\(requestData.count)")

        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            var finished = false

            let timeout = DispatchWorkItem {
                if finished { return }
                finished = true
                connection.cancel()
                DebugLog.write("DaemonClient.sendAndReceive timeout path=\(path)")
                continuation.resume(throwing: DaemonClientError.timeout)
            }

            func finish(_ result: Result<Data, Error>) {
                if finished { return }
                finished = true
                timeout.cancel()
                connection.cancel()
                switch result {
                case .success(let data):
                    DebugLog.write("DaemonClient.sendAndReceive finish ok bytes=\(data.count)")
                case .failure(let error):
                    DebugLog.write("DaemonClient.sendAndReceive finish error=\(error)")
                }
                continuation.resume(with: result)
            }

            func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                    if let error = error {
                        finish(.failure(error))
                        return
                    }

                    if let data = data {
                        buffer.append(data)
                        if buffer.count > Constants.maxResponseBytes {
                            finish(.failure(DaemonClientError.invalidResponse))
                            return
                        }

                        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let slice = buffer.prefix(upTo: newlineIndex)
                            finish(.success(Data(slice)))
                            return
                        }
                    }

                    if isComplete {
                        finish(.success(buffer))
                        return
                    }

                    receiveNext()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    DebugLog.write("DaemonClient.sendAndReceive state=ready")
                    connection.send(content: requestData, completion: .contentProcessed { error in
                        if let error = error {
                            DebugLog.write("DaemonClient.sendAndReceive send error=\(error)")
                            finish(.failure(error))
                        } else {
                            receiveNext()
                        }
                    })
                case .failed(let error):
                    DebugLog.write("DaemonClient.sendAndReceive state=failed error=\(error)")
                    finish(.failure(error))
                case .cancelled:
                    if !finished {
                        DebugLog.write("DaemonClient.sendAndReceive state=cancelled")
                        finish(.failure(DaemonClientError.invalidResponse))
                    }
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + Constants.timeoutSeconds, execute: timeout)
            connection.start(queue: queue)
        }
    }
}
