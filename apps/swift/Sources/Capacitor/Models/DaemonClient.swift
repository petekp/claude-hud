import Darwin
import Foundation

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
    let hasSession: Bool

    enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case state
        case updatedAt = "updated_at"
        case stateChangedAt = "state_changed_at"
        case sessionId = "session_id"
        case sessionCount = "session_count"
        case activeCount = "active_count"
        case hasSession = "has_session"
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
    typealias Transport = (Data) async throws -> Data

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
    private let transportOverride: Transport?

    init(transport: @escaping Transport) {
        self.transportOverride = transport
    }

    private init() {
        self.transportOverride = nil
    }

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
        let transport = transportOverride ?? sendAndReceivePosix
        return try await transport(requestData)
    }

    private func sendAndReceivePosix(_ requestData: Data) async throws -> Data {
        let path = try socketPath()
        DebugLog.write("DaemonClient.sendAndReceive posix connect path=\(path) bytes=\(requestData.count)")

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let fd = try Self.openUnixSocket(path: path, timeoutSeconds: Constants.timeoutSeconds)
                    defer { close(fd) }

                    try Self.writeAll(fd: fd, data: requestData)
                    let response = try Self.readUntilNewline(fd: fd, maxBytes: Constants.maxResponseBytes)

                    DebugLog.write("DaemonClient.sendAndReceive posix finish ok bytes=\(response.count)")
                    continuation.resume(returning: response)
                } catch {
                    DebugLog.write("DaemonClient.sendAndReceive posix finish error=\(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func openUnixSocket(path: String, timeoutSeconds: TimeInterval) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let microseconds = Int32((timeoutSeconds - floor(timeoutSeconds)) * 1_000_000)
        var timeout = timeval(
            tv_sec: Int(timeoutSeconds),
            tv_usec: microseconds
        )
        let timeSize = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeSize)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeSize)
        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else {
            close(fd)
            throw DaemonClientError.invalidResponse
        }

        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: Int8.self, capacity: maxLen) { rebounded in
                    _ = strncpy(rebounded, cstr, maxLen - 1)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw err
        }

        return fd
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n > 0 {
                    sent += n
                } else if n == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw DaemonClientError.timeout
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private static func readUntilNewline(fd: Int32, maxBytes: Int) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk.prefix(n))
                if buffer.count > maxBytes {
                    throw DaemonClientError.invalidResponse
                }
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    return Data(buffer.prefix(upTo: newlineIndex))
                }
                continue
            }
            if n == 0 {
                return buffer
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw DaemonClientError.timeout
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
