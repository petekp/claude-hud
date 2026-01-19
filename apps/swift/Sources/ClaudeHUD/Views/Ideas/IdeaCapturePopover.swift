import SwiftUI
import AppKit

struct IdeaCapturePopover: View {
    @Binding var isPresented: Bool
    let onCapture: (String) -> Result<Void, Error>

    @State private var ideaText: String = ""
    @State private var captureError: String?
    @State private var isCapturing = false
    @FocusState private var isTextFieldFocused: Bool

    private var hasText: Bool {
        !ideaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            textArea

            if let error = captureError {
                errorBanner(error)
            }

            footer
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
        .onKeyPress(keys: [.return]) { keyPress in
            if keyPress.modifiers.contains(.shift) {
                captureAndClear()
            } else {
                captureAndClose()
            }
            return .handled
        }
        .onKeyPress(keys: [.escape]) { _ in
            cancel()
            return .handled
        }
    }

    private var textArea: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $ideaText)
                .font(.body)
                .foregroundColor(.primary)
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(height: 72)
                .focused($isTextFieldFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            captureError != nil ? Color.red.opacity(0.5) : Color.primary.opacity(0.15),
                            lineWidth: 1
                        )
                )
                .disabled(isCapturing)

            if ideaText.isEmpty {
                Text("Quick thought...")
                    .font(.body)
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
            Text(error)
                .font(.caption)
                .foregroundColor(.red.opacity(0.9))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("⏎ Save  ⇧⏎ Save & add another")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.6))

            Spacer()

            Button("Cancel") {
                cancel()
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundColor(.secondary)
            .disabled(isCapturing)

            Button("Save") {
                captureAndClose()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.small)
            .disabled(!hasText || isCapturing)
        }
    }

    private func captureAndClose() {
        guard capture() else { return }
        isPresented = false
    }

    private func captureAndClear() {
        guard capture() else { return }
        ideaText = ""
        isTextFieldFocused = true
    }

    private func capture() -> Bool {
        let trimmed = ideaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        isCapturing = true
        captureError = nil

        let result = onCapture(trimmed)

        isCapturing = false

        switch result {
        case .success:
            return true
        case .failure(let error):
            captureError = error.localizedDescription
            return false
        }
    }

    private func cancel() {
        isPresented = false
    }
}
