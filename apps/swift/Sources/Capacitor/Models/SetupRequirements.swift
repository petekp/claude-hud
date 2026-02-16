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
    var isOptional: Bool = false

    var statusDetail: String {
        switch status {
        case .pending:
            description
        case .checking:
            "Checking..."
        case let .completed(detail):
            detail
        case let .actionNeeded(message):
            message
        case let .error(message):
            message
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
    var showShellInstructions = false
    private let engine: HudEngine?
    private weak var shellStateStore: ShellStateStore?
    private let isPreview: Bool

    var allComplete: Bool {
        steps.filter { !$0.isOptional }.allSatisfy(\.status.isComplete)
    }

    var hasBlockingError: Bool {
        steps.contains { $0.status.isBlocking }
    }

    var currentStepIndex: Int? {
        steps.firstIndex { !$0.status.isComplete }
    }

    init(engine: HudEngine? = nil, shellStateStore: ShellStateStore? = nil) {
        self.engine = engine ?? (try? HudEngine()) ?? {
            fatalError("Failed to create HudEngine")
        }()
        self.shellStateStore = shellStateStore
        isPreview = false
        setupSteps()
    }

    /// Preview-only initializer: pre-bakes step states so previews are instant and deterministic.
    private init(previewSteps: [SetupStep]) {
        engine = nil
        shellStateStore = nil
        isPreview = true
        steps = previewSteps
    }

    private func setupSteps() {
        steps = [
            SetupStep(
                id: "claude",
                title: "Claude Code",
                description: "Capacitor needs Claude Code to work",
                status: .pending,
            ),
            SetupStep(
                id: "hooks",
                title: "Session hooks",
                description: "Connect Capacitor to your Claude sessions",
                status: .pending,
            ),
            SetupStep(
                id: "shell",
                title: "Shell integration",
                description: "Track which project you're working in",
                status: .pending,
                isOptional: true,
            ),
        ]
    }

    func runChecks() async {
        guard !isPreview, !isRunningChecks, let engine else { return }
        isRunningChecks = true
        defer { isRunningChecks = false }

        let setupStatus = engine.checkSetupStatus()

        for dep in setupStatus.dependencies {
            await updateDependencyStatus(dep)
        }

        await updateHookStatus(setupStatus.hooks)
        updateShellStatus()
    }

    private func updateShellStatus() {
        updateStep("shell", status: .checking)

        let shellType = ShellType.current

        if let store = shellStateStore, ShellIntegrationChecker.isConfigured(shellStateStore: store) {
            updateStep("shell", status: .completed(detail: "Receiving shell events"))
        } else if shellType.isSnippetInstalled {
            updateStep("shell", status: .completed(detail: "\(shellType.configFile) configured"))
        } else if shellType == .unsupported {
            updateStep("shell", status: .completed(detail: "Skipped: unsupported shell"))
        } else {
            updateStep("shell", status: .actionNeeded(message: "Optional: add to \(shellType.configFile)"))
        }
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
            let hint = dep.name == "claude"
                ? "Not found — download from claude.ai/download"
                : dep.installHint ?? "Please install \(dep.name)"
            updateStep(stepId, status: .error(message: hint))
        } else {
            let hint = dep.installHint ?? "Optional: install \(dep.name)"
            updateStep(stepId, status: .completed(detail: hint))
        }
    }

    private func updateHookStatus(_ hookStatus: HookStatus) async {
        updateStep("hooks", status: .checking)

        switch hookStatus {
        case let .installed(version):
            updateStep("hooks", status: .completed(detail: "v\(version) installed"))

        case .notInstalled:
            updateStep("hooks", status: .actionNeeded(message: "Install hooks to enable session tracking"))

        case let .policyBlocked(reason):
            updateStep("hooks", status: .error(message: reason))

        case let .binaryBroken(reason):
            updateStep("hooks", status: .error(message: "Binary broken: \(reason)"))

        case let .symlinkBroken(target, reason):
            updateStep("hooks", status: .error(message: "Symlink broken: \(reason) (target: \(target))"))
        }
    }

    func executeStep(_ stepId: String) async {
        switch stepId {
        case "hooks":
            await installHooks()
        case "shell":
            showShellInstructions = true
        default:
            break
        }
    }

    func retryStep(_ stepId: String) async {
        guard let engine else { return }
        switch stepId {
        case "claude":
            let dep = engine.checkDependency(name: stepId)
            await updateDependencyStatus(dep)
        case "hooks":
            let status = engine.getHookStatus()
            await updateHookStatus(status)
        case "shell":
            updateShellStatus()
        default:
            break
        }
    }

    func dismissShellInstructions() {
        showShellInstructions = false
        updateShellStatus()
    }

    private func updateStep(_ id: String, status: SetupStepStatus) {
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index].status = status
        }
    }

    private func installHooks() async {
        guard let engine else { return }
        updateStep("hooks", status: .checking)

        // First, install the bundled hook binary using the shared helper
        if let installError = HookInstaller.installBundledBinary(using: engine) {
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
}

// MARK: - Preview Scenarios

#if DEBUG
    enum SetupPreviewScenario: String, CaseIterable, Identifiable {
        case allPending = "All Pending"
        case checking = "Checking"
        case cliMissing = "CLI Missing"
        case hooksNeeded = "Hooks Needed"
        case hooksError = "Hooks Error"
        case hooksPolicyBlocked = "Policy Blocked"
        case shellOptional = "Shell Optional"
        case allComplete = "All Complete"

        var id: String {
            rawValue
        }
    }

    extension SetupRequirementsManager {
        static func preview(_ scenario: SetupPreviewScenario) -> SetupRequirementsManager {
            SetupRequirementsManager(previewSteps: scenario.steps)
        }
    }

    extension SetupPreviewScenario {
        var steps: [SetupStep] {
            switch self {
            case .allPending:
                [
                    SetupStep(id: "claude", title: "Claude Code", description: "Capacitor needs Claude Code to work", status: .pending),
                    SetupStep(id: "hooks", title: "Session hooks", description: "Connect Capacitor to your Claude sessions", status: .pending),
                    SetupStep(id: "shell", title: "Shell integration", description: "Track which project you're working in", status: .pending, isOptional: true),
                ]

            case .checking:
                [
                    SetupStep(id: "claude", title: "Claude Code", description: "Capacitor needs Claude Code to work", status: .checking),
                    SetupStep(id: "hooks", title: "Session hooks", description: "Connect Capacitor to your Claude sessions", status: .pending),
                    SetupStep(id: "shell", title: "Shell integration", description: "Track which project you're working in", status: .pending, isOptional: true),
                ]

            case .cliMissing:
                [
                    SetupStep(id: "claude", title: "Claude Code", description: "Capacitor needs Claude Code to work", status: .error(message: "Claude Code not found. Install it from claude.ai/download")),
                    SetupStep(id: "hooks", title: "Session hooks", description: "Connect Capacitor to your Claude sessions", status: .pending),
                    SetupStep(id: "shell", title: "Shell integration", description: "Track which project you're working in", status: .pending, isOptional: true),
                ]

            case .hooksNeeded:
                [
                    SetupStep(id: "claude", title: "Claude Code", description: "Capacitor needs Claude Code to work", status: .completed(detail: "/usr/local/bin/claude")),
                    SetupStep(id: "hooks", title: "Session hooks", description: "Connect Capacitor to your Claude sessions", status: .actionNeeded(message: "Install hooks to enable session tracking")),
                    SetupStep(id: "shell", title: "Shell integration", description: "Track which project you're working in", status: .pending, isOptional: true),
                ]

            case .hooksError:
                [
                    SetupStep(id: "claude", title: "Claude Code", description: "Capacitor needs Claude Code to work", status: .completed(detail: "/usr/local/bin/claude")),
                    SetupStep(id: "hooks", title: "Session hooks", description: "Connect Capacitor to your Claude sessions", status: .error(message: "Binary broken: code signature invalid (SIGKILL)")),
                    SetupStep(id: "shell", title: "Shell integration", description: "Track which project you're working in", status: .pending, isOptional: true),
                ]

            case .hooksPolicyBlocked:
                [
                    SetupStep(id: "claude", title: "Claude Code", description: "Capacitor needs Claude Code to work", status: .completed(detail: "/usr/local/bin/claude")),
                    SetupStep(id: "hooks", title: "Session hooks", description: "Connect Capacitor to your Claude sessions", status: .error(message: "Hooks disabled by policy: disableAllHooks is set")),
                    SetupStep(id: "shell", title: "Shell integration", description: "Track which project you're working in", status: .pending, isOptional: true),
                ]

            case .shellOptional:
                [
                    SetupStep(id: "claude", title: "Claude Code", description: "Capacitor needs Claude Code to work", status: .completed(detail: "/usr/local/bin/claude")),
                    SetupStep(id: "hooks", title: "Session hooks", description: "Connect Capacitor to your Claude sessions", status: .completed(detail: "v1.0.0 installed")),
                    SetupStep(id: "shell", title: "Shell integration", description: "Track which project you're working in", status: .actionNeeded(message: "Optional: add to ~/.zshrc"), isOptional: true),
                ]

            case .allComplete:
                [
                    SetupStep(id: "claude", title: "Claude Code", description: "Capacitor needs Claude Code to work", status: .completed(detail: "/usr/local/bin/claude")),
                    SetupStep(id: "hooks", title: "Session hooks", description: "Connect Capacitor to your Claude sessions", status: .completed(detail: "v1.0.0 installed")),
                    SetupStep(id: "shell", title: "Shell integration", description: "Track which project you're working in", status: .completed(detail: "~/.zshrc configured"), isOptional: true),
                ]
            }
        }
    }
#endif
