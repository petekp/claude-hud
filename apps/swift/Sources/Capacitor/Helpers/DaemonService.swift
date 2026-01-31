import Darwin
import Foundation

enum DaemonService {
    private enum Constants {
        static let label = "com.capacitor.daemon"
        static let binaryName = "capacitor-daemon"
        static let enabledEnv = "CAPACITOR_DAEMON_ENABLED"
        static let throttleInterval: Int = 10
    }

    static func ensureRunning() -> String? {
        setenv(Constants.enabledEnv, "1", 1)
        DebugLog.write("DaemonService.ensureRunning start enabled=1")

        if let installError = DaemonInstaller.installBundledBinary() {
            DebugLog.write("DaemonService.ensureRunning install error=\(installError)")
            return installError
        }

        let binaryPath = DaemonInstaller.targetPath
        DebugLog.write("DaemonService.ensureRunning binaryPath=\(binaryPath)")
        return LaunchAgentManager.installAndKickstart(binaryPath: binaryPath)
    }

    private enum DaemonInstaller {
        static let targetPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/\(Constants.binaryName)")
            .path

        static func installBundledBinary() -> String? {
            if let sourcePath = findBundledBinary() {
                return symlinkBinary(from: sourcePath, to: targetPath)
            }

            if isTargetBinaryInstalled() {
                return nil
            }

            return "Daemon binary not bundled with this app. Build capacitor-daemon or reinstall the app."
        }

        private static func isTargetBinaryInstalled() -> Bool {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: targetPath) else { return false }
            return fileManager.isExecutableFile(atPath: targetPath)
        }

        private static func findBundledBinary() -> String? {
            if let bundledBinary = Bundle.main.url(forResource: Constants.binaryName, withExtension: nil) {
                return bundledBinary.path
            }

            if let resourcesPath = Bundle.main.resourcePath {
                let resourcesBinary = URL(fileURLWithPath: resourcesPath).appendingPathComponent(Constants.binaryName)
                if FileManager.default.fileExists(atPath: resourcesBinary.path) {
                    return resourcesBinary.path
                }
            }

            if let executableURL = Bundle.main.executableURL {
                let siblingBinary = executableURL.deletingLastPathComponent().appendingPathComponent(Constants.binaryName)
                if FileManager.default.fileExists(atPath: siblingBinary.path) {
                    return siblingBinary.path
                }
            }

            return nil
        }

        private static func symlinkBinary(from sourcePath: String, to destinationPath: String) -> String? {
            let fileManager = FileManager.default
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let destURL = URL(fileURLWithPath: destinationPath)
            let destDir = destURL.deletingLastPathComponent()

            do {
                try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: nil)

                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }

                try fileManager.createSymbolicLink(at: destURL, withDestinationURL: sourceURL)
                DebugLog.write("DaemonService.symlinkBinary src=\(sourcePath) dest=\(destinationPath)")
                return nil
            } catch {
                return "Failed to install daemon binary: \(error.localizedDescription)"
            }
        }
    }

    private enum LaunchAgentManager {
        static func installAndKickstart(binaryPath: String) -> String? {
            let plistURL: URL
            do {
                plistURL = try writeLaunchAgentPlist(binaryPath: binaryPath)
            } catch {
                DebugLog.write("DaemonService.installAndKickstart plist error=\(error.localizedDescription)")
                return "Failed to write LaunchAgent plist: \(error.localizedDescription)"
            }

            let domain = "gui/\(getuid())"

            _ = runLaunchctl(["bootout", domain, plistURL.path])
            _ = runLaunchctl(["bootstrap", domain, plistURL.path])

            let kickstart = runLaunchctl(["kickstart", "-k", "\(domain)/\(Constants.label)"])
            if kickstart.exitCode != 0 {
                DebugLog.write("DaemonService.kickstart failed output=\(kickstart.output)")
                return "Failed to start daemon: \(kickstart.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            DebugLog.write("DaemonService.kickstart ok")

            return nil
        }

        private static func writeLaunchAgentPlist(binaryPath: String) throws -> URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let launchAgentsDir = home.appendingPathComponent("Library/LaunchAgents")
            let logsDir = home.appendingPathComponent(".capacitor/daemon")

            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)

            let environment: [String: String] = {
#if DEBUG
                return [
                    "CAPACITOR_DEBUG_LOG": "1",
                    "RUST_LOG": "debug"
                ]
#else
                return [:]
#endif
            }()

            var plist: [String: Any] = [
                "Label": Constants.label,
                "ProgramArguments": [binaryPath],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ThrottleInterval": Constants.throttleInterval,
                "ProcessType": "Background",
                "WorkingDirectory": home.appendingPathComponent(".capacitor").path,
                "StandardOutPath": logsDir.appendingPathComponent("daemon.stdout.log").path,
                "StandardErrorPath": logsDir.appendingPathComponent("daemon.stderr.log").path
            ]

            if !environment.isEmpty {
                plist["EnvironmentVariables"] = environment
            }

            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let plistURL = launchAgentsDir.appendingPathComponent("\(Constants.label).plist")
            try data.write(to: plistURL, options: .atomic)
            return plistURL
        }

        private static func runLaunchctl(_ arguments: [String]) -> (exitCode: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return (1, error.localizedDescription)
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        }
    }
}
