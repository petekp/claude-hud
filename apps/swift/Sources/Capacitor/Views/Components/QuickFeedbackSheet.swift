import SwiftUI

struct QuickFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(QuickFeedbackPreferenceKeys.includeTelemetry) private var includeTelemetry = true
    @AppStorage(QuickFeedbackPreferenceKeys.includeProjectPaths) private var includeProjectPaths = false
    @State private var message = ""

    let onSubmit: (String, QuickFeedbackPreferences) -> Void

    private var canSubmit: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Feedback")
                .font(.system(size: 16, weight: .semibold))

            Text("Share what happened. We’ll open a GitHub issue draft with optional telemetry context.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextEditor(text: $message)
                .font(.system(size: 13))
                .frame(minHeight: 140)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04)),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5),
                )

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Include anonymized telemetry", isOn: $includeTelemetry)
                    .font(.system(size: 12))
                Toggle("Include project paths for debugging", isOn: $includeProjectPaths)
                    .font(.system(size: 12))
                    .disabled(!includeTelemetry)
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Submit") {
                    onSubmit(
                        message,
                        QuickFeedbackPreferences(
                            includeTelemetry: includeTelemetry,
                            includeProjectPaths: includeTelemetry && includeProjectPaths,
                        ),
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .onChange(of: includeTelemetry) { _, enabled in
            if !enabled {
                includeProjectPaths = false
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
