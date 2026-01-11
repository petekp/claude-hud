import SwiftUI

struct HealthCoachingSection: View {
    let healthResult: HealthScoreResult

    var improvementSuggestions: [HealthCheck] {
        healthResult.details.filter { !$0.passed && $0.suggestion != nil }
    }

    var body: some View {
        if improvementSuggestions.isEmpty {
            return AnyView(EmptyView())
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                DetailSectionLabel(title: "IMPROVEMENTS")

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(improvementSuggestions.prefix(3).enumerated()), id: \.offset) { index, check in
                        CoachingTipView(check: check, number: index + 1)
                    }

                    if improvementSuggestions.count > 3 {
                        Text("+\(improvementSuggestions.count - 3) more suggestions")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
        )
    }
}

struct CoachingTipView: View {
    let check: HealthCheck
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(Color.orange.opacity(0.3))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Text("\(number)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.orange)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(check.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))

                    if let suggestion = check.suggestion {
                        Text(suggestion)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                Spacer()
            }

            if let template = check.template {
                TemplatePreview(template: template)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
    }
}

struct TemplatePreview: View {
    let template: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Template:")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))

            Text(template.split(separator: "\n").prefix(2).joined(separator: "\n"))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(2)
        }
        .padding(6)
        .background(Color.white.opacity(0.02))
        .cornerRadius(4)
    }
}
