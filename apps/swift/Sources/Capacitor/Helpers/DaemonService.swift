import Darwin
import Foundation
#if canImport(ServiceManagement)
    import ServiceManagement
#endif

enum DaemonService {
    private enum Constants {
        static let label = "com.capacitor.daemon"
        static let launchAgentPlistName = "\(label).plist"
        static let binaryName = "capacitor-daemon"
        static let enabledEnv = "CAPACITOR_DAEMON_ENABLED"
        static let throttleInterval: Int = 10
    }

    static func enableForCurrentProcess() {
        setenv(Constants.enabledEnv, "1", 1)
    }

    static func ensureRunning() -> String? {
        enableForCurrentProcess()
        DebugLog.write("DaemonService.ensureRunning start enabled=1")

        guard let binaryPath = DaemonInstaller.resolveBundledBinaryPath() else {
            let error = "Daemon binary not bundled with this app. Build capacitor-daemon or reinstall the app."
            DebugLog.write("DaemonService.ensureRunning binary resolution error=\(error)")
            Telemetry.emit("daemon_install_error", "Failed to resolve bundled daemon binary", payload: [
                "error": error,
            ])
            return error
        }

        DebugLog.write("DaemonService.ensureRunning binaryPath=\(binaryPath)")
        return LaunchAgentManager.installAndKickstart(binaryPath: binaryPath)
    }

    static func disable() -> String? {
        unsetenv(Constants.enabledEnv)
        return LaunchAgentManager.unregister()
    }

    private enum DaemonInstaller {
        static func resolveBundledBinaryPath() -> String? {
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
    }

    enum LaunchAgentManager {
        private static let canonicalBundleIdentifier = "com.capacitor.app"

        enum RegistrationResult: Equatable {
            case success
            case unavailable
            case requiresApproval(String)
            case failed(String)
        }

        static func installAndKickstart(
            binaryPath: String,
            homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
            uid: uid_t = getuid(),
            runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = systemLaunchctl,
            smAppServiceRegistration: () -> RegistrationResult = registerWithSMAppServiceIfAvailable,
        ) -> String? {
            switch smAppServiceRegistration() {
            case .success:
                DebugLog.write("DaemonService.installAndKickstart smAppService=success")
                if let cleanupError = cleanupLegacyLaunchAgent(
                    homeDir: homeDir,
                    uid: uid,
                    runLaunchctl: runLaunchctl,
                ) {
                    return cleanupError
                }
                return nil
            case let .requiresApproval(message):
                DebugLog.write("DaemonService.installAndKickstart smAppService=requiresApproval")
                Telemetry.emit("daemon_registration_error", "SMAppService registration requires user approval", payload: [
                    "error": message,
                ])
                return message
            case let .failed(error):
                DebugLog.write("DaemonService.installAndKickstart smAppService=failed error=\(error)")
                Telemetry.emit("daemon_registration_error", "SMAppService registration failed; falling back to launchctl", payload: [
                    "error": error,
                ])
            case .unavailable:
                DebugLog.write("DaemonService.installAndKickstart smAppService=unavailable fallback=launchctl")
            }

            return installAndKickstartLegacy(
                binaryPath: binaryPath,
                homeDir: homeDir,
                uid: uid,
                runLaunchctl: runLaunchctl,
            )
        }

        static func unregister(
            homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
            uid: uid_t = getuid(),
            runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = systemLaunchctl,
            smAppServiceUnregister: () -> RegistrationResult = unregisterWithSMAppServiceIfAvailable,
        ) -> String? {
            switch smAppServiceUnregister() {
            case let .requiresApproval(message):
                return message
            case let .failed(error):
                DebugLog.write("DaemonService.unregister smAppServiceUnregister failed error=\(error)")
            case .success, .unavailable:
                break
            }

            return cleanupLegacyLaunchAgent(homeDir: homeDir, uid: uid, runLaunchctl: runLaunchctl)
        }

        private static func legacyPlistURL(homeDir: URL) -> URL {
            homeDir
                .appendingPathComponent("Library")
                .appendingPathComponent("LaunchAgents")
                .appendingPathComponent(Constants.launchAgentPlistName)
        }

        @discardableResult
        private static func cleanupLegacyLaunchAgent(
            homeDir: URL,
            uid: uid_t,
            runLaunchctl: ([String]) -> (exitCode: Int32, output: String),
        ) -> String? {
            let plistURL = legacyPlistURL(homeDir: homeDir)
            guard FileManager.default.fileExists(atPath: plistURL.path) else {
                return nil
            }

            let domain = "gui/\(uid)"
            let bootout = runLaunchctl(["bootout", domain, plistURL.path])
            if bootout.exitCode != 0 {
                let output = bootout.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Failed to bootout legacy daemon launch agent: \(output)"
            }

            do {
                try FileManager.default.removeItem(at: plistURL)
            } catch {
                return "Failed to remove legacy daemon launch agent plist: \(error.localizedDescription)"
            }
            return nil
        }

