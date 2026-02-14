@testable import Capacitor
import Darwin
import Foundation
import XCTest

final class DaemonClientTests: XCTestCase {
    func testUsesPosixUnixSocketTransport() async throws {
        setenv("CAPACITOR_DAEMON_ENABLED", "1", 1)
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let socketPath = tempDir.appendingPathComponent("daemon.sock").path

        let server = try UnixSocketServer(path: socketPath)
        defer { server.stop() }

        let response = makeProjectStatesResponse()
        server.start(response: response)

        setenv("CAPACITOR_DAEMON_SOCKET", socketPath, 1)
        defer { unsetenv("CAPACITOR_DAEMON_SOCKET") }

        let states = try await DaemonClient.shared.fetchProjectStates()

        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.projectPath, "/tmp/project")
    }

    func testEmptyResponseThrowsInvalidResponse() async throws {
        let client = DaemonClient(transport: { _ in Data() })

        do {
            _ = try await client.fetchProjectStates()
            XCTFail("Expected error")
        } catch let error as DaemonClientError {
            switch error {
            case .invalidResponse:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFetchRoutingSnapshotUsesExpectedMethodAndDecodesPayload() async throws {
        var capturedMethod: String?
        var capturedProjectPath: String?
        var capturedWorkspaceId: String?
        let client = DaemonClient(transport: { requestData in
            let requestJson = try JSONSerialization.jsonObject(with: requestData, options: [])
            let requestObject = requestJson as? [String: Any]
            capturedMethod = requestObject?["method"] as? String
            if let params = requestObject?["params"] as? [String: Any] {
                capturedProjectPath = params["project_path"] as? String
                capturedWorkspaceId = params["workspace_id"] as? String
            }
            return Self.makeRoutingSnapshotResponse()
        })

        let snapshot = try await client.fetchRoutingSnapshot(
            projectPath: "/Users/petepetrash/Code/capacitor",
            workspaceId: "workspace-1",
        )

        XCTAssertEqual(capturedMethod, "get_routing_snapshot")
        XCTAssertEqual(capturedProjectPath, "/Users/petepetrash/Code/capacitor")
        XCTAssertEqual(capturedWorkspaceId, "workspace-1")
        XCTAssertEqual(snapshot.status, "attached")
        XCTAssertEqual(snapshot.target.kind, "tmux_session")
        XCTAssertEqual(snapshot.target.value, "caps")
    }

    func testFetchRoutingDiagnosticsUsesExpectedMethod() async throws {
        var capturedMethod: String?
        let client = DaemonClient(transport: { requestData in
            let requestJson = try JSONSerialization.jsonObject(with: requestData, options: [])
            let requestObject = requestJson as? [String: Any]
            capturedMethod = requestObject?["method"] as? String
            return Self.makeRoutingDiagnosticsResponse()
        })

        let diagnostics = try await client.fetchRoutingDiagnostics(
            projectPath: "/Users/petepetrash/Code/capacitor",
            workspaceId: nil,
        )

        XCTAssertEqual(capturedMethod, "get_routing_diagnostics")
        XCTAssertEqual(diagnostics.snapshot.reasonCode, "TMUX_CLIENT_ATTACHED")
    }

    func testFetchDaemonConfigUsesExpectedMethodAndDecodesValues() async throws {
        var capturedMethod: String?
        let client = DaemonClient(transport: { requestData in
            let requestJson = try JSONSerialization.jsonObject(with: requestData, options: [])
            let requestObject = requestJson as? [String: Any]
            capturedMethod = requestObject?["method"] as? String
            return Self.makeRoutingConfigResponse()
        })

        let config = try await client.fetchDaemonConfig()
        XCTAssertEqual(capturedMethod, "get_config")
        XCTAssertEqual(config.tmuxSignalFreshMs, 5000)
        XCTAssertEqual(config.shellSignalFreshMs, 600_000)
        XCTAssertEqual(config.shellRetentionHours, 24)
        XCTAssertEqual(config.tmuxPollIntervalMs, 1000)
    }

    private func makeProjectStatesResponse() -> Data {
        let json = """
        {"ok":true,"id":"test","data":[{"project_path":"/tmp/project","state":"working","updated_at":"2026-02-02T19:00:00Z","state_changed_at":"2026-02-02T19:00:00Z","session_id":null,"session_count":1,"active_count":1,"has_session":false}]}
        """
        var data = Data(json.utf8)
        data.append(0x0A)
        return data
    }

    private static func makeRoutingSnapshotResponse() -> Data {
        let json = """
        {"ok":true,"id":"test","data":{"version":1,"workspace_id":"workspace-1","project_path":"/Users/petepetrash/Code/capacitor","status":"attached","target":{"kind":"tmux_session","value":"caps"},"confidence":"high","reason_code":"TMUX_CLIENT_ATTACHED","reason":"Attached tmux client","evidence":[],"updated_at":"2026-02-14T15:00:00Z"}}
        """
        var data = Data(json.utf8)
        data.append(0x0A)
        return data
    }

    private static func makeRoutingDiagnosticsResponse() -> Data {
        let json = """
        {"ok":true,"id":"test","data":{"snapshot":{"version":1,"workspace_id":"workspace-1","project_path":"/Users/petepetrash/Code/capacitor","status":"attached","target":{"kind":"tmux_session","value":"caps"},"confidence":"high","reason_code":"TMUX_CLIENT_ATTACHED","reason":"Attached tmux client","evidence":[],"updated_at":"2026-02-14T15:00:00Z"},"signal_ages_ms":{"tmux_client":250},"candidate_targets":[{"kind":"tmux_session","value":"caps"}],"conflicts":[],"scope_resolution":"path_exact"}}
        """
        var data = Data(json.utf8)
        data.append(0x0A)
        return data
    }

    private static func makeRoutingConfigResponse() -> Data {
        let json = """
        {"ok":true,"id":"test","data":{"tmux_signal_fresh_ms":5000,"shell_signal_fresh_ms":600000,"shell_retention_hours":24,"tmux_poll_interval_ms":1000}}
        """
        var data = Data(json.utf8)
        data.append(0x0A)
        return data
    }
}

final class UnixSocketServer {
    private let path: String
    private let fd: Int32
    private var workItem: DispatchWorkItem?

    init(path: String) throws {
        self.path = path
        _ = unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.fd = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }

        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: Int8.self, capacity: maxLen) { rebounded in
                    _ = strncpy(rebounded, cstr, maxLen - 1)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if bindResult != 0 {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw err
        }
        if listen(fd, 1) != 0 {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw err
        }
    }

    func start(response: Data, maxConnections: Int = 1) {
        start(
            responses: Array(repeating: response, count: maxConnections),
            maxConnections: maxConnections,
        )
    }

    func start(responses: [Data], maxConnections: Int? = nil) {
        let connectionLimit = maxConnections ?? responses.count
        guard connectionLimit > 0 else { return }
        let fallbackResponse = responses.last ?? Data()
        let work = DispatchWorkItem { [fd] in
            var served = 0
            while served < connectionLimit {
                var addr = sockaddr()
                var len = socklen_t(MemoryLayout<sockaddr>.size)
                let client = accept(fd, &addr, &len)
                if client < 0 {
                    return
                }

                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let n = read(client, &buffer, buffer.count)
                    if n <= 0 { break }
                    if buffer.prefix(n).contains(0x0A) { break }
                }
                let response: Data
                if responses.isEmpty {
                    response = fallbackResponse
                } else {
                    let responseIndex = min(served, responses.count - 1)
                    response = responses[responseIndex]
                }
                response.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    _ = write(client, base, response.count)
                }
                close(client)
                served += 1
            }
        }
        workItem = work
        DispatchQueue.global().async(execute: work)
    }

    func stop() {
        workItem?.cancel()
        close(fd)
        _ = unlink(path)
    }
}
