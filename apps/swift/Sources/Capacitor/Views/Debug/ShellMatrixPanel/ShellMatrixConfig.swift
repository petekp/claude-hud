import AppKit
import Foundation

#if DEBUG

    @MainActor
    @Observable
    final class ShellMatrixConfig {
        static let shared = ShellMatrixConfig()

        private let store = ActivationConfigStore.shared

        func behavior(for scenario: ShellScenario) -> ScenarioBehavior {
            store.behavior(for: scenario)
        }

        func isOverridden(_ scenario: ShellScenario) -> Bool {
            store.isModified(scenario)
        }

        func setBehavior(_ behavior: ScenarioBehavior, for scenario: ShellScenario) {
            store.setBehavior(behavior, for: scenario)
        }

        func resetBehavior(for scenario: ShellScenario) {
            store.resetBehavior(for: scenario)
        }

        func resetAll() {
            store.resetAll()
        }

        var hasChanges: Bool {
            store.modifiedCount > 0
        }

        var modifiedCount: Int {
            store.modifiedCount
        }

        func exportForLLM() -> String {
            guard hasChanges else {
                return """
                ## Shell Matrix Configuration

                No changes from defaults. All scenarios use their default activation strategies.
                """
            }

            var output = "## Shell Matrix Configuration Changes\n\n"
            output += "The following scenarios have custom activation strategies:\n\n"
            output += "| Scenario | Primary | Fallback |\n"
            output += "|----------|---------|----------|\n"

            for category in ParentAppCategory.allCases where category != .unknown {
                for parentApp in category.parentApps {
                    for scenario in ScenarioGenerator.generatePracticalScenarios(for: parentApp) {
                        guard store.isModified(scenario) else { continue }

                        let behavior = store.behavior(for: scenario)
                        let defaultBehavior = ScenarioBehavior.defaultBehavior(for: scenario)

                        let primaryChange = behavior.primaryStrategy != defaultBehavior.primaryStrategy
                            ? "**\(behavior.primaryStrategy.displayName)**"
                            : behavior.primaryStrategy.displayName

                        let fallbackStr: String
                        if let fallback = behavior.fallbackStrategy {
                            let changed = fallback != defaultBehavior.fallbackStrategy
                            fallbackStr = changed ? "**\(fallback.displayName)**" : fallback.displayName
                        } else {
                            fallbackStr = "—"
                        }

                        output += "| \(scenario.shortDescription) | \(primaryChange) | \(fallbackStr) |\n"
                    }
                }
            }

            output += "\n_Bold values differ from defaults._\n"

            return output
        }

        func copyToClipboard() {
            let export = exportForLLM()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(export, forType: .string)
        }
    }

#endif
