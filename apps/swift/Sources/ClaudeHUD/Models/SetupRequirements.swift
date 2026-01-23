import Foundation
import SwiftUI

enum SetupStepStatus: Equatable {
    case pending
    case checking
    case completed(detail: String)
    case actionNeeded(message: String)
    case error(message: String)

    var isComplete: Bool {
        if case .completed = self { return true }
        return false
    }

    var isBlocking: Bool {
        if case .error = self { return true }
        return false
    }
}

struct SetupStep: Identifiable {
    let id: String
    let title: String
    let description: String
    var status: SetupStepStatus

    var statusDetail: String {
        switch status {
        case .pending:
            return description
        case .checking:
            return "Checking..."
        case .completed(let detail):
            return detail
        case .actionNeeded(let message):
            return message
        case .error(let message):
            return message
        }
    }
}

@Observable
@MainActor
final class SetupRequirementsManager {
    private(set) var steps: [SetupStep] = []
    private(set) var claudePath: String?
    private(set) var tmuxPath: String?
    private(set) var isRunningChecks = false
    private let engine: HudEngine

    var allComplete: Bool {
        steps.allSatisfy { $0.status.isComplete }
    }

    var hasBlockingError: Bool {
        steps.contains { $0.status.isBlocking }
    }

    var currentStepIndex: Int? {
        steps.firstIndex { !$0.status.isComplete }
    }

    init(engine: HudEngine? = nil) {
        self.engine = engine ?? (try? HudEngine()) ?? {
            fatalError("Failed to create HudEngine")
        }()
        setupSteps()
    }

    private func setupSteps() {
        steps = [
            SetupStep(
                id: "claude",
                title: "Claude CLI",
                description: "Required for session tracking",
                status: .pending
            ),
            SetupStep(
                id: "hooks",
                title: "Session hooks",
                description: "Required for live state tracking",
                status: .pending
            )
        ]
    }

    func runChecks() async {
        guard !isRunningChecks else { return }
        isRunningChecks = true
        defer { isRunningChecks = false }

        let setupStatus = engine.checkSetupStatus()

        for dep in setupStatus.dependencies {
            await updateDependencyStatus(dep)
        }

        await updateHookStatus(setupStatus.hooks)
    }

    private func updateDependencyStatus(_ dep: DependencyStatus) async {
        let stepId = dep.name

        guard steps.contains(where: { $0.id == stepId }) else { return }

        updateStep(stepId, status: .checking)

        if dep.found {
            let path = dep.path ?? "Found"
            updateStep(stepId, status: .completed(detail: path))

            if dep.name == "claude" {
                claudePath = dep.path
                if let path = dep.path {
                    await CapacitorConfig.shared.setClaudePath(path)
                }
            } else if dep.name == "tmux" {
                tmuxPath = dep.path
            }
        } else if dep.required {
            let hint = dep.installHint ?? "Please install \(dep.name)"
            updateStep(stepId, status: .error(message: hint))
        } else {
            let hint = dep.installHint ?? "Optional: install \(dep.name)"
            updateStep(stepId, status: .completed(detail: hint))
        }
    }

    private func updateHookStatus(_ hookStatus: HookStatus) async {
        updateStep("hooks", status: .checking)

        switch hookStatus {
        case .installed(let version):
            updateStep("hooks", status: .completed(detail: "v\(version) installed"))

        case .notInstalled:
            updateStep("hooks", status: .actionNeeded(message: "Not installed yet"))

        case .outdated(let current, let latest):
            updateStep("hooks", status: .actionNeeded(message: "Update available: v\(current) → v\(latest)"))

        case .policyBlocked(let reason):
            updateStep("hooks", status: .error(message: reason))

        case .binaryBroken(let reason):
            updateStep("hooks", status: .error(message: "Binary broken: \(reason)"))
        }
    }

    func executeStep(_ stepId: String) async {
        switch stepId {
        case "hooks":
            await installHooks()
        default:
            break
        }
    }

    func retryStep(_ stepId: String) async {
        switch stepId {
        case "claude":
            let dep = engine.checkDependency(name: stepId)
            await updateDependencyStatus(dep)
        case "hooks":
            let status = engine.getHookStatus()
            await updateHookStatus(status)
        default:
            break
        }
    }

    private func updateStep(_ id: String, status: SetupStepStatus) {
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index].status = status
        }
    }

    private func installHooks() async {
        updateStep("hooks", status: .checking)

        // First, install the bundled hook binary if needed
        if let installError = installBundledHookBinary() {
            updateStep("hooks", status: .error(message: installError))
            return
        }

        do {
            let result = try engine.installHooks()

            if result.success {
                let status = engine.getHookStatus()
                await updateHookStatus(status)
            } else {
                updateStep("hooks", status: .error(message: result.message))
            }
        } catch {
            updateStep("hooks", status: .error(message: "Installation failed: \(error.localizedDescription)"))
        }
    }

    /// Installs the bundled hud-hook binary to ~/.local/bin/hud-hook
    /// Returns an error message if installation fails, nil on success
    private func installBundledHookBinary() -> String? {
        let fileManager = FileManager.default
        let destDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin")
        let destPath = destDir.appendingPathComponent("hud-hook")

        // Skip if already exists and is executable
        if fileManager.fileExists(atPath: destPath.path) {
            if fileManager.isExecutableFile(atPath: destPath.path) {
                return nil // Already installed
            }
            // Exists but not executable - try to fix permissions
            do {
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath.path)
                return nil
            } catch {
                return "Failed to set permissions on existing hud-hook: \(error.localizedDescription)"
            }
        }

        // Find the bundled binary in our app bundle
        guard let bundledBinary = Bundle.main.url(forResource: "hud-hook", withExtension: nil) else {
            // Try Resources subdirectory
            if let resourcesPath = Bundle.main.resourcePath {
                let resourcesBinary = URL(fileURLWithPath: resourcesPath).appendingPathComponent("hud-hook")
                if fileManager.fileExists(atPath: resourcesBinary.path) {
                    return copyHookBinary(from: resourcesBinary, to: destPath, destDir: destDir)
                }
            }
            return "Hook binary not bundled with this app. Please reinstall Claude HUD."
        }

        return copyHookBinary(from: bundledBinary, to: destPath, destDir: destDir)
    }

    private func copyHookBinary(from source: URL, to dest: URL, destDir: URL) -> String? {
        let fileManager = FileManager.default

        // Create ~/.local/bin if needed
        do {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            return "Failed to create ~/.local/bin: \(error.localizedDescription)"
        }

        // Copy the binary
        do {
            try fileManager.copyItem(at: source, to: dest)
        } catch {
            return "Failed to copy hook binary: \(error.localizedDescription)"
        }

        // Make it executable
        do {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        } catch {
            return "Failed to set hook binary permissions: \(error.localizedDescription)"
        }

        return nil // Success
    }
}
