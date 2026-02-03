import Foundation

#if DEBUG

    // MARK: - UI Extensions for ParentApp

    extension ParentApp {
        var icon: String {
            switch self {
            case .cursor, .vsCode, .vsCodeInsiders, .zed: "curlybraces"
            case .ghostty, .iTerm, .terminal, .kitty, .alacritty, .warp: "terminal"
            case .tmux: "rectangle.split.3x1"
            case .unknown: "questionmark.circle"
            }
        }
    }

    // MARK: - UI Extensions for ParentAppCategory

    extension ParentAppCategory {
        var icon: String {
            switch self {
            case .ide: "curlybraces"
            case .terminal: "terminal"
            case .multiplexer: "rectangle.split.3x1"
            case .unknown: "questionmark.circle"
            }
        }

        var parentApps: [ParentApp] {
            ParentApp.allCases.filter { $0.category == self }
        }
    }

    // MARK: - UI Extensions for ShellContext

    extension ShellContext {
        var displayName: String {
            switch self {
            case .direct: "Direct"
            case .tmux: "In tmux"
            }
        }

        var badge: String {
            switch self {
            case .direct: "direct"
            case .tmux: "tmux"
            }
        }
    }

    // MARK: - UI Extensions for TerminalMultiplicity

    extension TerminalMultiplicity {
        var displayName: String {
            switch self {
            case .single: "Single"
            case .multipleTabs: "Multiple Tabs"
            case .multipleWindows: "Multiple Windows"
            }
        }

        var badge: String {
            switch self {
            case .single: "1 window"
            case .multipleTabs: "multi-tab"
            case .multipleWindows: "multi-window"
            }
        }

        var likelihood: Int {
            switch self {
            case .single: 3
            case .multipleTabs: 2
            case .multipleWindows: 2
            }
        }
    }

    // MARK: - UI Extensions for ShellScenario

    extension ShellScenario {
        var displayName: String {
            var parts: [String] = []

            switch context {
            case .direct:
                parts.append("Direct shell")
            case .tmux:
                parts.append("tmux session")
            }

            switch multiplicity {
            case .single:
                parts.append("single window")
            case .multipleTabs:
                parts.append("multiple tabs")
            case .multipleWindows:
                parts.append("multiple windows")
            }

            return parts.joined(separator: ", ")
        }

        var shortDescription: String {
            "\(parentApp.displayName) → \(context.badge), \(multiplicity.badge)"
        }

        static func fromLiveState(shell: ShellEntry, shellCount: Int) -> ShellScenario {
            let parentApp = ParentApp(fromString: shell.parentApp)
            let context: ShellContext = shell.tmuxSession != nil ? .tmux : .direct

            let multiplicity: TerminalMultiplicity = if shellCount > 1 {
                .multipleTabs
            } else {
                .single
            }

            return ShellScenario(
                parentApp: parentApp,
                context: context,
                multiplicity: multiplicity
            )
        }
    }

    // MARK: - CwdMatchType (DEBUG only)

    enum CwdMatchType: String, CaseIterable, Codable {
        case exact
        case subdirectory
        case noMatch

        var displayName: String {
            switch self {
            case .exact: "Exact Match"
            case .subdirectory: "Subdirectory"
            case .noMatch: "No Match"
            }
        }

        var badge: String {
            switch self {
            case .exact: "exact"
            case .subdirectory: "subdir"
            case .noMatch: "no match"
            }
        }
    }

    // MARK: - Scenario Generator

    enum ScenarioGenerator {
        static func generatePracticalScenarios(for parentApp: ParentApp) -> [ShellScenario] {
            var scenarios: [ShellScenario] = []

            let contexts: [ShellContext] = parentApp == .tmux ? [.tmux] : [.direct, .tmux]
            let multiplicities: [TerminalMultiplicity] = [.single, .multipleTabs, .multipleWindows]

            for context in contexts {
                for multiplicity in multiplicities {
                    scenarios.append(ShellScenario(
                        parentApp: parentApp,
                        context: context,
                        multiplicity: multiplicity
                    ))
                }
            }

            return scenarios
        }

        static func generateAllScenarios(for parentApp: ParentApp) -> [ShellScenario] {
            var scenarios: [ShellScenario] = []

            let contexts: [ShellContext] = parentApp == .tmux ? [.tmux] : ShellContext.allCases
            let multiplicities = TerminalMultiplicity.allCases

            for context in contexts {
                for multiplicity in multiplicities {
                    scenarios.append(ShellScenario(
                        parentApp: parentApp,
                        context: context,
                        multiplicity: multiplicity
                    ))
                }
            }

            return scenarios
        }
    }

#endif
