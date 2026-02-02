import Foundation

/// Lightweight debug logger that appends to a file for deep diagnostics.
enum DebugLog {
    private static let logURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".capacitor/daemon/app-debug.log")
    }()

    private static let fallbackURL = URL(fileURLWithPath: "/tmp/capacitor-app-debug.log")

    static func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let data = Data(line.utf8)
        do {
            try append(data, to: logURL)
        } catch {
            do {
                try append(data, to: fallbackURL)
            } catch {
                // Intentionally ignore debug logging failures
            }
        }
    }

    private static func append(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
