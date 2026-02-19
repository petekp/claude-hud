@testable import Capacitor
import XCTest

final class DaemonServiceTests: XCTestCase {
    func testEnableForCurrentProcessSetsEnabledEnv() {
        unsetenv("CAPACITOR_DAEMON_ENABLED")
        defer { unsetenv("CAPACITOR_DAEMON_ENABLED") }

        XCTAssertNil(getenv("CAPACITOR_DAEMON_ENABLED"))

        DaemonService.enableForCurrentProcess()

        let value = String(cString: getenv("CAPACITOR_DAEMON_ENABLED"))
        XCTAssertEqual(value, "1")
    }

    func testLaunchAgentInstallDoesNotRestartWhenAlreadyRunningAndNoPlistChanges() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        // First write a plist, so subsequent calls see "no change".
        _ = try DaemonService.LaunchAgentManager.writeLaunchAgentPlist(binaryPath: "/bin/true", homeDir: homeDir)

        var calls: [[String]] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            if args.first == "print" {
                return (0, "state = running\n")
            }
            XCTFail("Unexpected launchctl call: \(args)")
            return (1, "unexpected")
        }

        // Plist is unchanged, so a running daemon should not be restarted.
        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .unavailable },
            )
        XCTAssertNil(error)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0], ["print", "gui/501/com.capacitor.daemon"])
    }

    func testLaunchAgentInstallKickstartsWhenLoadedButNotRunning() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        _ = try DaemonService.LaunchAgentManager.writeLaunchAgentPlist(binaryPath: "/bin/true", homeDir: homeDir)

        var calls: [[String]] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            switch args.first {
            case "print":
                return (0, "state = spawn scheduled\n")
            case "kickstart":
                return (0, "")
            default:
                XCTFail("Unexpected launchctl call: \(args)")
                return (1, "unexpected")
            }
        }

        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .unavailable },
            )
        XCTAssertNil(error)

        XCTAssertEqual(calls, [
            ["print", "gui/501/com.capacitor.daemon"],
            ["kickstart", "gui/501/com.capacitor.daemon"],
        ])
    }

    func testLaunchAgentInstallBootstrapsWhenJobNotLoaded() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        _ = try DaemonService.LaunchAgentManager.writeLaunchAgentPlist(binaryPath: "/bin/true", homeDir: homeDir)

        var calls: [[String]] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            switch args.first {
            case "print":
                return (1, "not loaded")
            case "bootstrap":
                return (0, "")
            case "kickstart":
                return (0, "")
            default:
                XCTFail("Unexpected launchctl call: \(args)")
                return (1, "unexpected")
            }
        }

        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .unavailable },
            )
        XCTAssertNil(error)

        let plistPath = homeDir
            .appendingPathComponent("Library/LaunchAgents/com.capacitor.daemon.plist")
            .path

        XCTAssertEqual(calls, [
            ["print", "gui/501/com.capacitor.daemon"],
            ["bootstrap", "gui/501", plistPath],
            ["kickstart", "gui/501/com.capacitor.daemon"],
        ])
    }

    func testLaunchAgentInstallReloadsWhenPlistChangesEvenIfAlreadyRunning() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        _ = try DaemonService.LaunchAgentManager.writeLaunchAgentPlist(binaryPath: "/bin/false", homeDir: homeDir)

        var calls: [[String]] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            switch args.first {
            case "print":
                return (0, "state = running\n")
            case "bootout", "bootstrap", "kickstart":
                return (0, "")
            default:
                XCTFail("Unexpected launchctl call: \(args)")
                return (1, "unexpected")
            }
        }

        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .unavailable },
            )
        XCTAssertNil(error)

        let plistPath = homeDir
            .appendingPathComponent("Library/LaunchAgents/com.capacitor.daemon.plist")
            .path
        XCTAssertEqual(calls, [
            ["print", "gui/501/com.capacitor.daemon"],
            ["bootout", "gui/501", plistPath],
            ["bootstrap", "gui/501", plistPath],
            ["kickstart", "gui/501/com.capacitor.daemon"],
        ])
    }

    func testLaunchAgentInstallPrefersSMAppServiceRegistrationWhenAvailable() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        var calls: [[String]] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            return (1, "launchctl should not be called when SMAppService succeeds")
        }

        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .success },
                daemonHealthCheck: { true },
            )
        XCTAssertNil(error)
        XCTAssertTrue(calls.isEmpty)
    }

    func testLaunchAgentInstallReturnsApprovalErrorWithoutLegacyFallback() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        var calls: [[String]] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            return (1, "launchctl should not be called when approval is required")
        }

        let message = "Daemon requires approval in System Settings > General > Login Items & Extensions."
        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .requiresApproval(message) },
            )
        XCTAssertEqual(error, message)
        XCTAssertTrue(calls.isEmpty)
    }

    func testLaunchAgentInstallFallsBackToLaunchctlWhenSMAppServiceFails() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        var calls: [[String]] = []
        var telemetryEvents: [(type: String, message: String, payload: [String: Any])] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            switch args.first {
            case "print":
                return (1, "not loaded")
            case "bootstrap", "kickstart":
                return (0, "")
            default:
                XCTFail("Unexpected launchctl call: \(args)")
                return (1, "unexpected")
            }
        }

        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .failed("SMAppService registration failed") },
                emitTelemetry: { type, message, payload in
                    telemetryEvents.append((type, message, payload))
                },
            )
        XCTAssertNil(error)

        let plistPath = homeDir
            .appendingPathComponent("Library/LaunchAgents/com.capacitor.daemon.plist")
            .path

        XCTAssertEqual(calls, [
            ["print", "gui/501/com.capacitor.daemon"],
            ["bootstrap", "gui/501", plistPath],
            ["kickstart", "gui/501/com.capacitor.daemon"],
        ])
        XCTAssertEqual(telemetryEvents.count, 1)
        XCTAssertEqual(telemetryEvents[0].type, "daemon_registration_error")
        XCTAssertTrue(telemetryEvents[0].message.contains("falling back to launchctl"))
        XCTAssertEqual(telemetryEvents[0].payload["error"] as? String, "SMAppService registration failed")
    }

    func testWriteLaunchAgentPlistAssociatesCapacitorBundleIdentifier() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        let (plistURL, _) = try DaemonService.LaunchAgentManager.writeLaunchAgentPlist(
            binaryPath: "/bin/true",
            homeDir: homeDir,
        )

        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        )
        let associatedBundleIdentifiers = try XCTUnwrap(
            plist["AssociatedBundleIdentifiers"] as? [String],
        )

        XCTAssertTrue(associatedBundleIdentifiers.contains("com.capacitor.app"))
    }

    func testBundledLaunchAgentPlistMatchesLegacyLaunchAgentDefaultsForSharedKeys() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CapacitorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // swift
        let bundledPlistURL = sourceRoot
            .appendingPathComponent("Resources/LaunchAgents/com.capacitor.daemon.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundledPlistURL.path))

        let bundledData = try Data(contentsOf: bundledPlistURL)
        let bundled = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: bundledData, format: nil) as? [String: Any],
        )

        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        let (legacyPlistURL, _) = try DaemonService.LaunchAgentManager.writeLaunchAgentPlist(
            binaryPath: "/bin/true",
            homeDir: homeDir,
        )
        let legacyData = try Data(contentsOf: legacyPlistURL)
        let legacy = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: legacyData, format: nil) as? [String: Any],
        )

        XCTAssertEqual(bundled["Label"] as? String, legacy["Label"] as? String)
        XCTAssertEqual(bundled["RunAtLoad"] as? Bool, legacy["RunAtLoad"] as? Bool)
        XCTAssertEqual(bundled["KeepAlive"] as? Bool, legacy["KeepAlive"] as? Bool)
        XCTAssertEqual(
            bundled["ThrottleInterval"] as? Int,
            legacy["ThrottleInterval"] as? Int,
        )
        XCTAssertEqual(bundled["ProcessType"] as? String, legacy["ProcessType"] as? String)

        let bundledAssociated = try XCTUnwrap(
            bundled["AssociatedBundleIdentifiers"] as? [String],
        )
        let legacyAssociated = try XCTUnwrap(
            legacy["AssociatedBundleIdentifiers"] as? [String],
        )
        XCTAssertTrue(bundledAssociated.contains("com.capacitor.app"))
        XCTAssertTrue(legacyAssociated.contains("com.capacitor.app"))
    }

    func testLaunchAgentInstallCleansLegacyPlistWhenSMAppServiceSucceeds() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let launchAgentsDir = homeDir.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        let legacyPlist = launchAgentsDir.appendingPathComponent("com.capacitor.daemon.plist")
        try Data("<plist/>".utf8).write(to: legacyPlist)

        var calls: [[String]] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            if args.first == "bootout" {
                return (0, "")
            }
            return (1, "unexpected")
        }

        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .success },
                daemonHealthCheck: { true },
            )

        XCTAssertNil(error)
        XCTAssertEqual(calls, [["bootout", "gui/501", legacyPlist.path]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPlist.path))
    }

    func testLaunchAgentInstallReturnsErrorWhenBootstrapFails() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        var calls: [[String]] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            switch args.first {
            case "print":
                return (1, "not loaded")
            case "bootstrap":
                return (1, "bootstrap failed")
            default:
                return (0, "")
            }
        }

        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .unavailable },
            )

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("bootstrap") == true)
        XCTAssertFalse(calls.contains { $0.first == "kickstart" })
    }

    func testLaunchAgentInstallFallsBackWhenSMAppServiceSucceedsButDaemonUnhealthy() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        var calls: [[String]] = []
        var telemetryEvents: [(type: String, message: String, payload: [String: Any])] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            switch args.first {
            case "print":
                return (1, "not loaded")
            case "bootstrap", "kickstart":
                return (0, "")
            default:
                XCTFail("Unexpected launchctl call: \(args)")
                return (1, "unexpected")
            }
        }

        var healthChecks = 0
        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .success },
                daemonHealthCheck: {
                    healthChecks += 1
                    return false
                },
                healthCheckAttempts: 2,
                healthCheckRetryDelay: 0,
                emitTelemetry: { type, message, payload in
                    telemetryEvents.append((type, message, payload))
                },
            )

        XCTAssertNil(error)
        XCTAssertEqual(healthChecks, 2)
        XCTAssertEqual(telemetryEvents.count, 1)
        XCTAssertEqual(telemetryEvents[0].type, "daemon_registration_error")
        XCTAssertTrue(telemetryEvents[0].message.contains("health check failed"))
        XCTAssertEqual(telemetryEvents[0].payload["attempts"] as? Int, 2)

        let plistPath = homeDir
            .appendingPathComponent("Library/LaunchAgents/com.capacitor.daemon.plist")
            .path
        XCTAssertEqual(calls, [
            ["print", "gui/501/com.capacitor.daemon"],
            ["bootstrap", "gui/501", plistPath],
            ["kickstart", "gui/501/com.capacitor.daemon"],
        ])
    }

    func testLaunchAgentInstallDoesNotFallbackWhenSMAppServiceHealthTurnsReadyAfterInitialGrace() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        var calls: [[String]] = []
        var telemetryEvents: [(type: String, message: String, payload: [String: Any])] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            switch args.first {
            case "print":
                return (1, "not loaded")
            case "bootstrap", "kickstart":
                return (0, "")
            default:
                XCTFail("Unexpected launchctl call: \(args)")
                return (1, "unexpected")
            }
        }

        var healthChecks = 0
        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .success },
                daemonHealthCheck: {
                    healthChecks += 1
                    return healthChecks >= 7
                },
                healthCheckRetryDelay: 0,
                emitTelemetry: { type, message, payload in
                    telemetryEvents.append((type, message, payload))
                },
            )

        XCTAssertNil(error)
        XCTAssertEqual(
            healthChecks,
            7,
            "SMAppService startup should tolerate a short warmup window and avoid immediate fallback thrash.",
        )
        XCTAssertTrue(calls.isEmpty, "launchctl fallback should not run when health eventually turns ready.")
        XCTAssertTrue(telemetryEvents.isEmpty, "no registration error telemetry expected when health becomes ready.")
    }

    func testLaunchAgentInstallDoesNotFallbackWhenSMAppServiceHealthTurnsReadyAfterExtendedWarmup() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        var calls: [[String]] = []
        var telemetryEvents: [(type: String, message: String, payload: [String: Any])] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            switch args.first {
            case "print":
                return (1, "not loaded")
            case "bootstrap", "kickstart":
                return (0, "")
            default:
                XCTFail("Unexpected launchctl call: \(args)")
                return (1, "unexpected")
            }
        }

        var healthChecks = 0
        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .success },
                daemonHealthCheck: {
                    healthChecks += 1
                    return healthChecks >= 10
                },
                healthCheckRetryDelay: 0,
                emitTelemetry: { type, message, payload in
                    telemetryEvents.append((type, message, payload))
                },
            )

        XCTAssertNil(error)
        XCTAssertEqual(
            healthChecks,
            10,
            "SMAppService startup should tolerate delayed socket readiness without falling back to launchctl.",
        )
        XCTAssertTrue(calls.isEmpty, "launchctl fallback should not run when SMAppService becomes healthy.")
        XCTAssertTrue(telemetryEvents.isEmpty, "no registration error telemetry expected when health eventually turns ready.")
    }

    func testLaunchAgentInstallRetriesSMAppServiceBeforeLegacyFallbackWhenDefaultHealthWindowFails() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        var calls: [[String]] = []
        var telemetryEvents: [(type: String, message: String, payload: [String: Any])] = []
        var smRegistrationCalls = 0
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            switch args.first {
            case "print":
                return (1, "not loaded")
            case "bootstrap", "kickstart":
                return (0, "")
            default:
                XCTFail("Unexpected launchctl call: \(args)")
                return (1, "unexpected")
            }
        }

        var healthChecks = 0
        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: {
                    smRegistrationCalls += 1
                    return .success
                },
                daemonHealthCheck: {
                    healthChecks += 1
                    return smRegistrationCalls >= 2
                },
                healthCheckRetryDelay: 0,
                emitTelemetry: { type, message, payload in
                    telemetryEvents.append((type, message, payload))
                },
            )

        XCTAssertNil(error)
        XCTAssertEqual(smRegistrationCalls, 2, "SMAppService should be re-registered once before legacy fallback in default startup mode.")
        XCTAssertTrue(healthChecks >= 13, "expected the first health window to fully exhaust before second registration attempt")
        XCTAssertTrue(calls.isEmpty, "launchctl fallback should not run when second SMAppService registration enables health")
        XCTAssertTrue(telemetryEvents.isEmpty, "registration retry path should not emit fallback telemetry when health recovers")
    }

    func testLaunchAgentInstallSurfacesErrorWhenSMAppServiceSucceedsButFallbackFails() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        var calls: [[String]] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            switch args.first {
            case "print":
                return (1, "not loaded")
            case "bootstrap":
                return (1, "bootstrap failed")
            default:
                return (0, "")
            }
        }

        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .success },
                daemonHealthCheck: { false },
                healthCheckAttempts: 1,
                healthCheckRetryDelay: 0,
            )

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("bootstrap") == true)
        XCTAssertEqual(calls.count(where: { $0.first == "kickstart" }), 0)
    }

    func testLaunchAgentInstallEmitsTelemetryWhenKickstartAndRetryFail() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        _ = try DaemonService.LaunchAgentManager.writeLaunchAgentPlist(binaryPath: "/bin/true", homeDir: homeDir)

        var telemetryEvents: [(type: String, message: String, payload: [String: Any])] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            switch args.first {
            case "print":
                return (0, "state = spawn scheduled\n")
            case "kickstart":
                if args.count >= 2, args[1] == "-k" {
                    return (1, "restart failed")
                }
                return (1, "kickstart failed")
            default:
                XCTFail("Unexpected launchctl call: \(args)")
                return (1, "unexpected")
            }
        }

        let error = DaemonService
            .LaunchAgentManager
            .installAndKickstart(
                binaryPath: "/bin/true",
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceRegistration: { .unavailable },
                emitTelemetry: { type, message, payload in
                    telemetryEvents.append((type, message, payload))
                },
            )

        XCTAssertNotNil(error)
        XCTAssertEqual(telemetryEvents.count, 2)
        XCTAssertEqual(telemetryEvents[0].type, "daemon_kickstart_error")
        XCTAssertTrue(telemetryEvents[0].message.contains("kickstart failed"))
        XCTAssertEqual(telemetryEvents[0].payload["output"] as? String, "kickstart failed")
        XCTAssertEqual(telemetryEvents[1].type, "daemon_kickstart_error")
        XCTAssertTrue(telemetryEvents[1].message.contains("kickstart -k failed"))
        XCTAssertEqual(telemetryEvents[1].payload["output"] as? String, "restart failed")
    }

    func testWriteLaunchAgentPlistIncludesBinaryRevisionEnvironment() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        let binary = homeDir.appendingPathComponent("bin/capacitor-daemon")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("daemon".utf8).write(to: binary)

        let (plistURL, _) = try DaemonService.LaunchAgentManager.writeLaunchAgentPlist(
            binaryPath: binary.path,
            homeDir: homeDir,
        )

        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        )
        let environment = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
        let revision = try XCTUnwrap(environment["CAPACITOR_DAEMON_BINARY_REVISION"])
        XCTAssertFalse(revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testTrimDaemonLogsCompactsOversizedStdoutAndStderrLogs() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logsDir = homeDir.appendingPathComponent(".capacitor/daemon")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let stdout = logsDir.appendingPathComponent("daemon.stdout.log")
        let stderr = logsDir.appendingPathComponent("daemon.stderr.log")
        let oversizeData = Data(repeating: UInt8(ascii: "x"), count: 4096)
        try oversizeData.write(to: stdout, options: .atomic)
        try oversizeData.write(to: stderr, options: .atomic)

        DaemonService
            .LaunchAgentManager
            .trimDaemonLogs(
                homeDir: homeDir,
                maxBytes: 1024,
                retainBytes: 256,
            )

        let stdoutData = try Data(contentsOf: stdout)
        let stderrData = try Data(contentsOf: stderr)

        XCTAssertLessThanOrEqual(stdoutData.count, 512)
        XCTAssertLessThanOrEqual(stderrData.count, 512)

        let stdoutText = String(decoding: stdoutData, as: UTF8.self)
        let stderrText = String(decoding: stderrData, as: UTF8.self)
        XCTAssertTrue(stdoutText.contains("trimmed oversized daemon log"))
        XCTAssertTrue(stderrText.contains("trimmed oversized daemon log"))
    }

    func testLaunchAgentUnregisterBootsOutAndDeletesLegacyPlist() throws {
        let homeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let launchAgentsDir = homeDir.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        let legacyPlist = launchAgentsDir.appendingPathComponent("com.capacitor.daemon.plist")
        try Data("<plist/>".utf8).write(to: legacyPlist)

        var calls: [[String]] = []
        let runLaunchctl: ([String]) -> (exitCode: Int32, output: String) = { args in
            calls.append(args)
            return (0, "")
        }

        let error = DaemonService
            .LaunchAgentManager
            .unregister(
                homeDir: homeDir,
                uid: 501,
                runLaunchctl: runLaunchctl,
                smAppServiceUnregister: { .unavailable },
            )

        XCTAssertNil(error)
        XCTAssertEqual(calls, [["bootout", "gui/501", legacyPlist.path]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPlist.path))
    }
}