        private static func installAndKickstartLegacy(
            binaryPath: String,
            homeDir: URL,
            uid: uid_t,
            runLaunchctl: ([String]) -> (exitCode: Int32, output: String),
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
            var jobRunning = jobLoaded && printResult.output.contains("state = running")

            if !jobLoaded {
                let bootstrap = runLaunchctl(["bootstrap", domain, plistURL.path])
                if bootstrap.exitCode != 0 {
                    let output = bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    DebugLog.write("DaemonService.bootstrap failed output=\(output)")
                    return "Failed to bootstrap daemon launch agent: \(output)"
                }
            } else if didChange {
                // Ensure launchd picks up plist changes, even if the daemon is currently running.
                let bootout = runLaunchctl(["bootout", domain, plistURL.path])
                if bootout.exitCode != 0 {
                    let output = bootout.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    DebugLog.write("DaemonService.bootout failed output=\(output)")
                    return "Failed to reload daemon launch agent (bootout): \(output)"
                }

                let bootstrap = runLaunchctl(["bootstrap", domain, plistURL.path])
                if bootstrap.exitCode != 0 {
                    let output = bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    DebugLog.write("DaemonService.bootstrap reload failed output=\(output)")
                    return "Failed to reload daemon launch agent (bootstrap): \(output)"
                }
                jobRunning = false
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

        private static func registerWithSMAppServiceIfAvailable() -> RegistrationResult {
            #if canImport(ServiceManagement)
                if #available(macOS 13.0, *) {
                    let plistName = Constants.launchAgentPlistName
                    guard hasBundledLaunchAgentPlist(named: plistName) else {
                        return .unavailable
                    }

                    let service = SMAppService.agent(plistName: plistName)
                    if service.status == .enabled {
                        return .success
                    }
                    if service.status == .requiresApproval {
                        return .requiresApproval(
                            "Daemon requires approval in System Settings > General > Login Items & Extensions.",
                        )
                    }
                    if service.status == .notFound {
                        return .unavailable
                    }

                    do {
                        try service.register()
                        return .success
                    } catch {
                        if service.status == .enabled {
                            return .success
                        }
                        if service.status == .requiresApproval {
                            return .requiresApproval(
                                "Daemon requires approval in System Settings > General > Login Items & Extensions.",
                            )
                        }
                        return .failed(error.localizedDescription)
                    }
                }
            #endif

            return .unavailable
        }

        private static func unregisterWithSMAppServiceIfAvailable() -> RegistrationResult {
            #if canImport(ServiceManagement)
                if #available(macOS 13.0, *) {
                    let plistName = Constants.launchAgentPlistName
                    guard hasBundledLaunchAgentPlist(named: plistName) else {
                        return .unavailable
                    }

                    let service = SMAppService.agent(plistName: plistName)
                    if service.status == .notFound {
                        return .unavailable
                    }
                    if service.status == .requiresApproval {
                        return .requiresApproval(
                            "Daemon requires approval in System Settings > General > Login Items & Extensions.",
                        )
                    }

                    do {
                        try service.unregister()
                        return .success
                    } catch {
                        if service.status == .notRegistered || service.status == .notFound {
                            return .success
                        }
                        return .failed(error.localizedDescription)
                    }
                }
            #endif

            return .unavailable
        }

        private static func hasBundledLaunchAgentPlist(named plistName: String) -> Bool {
            let bundleURL = Bundle.main.bundleURL
            let candidates = [
                bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)"),
                bundleURL.appendingPathComponent("Library/LaunchAgents/\(plistName)"),
            ]
            return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
        }

        static func writeLaunchAgentPlist(binaryPath: String, homeDir: URL) throws -> (URL, Bool) {
            let launchAgentsDir = homeDir.appendingPathComponent("Library/LaunchAgents")
            let logsDir = homeDir.appendingPathComponent(".capacitor/daemon")

            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)

            var environment: [String: String] = [
                "CAPACITOR_DAEMON_BINARY_REVISION": binaryRevisionToken(for: binaryPath),
            ]
            #if DEBUG
                environment["CAPACITOR_DEBUG_LOG"] = "1"
                environment["RUST_LOG"] = "debug"
            #endif

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

            let associatedBundleIdentifiers = preferredAssociatedBundleIdentifiers()
            if !associatedBundleIdentifiers.isEmpty {
                plist["AssociatedBundleIdentifiers"] = associatedBundleIdentifiers
            }

            plist["EnvironmentVariables"] = environment

            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let plistURL = launchAgentsDir.appendingPathComponent("\(Constants.label).plist")
            let existing = try? Data(contentsOf: plistURL)
            let didChange = existing != data
            if didChange {
                try data.write(to: plistURL, options: .atomic)
            }
            return (plistURL, didChange)
        }

        private static func preferredAssociatedBundleIdentifiers() -> [String] {
            var identifiers = [canonicalBundleIdentifier]
            if let activeBundleIdentifier = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !activeBundleIdentifier.isEmpty,
               !identifiers.contains(activeBundleIdentifier)
            {
                identifiers.append(activeBundleIdentifier)
            }
            return identifiers
        }

        private static func binaryRevisionToken(for binaryPath: String) -> String {
            let url = URL(fileURLWithPath: binaryPath)
            let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(fileSize)-\(Int64(modifiedAt))"
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
