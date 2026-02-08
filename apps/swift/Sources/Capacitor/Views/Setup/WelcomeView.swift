import AppKit
import SwiftUI

@MainActor
struct WelcomeView: View {
    @State private var manager = SetupRequirementsManager()
    @State private var checkID = UUID()
    var shellStateStore: ShellStateStore?
    var onComplete: () -> Void

    private static let cachedLogomarkImage: NSImage? = {
        guard let url = ResourceBundle.url(forResource: "logomark", withExtension: "pdf") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    private var logomarkImage: NSImage? {
        Self.cachedLogomarkImage
    }

    private var userFirstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 40)

                headerSection
                    .padding(.bottom, 32)

                stepsSection

                transparencySection

                Spacer()
                    .frame(minHeight: 40)

                footerSection
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: checkID) {
            await manager.runChecks()
        }
        .onAppear {
            manager = SetupRequirementsManager(shellStateStore: shellStateStore)
            checkID = UUID()
        }
        .onChange(of: shellStateStore?.state?.shells.count) { _, _ in
            _Concurrency.Task {
                await manager.retryStep("shell")
            }
        }
        .sheet(isPresented: $manager.showShellInstructions) {
            ShellInstructionsSheet(
                isPresented: $manager.showShellInstructions,
                onDismiss: { manager.dismissShellInstructions() },
            )
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 16) {
            Group {
                if let nsImage = logomarkImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text("Hi \(userFirstName)! Let's get you all set up.")
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !visibleRequiredSteps.isEmpty {
                Text("Required")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    ForEach(visibleRequiredSteps) { step in
                        SetupStepRow(
                            step: step,
                            isCurrentStep: step.id == currentStepId && !step.isOptional,
                            actionLabel: actionLabel(for: step),
                            onAction: {
                                _Concurrency.Task {
                                    await manager.executeStep(step.id)
                                }
                            },
                            onRetry: {
                                _Concurrency.Task {
                                    await manager.retryStep(step.id)
                                }
                            },
                        )
                    }
                }
            }

            if !optionalSteps.isEmpty {
                Text("Optional")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, visibleRequiredSteps.isEmpty ? 0 : 6)

                VStack(spacing: 10) {
                    ForEach(optionalSteps) { step in
                        SetupStepRow(
                            step: step,
                            isCurrentStep: step.id == currentStepId && !step.isOptional,
                            actionLabel: actionLabel(for: step),
                            onAction: {
                                _Concurrency.Task {
                                    await manager.executeStep(step.id)
                                }
                            },
                            onRetry: {
                                _Concurrency.Task {
                                    await manager.retryStep(step.id)
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    // MARK: - Transparency

    private var transparencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What we'll change on your machine")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 6) {
                transparencyBullet("Install the hud-hook binary at ~/.local/bin/hud-hook.")
                transparencyBullet("Register Claude hooks in ~/.claude/settings.json (we only add our entries).")
                transparencyBullet("Hooks send event metadata (session start/stop, tool name, file path) to a local daemon over ~/.capacitor/daemon.sock.")
                transparencyBullet("The daemon stores session state under ~/.capacitor/.")
                transparencyBullet("Optional: add a shell snippet to report your current directory after each prompt.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
    }

    private func transparencyBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .padding(.top, 6)
            Text(text)
        }
    }

    private var currentStepId: String? {
        if let required = manager.steps.first(where: { !$0.isOptional && !$0.status.isComplete }) {
            return required.id
        }
        return manager.steps.first(where: { !$0.status.isComplete })?.id
    }

    private var visibleRequiredSteps: [SetupStep] {
        manager.steps.filter { step in
            if step.isOptional { return false }
            if step.id == "claude", step.status.isComplete { return false }
            return true
        }
    }

    private var optionalSteps: [SetupStep] {
        manager.steps.filter(\.isOptional)
    }

    private func actionLabel(for step: SetupStep) -> String {
        switch step.id {
        case "hooks":
            if case .error = step.status {
                return "Repair Hooks"
            }
            return "Install Hooks"
        case "shell":
            return "Open Instructions"
        default:
            return "Install"
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 16) {
            if manager.hasBlockingError {
                Text("Please resolve the issues above to continue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: completeSetup) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!manager.allComplete)
        }
        .padding(.top, 24)
    }

    // MARK: - Actions

    private func completeSetup() {
        _Concurrency.Task {
            await CapacitorConfig.shared.markSetupComplete()

            #if DEBUG
                CapacitorApp.restoreOnboardingBackup()
            #endif

            onComplete()
        }
    }
}

#Preview("All Complete") {
    WelcomeView(onComplete: { print("Complete!") })
        .preferredColorScheme(.dark)
}

#Preview("In Progress") {
    WelcomeView(onComplete: { print("Complete!") })
        .preferredColorScheme(.dark)
}
