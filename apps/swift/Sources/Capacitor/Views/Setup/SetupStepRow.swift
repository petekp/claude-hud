import SwiftUI

struct SetupStepRow: View {
    let step: SetupStep
    let isCurrentStep: Bool
    var actionLabel: String = "Install"
    var linkURL: URL?
    var linkLabel: String = "Download"
    var onAction: (() -> Void)?
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.headline)
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                Text(step.statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(detailColor)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }

            Spacer()

            actionButton
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.2), value: step.status)
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)

        case .checking:
            ProgressView()
                .scaleEffect(0.8)

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)

        case .actionNeeded:
            Image(systemName: "circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)

        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.yellow)
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch step.status {
        case .actionNeeded:
            if let onAction {
                Button(actionLabel, action: onAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

        case .error:
            ViewThatFits {
                HStack(spacing: 6) {
                    errorActions
                }

                VStack(alignment: .leading, spacing: 6) {
                    errorActions
                }
            }
            .fixedSize(horizontal: true, vertical: false)

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var errorActions: some View {
        if let linkURL {
            Link(linkLabel, destination: linkURL)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }

        if let onRetry {
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else if let onAction, linkURL == nil {
            Button(actionLabel, action: onAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - Styling

    private var titleColor: Color {
        switch step.status {
        case .pending:
            .secondary
        case .error:
            .primary
        default:
            .primary
        }
    }

    private var detailColor: Color {
        switch step.status {
        case .error:
            .yellow
        default:
            .secondary
        }
    }

    private var rowBackground: Color {
        switch step.status {
        case .actionNeeded where isCurrentStep:
            Color.accentColor.opacity(0.1)
        case .error:
            Color.yellow.opacity(0.1)
        default:
            Color.primary.opacity(0.05)
        }
    }
}

#Preview("All States") {
    VStack(spacing: 12) {
        SetupStepRow(
            step: SetupStep(
                id: "claude",
                title: "Claude Code",
                description: "Capacitor needs Claude Code to work",
                status: .completed(detail: "/usr/local/bin/claude"),
            ),
            isCurrentStep: false,
        )

        SetupStepRow(
            step: SetupStep(
                id: "hooks",
                title: "Session hooks",
                description: "Connect Capacitor to your Claude sessions",
                status: .checking,
            ),
            isCurrentStep: true,
        )

        SetupStepRow(
            step: SetupStep(
                id: "hooks",
                title: "Session hooks",
                description: "Connect Capacitor to your Claude sessions",
                status: .actionNeeded(message: "Install hooks to enable session tracking"),
            ),
            isCurrentStep: true,
            onAction: { print("Install tapped") },
        )

        SetupStepRow(
            step: SetupStep(
                id: "claude",
                title: "Claude Code",
                description: "Capacitor needs Claude Code to work",
                status: .error(message: "Not found — download from claude.ai/download"),
            ),
            isCurrentStep: true,
            linkURL: URL(string: "https://claude.ai/download"),
            onRetry: { print("Retry tapped") },
        )

        SetupStepRow(
            step: SetupStep(
                id: "shell",
                title: "Shell integration",
                description: "Track which project you're working in",
                status: .pending,
                isOptional: true,
            ),
            isCurrentStep: false,
        )
    }
    .padding()
    .frame(width: 400)
    .preferredColorScheme(.dark)
}
