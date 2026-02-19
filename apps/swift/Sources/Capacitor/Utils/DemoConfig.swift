import Foundation

struct DemoConfig: Equatable {
    let isEnabled: Bool
    let scenario: String?
    let disableSideEffects: Bool
    let projectsFilePath: String?

    static var current: DemoConfig {
        resolve(environment: ProcessInfo.processInfo.environment)
    }

    static func resolve(environment: [String: String]) -> DemoConfig {
        let isEnabled = parseBoolean(environment["CAPACITOR_DEMO_MODE"]) ?? false
        let requestedScenario = normalizeScenario(environment["CAPACITOR_DEMO_SCENARIO"])
        let scenario = isEnabled ? (requestedScenario ?? "project_flow_v1") : requestedScenario
        let disableSideEffects = parseBoolean(environment["CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS"]) ?? isEnabled
        let projectsFilePath = normalizePath(environment["CAPACITOR_DEMO_PROJECTS_FILE"])

        return DemoConfig(
            isEnabled: isEnabled,
            scenario: scenario,
            disableSideEffects: disableSideEffects,
            projectsFilePath: projectsFilePath,
        )
    }

    private static func normalizeScenario(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func parseBoolean(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func normalizePath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
