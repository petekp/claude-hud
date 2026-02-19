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
}
