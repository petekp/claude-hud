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
            Telemetry.emit("daemon_install_error", "Failed to install daemon binary", payload: [
                "error": installError,
            ])
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

    enum LaunchAgentManager {
        static func installAndKickstart(
            binaryPath: String,
            homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
            uid: uid_t = getuid(),
            runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = systemLaunchctl,
        ) -> String? {
            let plistURL: URL
            let didChange: Bool
            do {
                (plistURL, didChange) = try writeLaunchAgentPlist(binaryPath: binaryPath, homeDir: homeDir)
            } catch {
                DebugLog.write("DaemonService.installAndKickstart plist error=\(error.localizedDescription)")
                return "Failed to write LaunchAgent plist: \(error.localizedDescription)"
            }

            let domain = "gui/\(uid)"
            let serviceTarget = "\(domain)/\(Constants.label)"

            // launchctl semantics matter here:
            // - `bootout` removes the job (and will SIGTERM it if running)
            // - `bootstrap` loads the plist into launchd
            // - `kickstart` starts the job; adding `-k` *restarts* it
            //
            // We do NOT want to repeatedly `bootout`/`kickstart -k` on a health-check loop,
            // since that causes thrash and leaves stale unix sockets behind.

            let printResult = runLaunchctl(["print", serviceTarget])
            let jobLoaded = printResult.exitCode == 0
            let jobRunning = jobLoaded && printResult.output.contains("state = running")

            if !jobLoaded {
                _ = runLaunchctl(["bootstrap", domain, plistURL.path])
            } else if didChange, !jobRunning {
                // Only reload the job if it isn't running, to avoid disrupting a healthy daemon.
                _ = runLaunchctl(["bootout", domain, plistURL.path])
                _ = runLaunchctl(["bootstrap", domain, plistURL.path])
            }

            if jobRunning {
                DebugLog.write("DaemonService.installAndKickstart alreadyRunning=1")
                return nil
            }

            // Prefer a non-disruptive kickstart. Only restart (-k) as a last resort.
            let kickstart = runLaunchctl(["kickstart", serviceTarget])
            if kickstart.exitCode == 0 {
                DebugLog.write("DaemonService.kickstart ok")
                return nil
            }

            DebugLog.write("DaemonService.kickstart failed output=\(kickstart.output)")
            Telemetry.emit("daemon_kickstart_error", "launchctl kickstart failed", payload: [
                "output": kickstart.output,
            ])

            let retryKickstart = runLaunchctl(["kickstart", "-k", serviceTarget])
            if retryKickstart.exitCode != 0 {
                DebugLog.write("DaemonService.kickstart -k failed output=\(retryKickstart.output)")
                Telemetry.emit("daemon_kickstart_error", "launchctl kickstart -k failed", payload: [
                    "output": retryKickstart.output,
                ])
                return "Failed to start daemon: \(retryKickstart.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            DebugLog.write("DaemonService.kickstart -k ok")
            return nil
        }

        static func writeLaunchAgentPlist(binaryPath: String, homeDir: URL) throws -> (URL, Bool) {
            let launchAgentsDir = homeDir.appendingPathComponent("Library/LaunchAgents")
            let logsDir = homeDir.appendingPathComponent(".capacitor/daemon")

            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)

            let environment: [String: String] = {
                #if DEBUG
                    return [
                        "CAPACITOR_DEBUG_LOG": "1",
                        "RUST_LOG": "debug",
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
                "WorkingDirectory": homeDir.appendingPathComponent(".capacitor").path,
                "StandardOutPath": logsDir.appendingPathComponent("daemon.stdout.log").path,
                "StandardErrorPath": logsDir.appendingPathComponent("daemon.stderr.log").path,
            ]

            if !environment.isEmpty {
                plist["EnvironmentVariables"] = environment
            }

            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let plistURL = launchAgentsDir.appendingPathComponent("\(Constants.label).plist")
            let existing = try? Data(contentsOf: plistURL)
            let didChange = existing != data
            if didChange {
                try data.write(to: plistURL, options: .atomic)
            }
            return (plistURL, didChange)
        }

        private static func systemLaunchctl(_ arguments: [String]) -> (exitCode: Int32, output: String) {
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
